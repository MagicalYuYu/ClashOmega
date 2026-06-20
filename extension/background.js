// Clash Manager — Service Worker (Background)
// 导入所有模块
importScripts(
  'lib/proxy-manager.js',
  'lib/clash-api.js',
  'lib/native-bridge.js',
  'lib/domain-detector.js'
);

// ──── 初始化 ────

// 启动域名检测器
initDomainDetector();

// 初始化默认设置
chrome.runtime.onInstalled.addListener(async () => {
  const existing = await chrome.storage.local.get('settings');
  if (!existing.settings) {
    await chrome.storage.local.set({
      settings: {
        currentMode: 'system',
        clashApiUrl: 'http://127.0.0.1:9090',
        clashSecret: '',
        clashProxyHost: '127.0.0.1',
        clashProxyPort: 7890,
        language: 'zh_CN'
      }
    });
  }
});

// ──── 消息路由 ────

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  handleMessage(message).then(sendResponse);
  return true; // 保持异步响应通道
});

async function handleMessage(message) {
  try {
    switch (message.action) {
      // ──── 状态查询 ────
      case 'getStatus': {
        const settings = await getSettings();
        const config = await getClashConfig();
        const clashRunning = config !== null;
        // 串行调用 Native Host（避免并发导致 native messaging 队列问题）
        const nativeHostInstalled = await checkNativeHost();
        const sysProxy = await getSystemProxyStatus();
        const proxyPort = clashRunning
          ? extractProxyPort(config, settings.clashProxyHost).port
          : settings.clashProxyPort;
        return {
          mode: settings.currentMode,
          clashRunning,
          config,
          proxyPort,
          sysProxy: sysProxy.success ? sysProxy : null,
          nativeHostInstalled,
          clashProxyHost: settings.clashProxyHost,
          clashProxyPort: settings.clashProxyPort
        };
      }

      // ──── 模式切换 ────
      case 'setMode': {
        const settings = await getSettings();
        let clashProxy = {
          host: settings.clashProxyHost,
          port: settings.clashProxyPort
        };

        // Clash 模式：优先从 API 获取实际代理端口（mixed-port / port）
        if (message.mode === 'clash') {
          try {
            const config = await getClashConfig();
            if (config) {
              const detected = extractProxyPort(config, settings.clashProxyHost);
              clashProxy = detected;
              // 同步更新保存的端口，下次离线时也能用
              settings.clashProxyPort = detected.port;
              console.log(`Clash Manager: detected proxy port ${detected.port} from Clash config`);
            }
          } catch (e) {
            // 离线时回退到已保存的端口
            console.log('Clash Manager: cannot detect proxy port, using saved:', settings.clashProxyPort);
          }
        }

        await setProxyMode(message.mode, clashProxy);
        settings.currentMode = message.mode;
        await chrome.storage.local.set({ settings });
        await setActionIcon(message.mode);
        return { success: true, proxyPort: clashProxy.port };
      }

      // ──── Clash 规则读取（REST API） ────
      case 'getClashRules': {
        const data = await getClashRules();
        return { success: data !== null, rules: data?.rules || [] };
      }

      // ──── Clash 代理组列表 ────
      case 'getProxies': {
        const proxies = await getClashProxies();
        return { success: true, proxies };
      }

      // ──── Clash 状态 ────
      case 'getClashConfig': {
        const config = await getClashConfig();
        return { success: config !== null, config };
      }

      // ──── 规则管理（Native Host） ────
      case 'addRule': {
        const result = await addClashRule(message.rule);
        // 不自动重启 Clash —— Clash Verge Rev 等 GUI 客户端管理内核生命周期，
        // 直接 POST /restart 会导致内核崩溃。规则写入后需用户在 Clash GUI 中手动重启。
        return result;
      }

      case 'batchAddRules': {
        const result = await batchAddClashRules(message.rules);
        return result;
      }

      case 'removeRule': {
        const result = await removeClashRule(message.rule);
        return result;
      }

      // ──── 域名检测 ────
      case 'getPageDomains': {
        const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
        const domains = getTabDomains(tab.id);
        const count = getTabDomainCount(tab.id);
        return { success: true, domains, count };
      }

      // ──── 设置管理 ────
      case 'getSettings': {
        return await getSettings();
      }

      case 'saveSettings': {
        await chrome.storage.local.set({ settings: message.settings });
        return { success: true };
      }

      // ──── Clash 服务管理 ────
      case 'setConfigPath': {
        const result = await sendToNative({ action: 'setConfigPath', path: message.path });
        return result;
      }

      case 'ping': {
        const result = await sendToNative({ action: 'ping' });
        return result;
      }

      default:
        return { success: false, error: `Unknown action: ${message.action}` };
    }
  } catch (e) {
    console.error(`Handle message error (${message.action}):`, e);
    return { success: false, error: e.message };
  }
}

// ──── 初始化 ────
async function init() {
  const settings = await getSettings();
  await setProxyMode(settings.currentMode, {
    host: settings.clashProxyHost,
    port: settings.clashProxyPort
  });
  await setActionIcon(settings.currentMode);
}

// 根据模式切换扩展图标颜色
async function setActionIcon(mode) {
  const base = 'icons/';
  const sizes = { 16: 'icon16', 48: 'icon48', 128: 'icon128' };
  const path = {};
  for (const [size, prefix] of Object.entries(sizes)) {
    path[size] = `${base}${prefix}_${mode}.png`;
  }
  try {
    await chrome.action.setIcon({ path });
  } catch (e) {
    console.warn('setActionIcon failed:', e.message);
  }
}

init();