# Clash Rules Manager - Native Messaging Host (PowerShell)
# 被 Chrome 按需调用，读写 Clash 配置文件中的 rules 字段。
# 协议: stdin/stdout 二进制消息 (4字节小端序长度 + UTF-8 JSON)
# 依赖: 仅 Windows 内置 PowerShell，零额外安装

param()

$ErrorActionPreference = 'Stop'
$encoding = [System.Text.UTF8Encoding]::new($false)

# ──── 默认 Clash 配置路径 / Default config search paths ────
$DefaultConfigPaths = @(
    # Clash Verge Rev (Electron 数据目录，最常见)
    "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml",
    "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev\config.yaml",
    # Clash Verge Rev 旧路径
    "$env:APPDATA\clash-verge-rev\clash-verge.yaml",
    "$env:APPDATA\clash-verge-rev\config.yaml",
    # Clash Verge Rev LOCALAPPDATA 变体
    "$env:LOCALAPPDATA\io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml",
    "$env:LOCALAPPDATA\io.github.clash-verge-rev.clash-verge-rev\config.yaml",
    "$env:LOCALAPPDATA\clash-verge-rev\clash-verge.yaml",
    "$env:LOCALAPPDATA\clash-verge-rev\config.yaml",
    # Clash Verge
    "$env:USERPROFILE\.config\clash-verge\config.yaml",
    # Mihomo / Clash.Meta
    "$env:USERPROFILE\.config\mihomo\config.yaml",
    # Clash for Windows
    "$env:USERPROFILE\.config\clash\config.yaml",
    "$env:USERPROFILE\.config\clash\profiles\default.yaml",
    # Clash Nyanpasu
    "$env:USERPROFILE\.config\clash-nyanpasu\config.yaml",
    # Flclash
    "$env:USERPROFILE\.config\flclash\config.yaml",
    # 通用 AppData 路径
    "$env:LOCALAPPDATA\clash\config.yaml",
    "$env:APPDATA\clash\config.yaml",
    "$env:APPDATA\mihomo\config.yaml"
)

# 需要递归搜索 *.yaml 的目录
$ProfileSearchDirs = @(
    "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev\profiles",
    "$env:LOCALAPPDATA\io.github.clash-verge-rev.clash-verge-rev\profiles",
    "$env:APPDATA\clash-verge-rev\profiles",
    "$env:LOCALAPPDATA\clash-verge-rev\profiles",
    "$env:USERPROFILE\.config\clash\profiles",
    "$env:USERPROFILE\.config\clash-verge\profiles",
    "$env:USERPROFILE\.config\mihomo\profiles",
    "$env:APPDATA\clash\profiles",
    "$env:LOCALAPPDATA\clash\profiles"
)

# 可能包含 profiles.yaml 的 Clash GUI 配置目录（用于解析 type:rules 的 profile）
$ProfilesYamlDirs = @(
    "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev",
    "$env:LOCALAPPDATA\io.github.clash-verge-rev.clash-verge-rev",
    "$env:APPDATA\clash-verge-rev",
    "$env:LOCALAPPDATA\clash-verge-rev",
    "$env:USERPROFILE\.config\clash-verge",
    "$env:USERPROFILE\.config\clash",
    "$env:USERPROFILE\.config\mihomo"
)

function Get-ConfigPath {
    # 1. 环境变量优先
    $envPath = $env:CLASH_CONFIG_PATH
    if ($envPath -and (Test-Path $envPath)) {
        return $envPath
    }

    # 2. 从 profiles.yaml 解析 type:rules 的 profile 文件（优先于快照文件）
    #    Clash Verge Rev 架构说明：
    #    - clash-verge.yaml 是快照文件，由所有 profile 合并生成，重启内核后重建
    #    - profiles.yaml 中的 type:rules 项指向用户自定义规则的源文件，修改后永久生效
    #    - type:remote 是订阅文件，不应修改（会被订阅更新覆盖）
    $foundProfilePath = $null
    $profileDir = $null

    foreach ($dir in $ProfilesYamlDirs) {
        $profilesYaml = Join-Path $dir 'profiles.yaml'
        if (Test-Path $profilesYaml) {
            $profileContent = Get-Content $profilesYaml -Raw -Encoding UTF8
            $lines = $profileContent -split "`n"
            $currentType = $null; $currentFile = $null

            # 优先查找 type:rules（用户自定义规则覆盖文件）
            foreach ($line in $lines) {
                $trimmed = $line.Trim()
                if ($trimmed -match '^-\s*uid\s*:') { $currentType = $null; $currentFile = $null }
                elseif ($trimmed -match '^\s*type\s*:\s*(\S+)') { $currentType = $matches[1] }
                elseif ($trimmed -match '^\s*file\s*:\s*(\S+)') { $currentFile = $matches[1] }
                if ($currentType -eq 'rules' -and $currentFile) {
                    $foundProfilePath = Join-Path $dir 'profiles' $currentFile
                    $profileDir = $dir
                    if (Test-Path $foundProfilePath) { return $foundProfilePath }
                    $currentType = $null; $currentFile = $null
                }
            }

            # 兜底：如果 type:rules 未找到，取任意一个非 remote 的 profile 文件
            if (-not $foundProfilePath) {
                $currentType = $null; $currentFile = $null
                foreach ($line in $lines) {
                    $trimmed = $line.Trim()
                    if ($trimmed -match '^-\s*uid\s*:') { $currentType = $null; $currentFile = $null }
                    elseif ($trimmed -match '^\s*type\s*:\s*(\S+)') { $currentType = $matches[1] }
                    elseif ($trimmed -match '^\s*file\s*:\s*(\S+)') { $currentFile = $matches[1] }
                    if ($currentType -ne 'remote' -and $currentType -ne 'script' -and $currentFile) {
                        $foundProfilePath = Join-Path $dir 'profiles' $currentFile
                        $profileDir = $dir
                        if (Test-Path $foundProfilePath) { break }
                        $currentType = $null; $currentFile = $null
                    }
                }
            }
        }
    }

    # 如果从 profiles.yaml 中找到了 profile 文件（但可能不是 type:rules，作为次选）
    if ($foundProfilePath -and (Test-Path $foundProfilePath)) {
        return $foundProfilePath
    }

    # 3. 在 profile 目录中递归搜索（优先于快照文件）
    #    用户在 profiles 目录下手动创建的规则文件通常在这里
    foreach ($dir in $ProfileSearchDirs) {
        if (Test-Path $dir) {
            $found = Get-ChildItem -Path $dir -Filter "*.yaml" -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { return $found.FullName }
        }
    }

    # 4. 检查固定路径列表（最后兜底）
    #    注意：clash-verge.yaml 是 Clash Verge Rev 的快照文件，重启后会丢失修改。
    foreach ($p in $DefaultConfigPaths) {
        if (Test-Path $p) {
            return $p
        }
    }

    # 5. 尝试从运行中的 Clash 进程获取配置文件路径
    $clashProcs = Get-CimInstance Win32_Process -Filter "name like '%clash%' or name like '%mihomo%'" -ErrorAction SilentlyContinue
    foreach ($proc in $clashProcs) {
        if ($proc.CommandLine) {
            $cmdLine = $proc.CommandLine
            if ($cmdLine -match '-f\s+"?([^\s"]+\.ya?ml)"?') {
                $p = $matches[1]
                if (Test-Path $p) { return $p }
            }
            if ($cmdLine -match '-d\s+"?([^\s"]+)"?') {
                $d = $matches[1]
                $p = Join-Path $d "config.yaml"
                if (Test-Path $p) { return $p }
            }
        }
    }

    return $null
}

function Read-Config($path) {
    return Get-Content -Path $path -Raw -Encoding UTF8
}

function Write-Config($path, $content) {
    $backup = "$path.bak"
    if (Test-Path $path) {
        Copy-Item -Path $path -Destination $backup -Force
    }
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($path, $content, $utf8NoBom)
}

function Parse-Rules($content) {
    $rules = @()
    $lines = $content -split "`n"

    # 自动检测 Clash Verge profile 格式
    $isProfile = ($content -match '^\s*append\s*:') -or ($content -match '^\s*prepend\s*:')

    if ($isProfile) {
        $inAppend = $false
        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if ($trimmed -eq 'append:') { $inAppend = $true; continue }
            if ($inAppend -and $trimmed.StartsWith('- ') -and -not $trimmed.EndsWith('[]')) {
                $rule = $trimmed.Substring(2).Trim().Trim("'").Trim('"')
                if ($rule) { $rules += $rule }
            }
            if ($inAppend -and -not $trimmed.StartsWith('- ') -and $trimmed -and -not $trimmed.StartsWith('#')) {
                $inAppend = $false
            }
        }
        return $rules
    }

    # 标准 Clash 配置格式
    $inRules = $false
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if (-not $inRules) {
            if ($trimmed -eq 'rules:' -or $trimmed.StartsWith('rules:')) { $inRules = $true }
            continue
        }
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        if (-not $trimmed.StartsWith('- ') -and -not $trimmed.StartsWith("- '") -and -not $trimmed.StartsWith('- "')) {
            if (-not $line.StartsWith(' ') -and -not $line.StartsWith("`t") -and $trimmed.Contains(':')) { break }
            continue
        }
        $rule = ''
        if ($trimmed.StartsWith('- ')) { $rule = $trimmed.Substring(2).Trim() }
        elseif ($trimmed.StartsWith("- '") -and $trimmed.EndsWith("'")) { $rule = $trimmed.Substring(3, $trimmed.Length - 4).Trim() }
        elseif ($trimmed.StartsWith('- "') -and $trimmed.EndsWith('"')) { $rule = $trimmed.Substring(3, $trimmed.Length - 4).Trim() }
        if ($rule) { $rules += $rule }
    }
    return $rules
}

function Add-Rule($content, $rule) {
    $isProfile = ($content -match '^\s*append\s*:') -or ($content -match '^\s*prepend\s*:')

    if ($isProfile) {
        $lines = [System.Collections.ArrayList]::new($content -split "`n")
        $inAppend = $false; $insertIdx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $trimmed = $lines[$i].Trim()
            if ($trimmed -eq 'append:') { $inAppend = $true; continue }
            if ($inAppend) {
                if ($trimmed.StartsWith('- ') -and -not $trimmed.EndsWith('[]')) { $insertIdx = $i + 1; continue }
                if ($trimmed -eq '[]') { $lines[$i] = "  - '$rule'"; $insertIdx = -1; break }
                if (-not $trimmed.StartsWith('- ') -and $trimmed -and -not $trimmed.StartsWith('#')) { $insertIdx = $i; break }
            }
        }
        if ($insertIdx -ge 0) { $lines.Insert($insertIdx, "  - '$rule'") }
        return $lines -join "`n"
    }

    # 标准 Clash 配置格式
    $lines = [System.Collections.ArrayList]::new($content -split "`n")
    $inRules = $false; $insertIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $trimmed = $lines[$i].Trim()
        if (-not $inRules) {
            if ($trimmed -eq 'rules:' -or $trimmed.StartsWith('rules:')) { $inRules = $true }
            continue
        }
        if (-not $trimmed -or $trimmed.StartsWith('#')) { $insertIdx = $i + 1; continue }
        if ($trimmed.StartsWith('- ') -or $trimmed.StartsWith("- '") -or $trimmed.StartsWith('- "')) { $insertIdx = $i + 1; continue }
        if (-not $lines[$i].StartsWith(' ') -and -not $lines[$i].StartsWith("`t") -and $trimmed.Contains(':')) { $insertIdx = $i; break }
    }
    if ($insertIdx -lt 0) { return $content }
    $newLine = if ($rule.Contains(',')) { "  - '$rule'" } else { "  - $rule" }
    $lines.Insert($insertIdx, $newLine)
    return $lines -join "`n"
}

function Remove-Rule($content, $rule) {
    $lines = $content -split "`n"
    $result = @()
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        $ruleContent = ''
        if ($trimmed.StartsWith('- ')) { $ruleContent = $trimmed.Substring(2).Trim().Trim("'").Trim('"') }
        elseif ($trimmed.StartsWith("- '") -and $trimmed.EndsWith("'")) { $ruleContent = $trimmed.Substring(3, $trimmed.Length - 4).Trim() }
        elseif ($trimmed.StartsWith('- "') -and $trimmed.EndsWith('"')) { $ruleContent = $trimmed.Substring(3, $trimmed.Length - 4).Trim() }
        if ($ruleContent -eq $rule) { continue }
        $result += $line
    }
    return $result -join "`n"
}

# ──── Native Messaging 协议 ────

function Send-Message($msg) {
    $json = ConvertTo-Json -InputObject $msg -Compress -Depth 10
    $bytes = $encoding.GetBytes($json)
    $lenBytes = [System.BitConverter]::GetBytes([int]$bytes.Length)
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($lenBytes, 0, 4)
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
}

function Read-Message {
    $stdin = [Console]::OpenStandardInput()
    $lenBuffer = New-Object byte[] 4
    $read = $stdin.Read($lenBuffer, 0, 4)
    if ($read -lt 4) { return $null }
    $msgLen = [System.BitConverter]::ToInt32($lenBuffer, 0)
    if ($msgLen -le 0 -or $msgLen -gt 1048576) { return $null }
    $msgBuffer = New-Object byte[] $msgLen
    $totalRead = 0
    while ($totalRead -lt $msgLen) {
        $r = $stdin.Read($msgBuffer, $totalRead, $msgLen - $totalRead)
        if ($r -le 0) { return $null }
        $totalRead += $r
    }
    $json = $encoding.GetString($msgBuffer)
    return ConvertFrom-Json $json
}

# ──── 主循环 ────

function Main {
    $configPath = Get-ConfigPath

    while ($true) {
        $msg = Read-Message
        if ($null -eq $msg) { break }

        $action = $msg.action
        if (-not $action) { $action = '' }

        try {
            switch ($action) {
                'ping' {
                    Send-Message @{
                        success = $true
                        configPath = if ($configPath) { $configPath } else { '(not found)' }
                    }
                }

                'getRules' {
                    if (-not $configPath) { $configPath = Get-ConfigPath }
                    if (-not $configPath -or -not (Test-Path $configPath)) {
                        Send-Message @{
                            success = $false
                            error = 'Config file not found. Please set CLASH_CONFIG_PATH or start Clash first.'
                        }
                    }
                    else {
                        $content = Read-Config $configPath
                        $rules = Parse-Rules $content
                        Send-Message @{
                            success = $true
                            rules = $rules
                            configPath = $configPath
                        }
                    }
                }

                'addRule' {
                    if (-not $configPath) { $configPath = Get-ConfigPath }
                    if (-not $configPath -or -not (Test-Path $configPath)) {
                        Send-Message @{ success = $false; error = 'Config file not found. Please set CLASH_CONFIG_PATH or start Clash first.' }
                    }
                    else {
                        $content = Read-Config $configPath
                        $newContent = Add-Rule $content $msg.rule
                        Write-Config $configPath $newContent
                        Send-Message @{ success = $true; message = 'Rule added'; configPath = $configPath }
                    }
                }

                'batchAddRules' {
                    if (-not $configPath) { $configPath = Get-ConfigPath }
                    if (-not $configPath -or -not (Test-Path $configPath)) {
                        Send-Message @{ success = $false; error = 'Config file not found. Please set CLASH_CONFIG_PATH or start Clash first.' }
                    }
                    else {
                        $content = Read-Config $configPath
                        $existing = [System.Collections.Generic.HashSet[string]]::new([string[]](Parse-Rules $content))
                        $added = 0
                        foreach ($rule in $msg.rules) {
                            if (-not $existing.Contains($rule)) {
                                $content = Add-Rule $content $rule
                                [void]$existing.Add($rule)
                                $added++
                            }
                        }
                        Write-Config $configPath $content
                        Send-Message @{ success = $true; message = "$added rules added"; configPath = $configPath }
                    }
                }

                'removeRule' {
                    if (-not $configPath) { $configPath = Get-ConfigPath }
                    if (-not $configPath -or -not (Test-Path $configPath)) {
                        Send-Message @{ success = $false; error = 'Config file not found. Please set CLASH_CONFIG_PATH or start Clash first.' }
                    }
                    else {
                        $content = Read-Config $configPath
                        $newContent = Remove-Rule $content $msg.rule
                        Write-Config $configPath $newContent
                        Send-Message @{ success = $true; message = 'Rule removed'; configPath = $configPath }
                    }
                }

                'setConfigPath' {
                    if (Test-Path $msg.path) {
                        $configPath = $msg.path
                        Send-Message @{ success = $true; message = 'Config path updated' }
                    }
                    else {
                        Send-Message @{ success = $false; error = 'Path does not exist' }
                    }
                }

                'getSystemProxy' {
                    $regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
                    try {
                        $proxyEnable = (Get-ItemProperty -Path $regPath -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable
                        $proxyServer = (Get-ItemProperty -Path $regPath -Name ProxyServer -ErrorAction SilentlyContinue).ProxyServer
                        $autoConfigUrl = (Get-ItemProperty -Path $regPath -Name AutoConfigURL -ErrorAction SilentlyContinue).AutoConfigURL
                        Send-Message @{
                            success = $true
                            proxyEnable = if ($proxyEnable) { $true } else { $false }
                            proxyServer = if ($proxyServer) { $proxyServer } else { '' }
                            autoConfigUrl = if ($autoConfigUrl) { $autoConfigUrl } else { '' }
                        }
                    }
                    catch {
                        Send-Message @{ success = $false; error = $_.Exception.Message }
                    }
                }

                default {
                    Send-Message @{ success = $false; error = "Unknown action: $action" }
                }
            }
        }
        catch {
            Send-Message @{ success = $false; error = $_.Exception.Message }
        }
    }
}

Main