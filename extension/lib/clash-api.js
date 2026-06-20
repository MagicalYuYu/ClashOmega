// Clash REST API 封装（只读 GET + 配置重载 PUT）
// 规则修改由 Native Messaging Host 完成

// Clash 常见 API 端口（自动探测）
const CLASH_API_PORTS = [9090, 9097, 9098, 9091, 8080];

/**
 * 获取 Clash API 基础 URL 和认证头
 */
async function getApiConfig() {
  const settings = await getSettings();
  const headers = { 'Content-Type': 'application/json' };
  if (settings.clashSecret) {
    headers['Authorization'] = `Bearer ${settings.clashSecret}`;
  }
  return { baseUrl: settings.clashApiUrl, headers };
}

/**
 * 尝试向指定 URL 发送 GET 请求
 */
async function tryFetch(url, headers) {
  try {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 3000);
    const response = await fetch(url, { headers, signal: ctrl.signal });
    clearTimeout(timer);
    if (!response.ok) return null;
    return await response.json();
  } catch {
    return null;
  }
}

/**
 * 发送 GET 请求到 Clash API（自动端口探测）
 */
async function clashGet(endpoint) {
  const { baseUrl, headers } = await getApiConfig();
  const result = await tryFetch(`${baseUrl}${endpoint}`, headers);
  if (result !== null) return result;

  // 如果用户配置的 URL 不通，尝试自动探测其他端口
  const settings = await getSettings();
  for (const port of CLASH_API_PORTS) {
    const testUrl = `http://127.0.0.1:${port}${endpoint}`;
    if (testUrl === `${baseUrl}${endpoint}`) continue; // 已尝试过
    const r = await tryFetch(testUrl, headers);
    if (r !== null) {
      // 自动保存探测到的端口
      settings.clashApiUrl = `http://127.0.0.1:${port}`;
      await chrome.storage.local.set({ settings });
      console.log(`Clash Manager: auto-detected API at http://127.0.0.1:${port}`);
      return r;
    }
  }
  return null;
}

/**
 * 发送 PUT 请求到 Clash API
 */
async function clashPut(endpoint, body) {
  const { baseUrl, headers } = await getApiConfig();
  try {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 3000);
    const response = await fetch(`${baseUrl}${endpoint}`, {
      method: 'PUT',
      headers,
      body: JSON.stringify(body),
      signal: ctrl.signal
    });
    clearTimeout(timer);
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    return true;
  } catch (e) {
    console.error(`Clash API PUT ${endpoint} failed:`, e.message);
    return false;
  }
}

/**
 * Clash POST 请求
 */
async function clashPost(endpoint) {
  const { baseUrl, headers } = await getApiConfig();
  try {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 3000);
    const response = await fetch(`${baseUrl}${endpoint}`, {
      method: 'POST',
      headers,
      signal: ctrl.signal
    });
    clearTimeout(timer);
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    return true;
  } catch (e) {
    console.error(`Clash API POST ${endpoint} failed:`, e.message);
    return false;
  }
}

/**
 * 获取 Clash 规则列表
 */
async function getClashRules() {
  return await clashGet('/rules');
}

/**
 * 获取 Clash 配置
 */
async function getClashConfig() {
  return await clashGet('/configs');
}

/**
 * 重载 Clash 配置（重启内核，Clash Verge Rev 会重新从 profile 生成配置）
 */
async function reloadClashConfig() {
  return await clashPost('/restart');
}

/**
 * 获取 Clash 代理组列表（用于 F2 快捷添加时选择目标代理组）
 */
async function getClashProxies() {
  const data = await clashGet('/proxies');
  if (!data || !data.proxies) return {};
  return data.proxies;
}

/**
 * 检查 Clash 是否可连接
 */
async function checkClashStatus() {
  try {
    const config = await getClashConfig();
    return config !== null;
  } catch {
    return false;
  }
}