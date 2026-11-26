/* APP 侧适配脚本：不改服务器资源，不传递密码、Token、消息内容。 */
(() => {
  'use strict';
  if (location.origin !== new URL(__ADMIN_ORIGIN__).origin ||
      !['/', '/app', '/app/'].includes(location.pathname) || window.IfengAdminBridge) return;

  let accountID = null;
  let previous = '';
  let queued = false;
  const streams = new Set();
  const positive = value => Number.isSafeInteger(Number(value)) && Number(value) > 0;
  const isReady = () => {
    const workspace = document.getElementById('workspace');
    return !!workspace && !workspace.hidden;
  };
  const hasDraft = () => !!(
    document.getElementById('message-input')?.value?.trim() ||
    document.getElementById('agent-image-preview') && !document.getElementById('agent-image-preview').hidden
  );
  function report() {
    queued = false;
    const loggedIn = isReady();
    const sync = document.getElementById('sync-status')?.textContent || '';
    const payload = {
      type: 'state', loggedIn, accountID: loggedIn ? accountID : null,
      hasDraft: hasDraft(), routeError: sync.startsWith('无法打开通知会话')
    };
    const encoded = JSON.stringify(payload);
    if (previous === encoded) return;
    previous = encoded;
    window.webkit?.messageHandlers?.ifengAdmin?.postMessage(payload);
  }
  function scheduleReport() {
    if (queued) return;
    queued = true;
    queueMicrotask(report);
  }

  // 只旁听现有请求结果，不新增 API，不读取或转发认证请求头。
  const originalFetch = window.fetch;
  window.fetch = function (...args) {
    const result = originalFetch.apply(this, args);
    result.then(response => {
      let url;
      try { url = new URL(typeof args[0] === 'string' ? args[0] : args[0]?.url || String(args[0]), location.href); }
      catch { return; }
      if (url.origin !== location.origin || !response.ok) return;
      const match = url.pathname.match(/^\/api\/v1\/accounts\/(\d+)(?:\/|$)/);
      if (match && positive(match[1])) { accountID = Number(match[1]); scheduleReport(); }
      if (url.pathname === '/api/v1/profile' || url.pathname === '/auth/sign_in') {
        response.clone().json().then(body => {
          const user = url.pathname === '/auth/sign_in' ? body.data : body;
          if (positive(user?.account_id)) { accountID = Number(user.account_id); scheduleReport(); }
        }).catch(() => {});
      }
    }).catch(() => {});
    return result;
  };

  // 前台恢复时关闭已冻结的流，再由网页自己申请 Ticket、重连和同步。
  // 仍使用网页的 SSE，不创建原生消息通道或第二条实时连接。
  if (window.EventSource) {
    const OriginalEventSource = window.EventSource;
    window.EventSource = new Proxy(OriginalEventSource, {
      construct(target, args) {
        const source = Reflect.construct(target, args);
        streams.add(source);
        const close = source.close.bind(source);
        source.close = () => { streams.delete(source); close(); };
        return source;
      }
    });
  }
  function resume() {
    for (const stream of [...streams]) stream.close();
    window.dispatchEvent(new Event('online'));
    window.dispatchEvent(new Event('pageshow'));
    document.dispatchEvent(new Event('visibilitychange'));
    scheduleReport();
  }

  function openConversation(target) {
    if (!isReady() || !positive(accountID)) return 'waiting';
    if (!positive(target?.accountID) || !positive(target?.conversationID)) return 'invalid';
    if (Number(target.accountID) !== accountID) return 'account-mismatch';
    // 优先复用网页已有通知导航处理器，保留内存草稿。WKWebView 若没有
    // ServiceWorker 容器则交给原生层确认后加载真实的 /app/?... 路由。
    if (navigator.serviceWorker?.dispatchEvent && window.ChatServerNotifications) {
      navigator.serviceWorker.dispatchEvent(new MessageEvent('message', { data: {
        kind: 'chat-server-admin-message', account_id: Number(target.accountID),
        conversation_id: Number(target.conversationID)
      }}));
      return 'handled';
    }
    return hasDraft() ? 'needs-confirmation' : 'navigate';
  }

  Object.defineProperty(window, 'IfengAdminBridge', {value: Object.freeze({resume, openConversation})});
  function observe() {
    new MutationObserver(scheduleReport).observe(document.documentElement, {
      subtree: true, childList: true, characterData: true,
      attributes: true, attributeFilter: ['hidden', 'class']
    });
    document.addEventListener('input', scheduleReport, true);
    report();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', observe, {once: true});
  else observe();
})();
