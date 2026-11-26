import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {test} from 'node:test';
import vm from 'node:vm';

const template = readFileSync(new URL('../IfengAdmin/Resources/AdminBridge.js', import.meta.url), 'utf8');
const source = template.replace('__ADMIN_ORIGIN__', JSON.stringify('https://support.example.com'));
const settle = () => new Promise(resolve => setImmediate(resolve));

function fixture({loggedIn = false, worker = false, origin = 'https://support.example.com', pathname = '/app/'} = {}) {
  const messages = [], requests = [], workerEvents = [], observers = [];
  const nodes = new Map([
    ['workspace', {hidden: !loggedIn}], ['message-input', {value: ''}],
    ['agent-image-preview', {hidden: true}], ['sync-status', {textContent: ''}]
  ]);
  class MockDocument extends EventTarget {
    readyState = 'complete';
    documentElement = {};
    getElementById(id) { return nodes.get(id); }
  }
  class Source extends EventTarget {
    static CLOSED = 2;
    static OPEN = 1;
    static CONNECTING = 0;
    readyState = 1;
    closeCount = 0;
    close() { this.closeCount++; this.readyState = 2; }
  }
  const window = new EventTarget();
  const document = new MockDocument();
  const navigator = {};
  if (worker) {
    navigator.serviceWorker = new EventTarget();
    navigator.serviceWorker.addEventListener('message', event => workerEvents.push(structuredClone(event.data)));
    window.ChatServerNotifications = {};
  }
  const context = {
    window, document, navigator, location: {origin, pathname, href: origin + pathname},
    URL, Event, MessageEvent, queueMicrotask,
    MutationObserver: class { constructor(callback) { observers.push(callback); } observe() {} }
  };
  window.navigator = navigator;
  window.location = context.location;
  window.focus = () => {};
  window.webkit = {messageHandlers: {ifengAdmin: {postMessage: value => messages.push(structuredClone(value))}}};
  window.EventSource = Source;
  window.fetch = function (...args) {
    requests.push({receiver: this, args});
    return Promise.resolve(new Response(JSON.stringify({account_id: 2}), {status: 200}));
  };
  const originalFetch = window.fetch;
  vm.runInNewContext(source, context);
  const mutate = async () => { for (const callback of observers) callback(); await settle(); };
  const authenticate = async (id = 2) => {
    nodes.get('workspace').hidden = false;
    await window.fetch(`/api/v1/accounts/${id}/conversations`);
    await mutate();
  };
  return {window, document, context, messages, requests, workerEvents, nodes, mutate, authenticate, originalFetch};
}

test('bridge is only installed in the configured administrator document', () => {
  for (const options of [{origin:'https://evil.example.com'}, {pathname:'/widget'}, {pathname:'/api/v1/profile'}]) {
    const f = fixture(options);
    assert.equal(f.window.IfengAdminBridge, undefined);
    assert.equal(f.window.fetch, f.originalFetch);
    assert.equal(f.messages.length, 0);
  }
});
test('unauthenticated target waits for real webpage login', () => {
  const f = fixture();
  assert.equal(f.window.IfengAdminBridge.openConversation({accountID:2, conversationID:123}), 'waiting');
  assert.equal(f.messages.at(-1).loggedIn, false);
});
test('successful existing request identifies active account without extra requests', async () => {
  const f = fixture();
  await f.authenticate();
  assert.equal(f.messages.at(-1).loggedIn, true);
  assert.equal(f.messages.at(-1).accountID, 2);
  assert.equal(f.requests.length, 1);
  assert.equal(f.window.IfengAdminBridge.openConversation({accountID:2, conversationID:123}), 'navigate');
});
test('fetch preserves promise payload, receiver and request arguments', async () => {
  const f = fixture();
  const receiver = {};
  const options = {method:'POST', body:'unchanged'};
  const response = await f.window.fetch.call(receiver, '/auth/sign_in', options);
  assert.equal((await response.json()).account_id, 2);
  assert.equal(f.requests[0].receiver, receiver);
  assert.equal(f.requests[0].args[1], options);
  await settle();
});
test('no credentials or message content cross the native bridge', async () => {
  const f = fixture();
  await f.authenticate();
  f.nodes.get('message-input').value = 'private unsent content';
  await f.mutate();
  const encoded = JSON.stringify(f.messages);
  for (const secret of ['private unsent content', 'access-token', 'password', 'headers', 'uid']) {
    assert.equal(encoded.includes(secret), false);
  }
  assert.deepEqual(Object.keys(f.messages.at(-1)).sort(), ['accountID','hasDraft','loggedIn','routeError','type']);
});
test('existing webpage notification listener is used when available', async () => {
  const f = fixture({worker:true});
  await f.authenticate();
  const requests = f.requests.length;
  assert.equal(f.window.IfengAdminBridge.openConversation({accountID:2, conversationID:123}), 'handled');
  assert.deepEqual(f.workerEvents, [{kind:'chat-server-admin-message', account_id:2, conversation_id:123}]);
  assert.equal(f.requests.length, requests);
});
test('actual existing website listener receives correct account and conversation', async () => {
  const f = fixture({worker:true});
  // 只读复制的现有网页通知模块作为契约快照，不会打包进 APP 或更改网站。
  const website = readFileSync(new URL('./fixtures/notifications-0.5.43.js', import.meta.url), 'utf8');
  vm.runInNewContext(website, f.context);
  const opened = [];
  f.window.ChatServerNotifications.attach({
    context: () => ({active:true, accountId:2, userId:1}),
    onOpen: target => opened.push(structuredClone(target))
  });
  await f.authenticate();
  assert.equal(f.window.IfengAdminBridge.openConversation({accountID:2, conversationID:123}), 'handled');
  assert.deepEqual(opened, [{account_id:2, conversation_id:123}]);
});
test('fallback navigation requests confirmation for text and image drafts', async () => {
  const f = fixture();
  await f.authenticate();
  f.nodes.get('message-input').value = 'unfinished';
  assert.equal(f.window.IfengAdminBridge.openConversation({accountID:2, conversationID:123}), 'needs-confirmation');
  f.nodes.get('message-input').value = '';
  f.nodes.get('agent-image-preview').hidden = false;
  assert.equal(f.window.IfengAdminBridge.openConversation({accountID:2, conversationID:123}), 'needs-confirmation');
});
test('account mismatch does not navigate or dispatch a message', async () => {
  const f = fixture({worker:true});
  await f.authenticate();
  assert.equal(f.window.IfengAdminBridge.openConversation({accountID:3, conversationID:123}), 'account-mismatch');
  assert.equal(f.workerEvents.length, 0);
});
test('invalid and imprecise conversation IDs are rejected', async () => {
  const f = fixture({worker:true});
  await f.authenticate();
  for (const conversationID of [0,-1,'bad',9007199254740992]) {
    assert.equal(f.window.IfengAdminBridge.openConversation({accountID:2, conversationID}), 'invalid');
  }
});
test('foreground resume closes old SSE and invokes existing recovery hooks without reload', () => {
  const f = fixture();
  const stream = new f.window.EventSource('/api/v1/realtime/events');
  const received = [];
  f.window.addEventListener('online', () => received.push('online'));
  f.window.addEventListener('pageshow', () => received.push('pageshow'));
  f.document.addEventListener('visibilitychange', () => received.push('visible'));
  f.window.IfengAdminBridge.resume();
  f.window.IfengAdminBridge.resume();
  assert.equal(stream.closeCount, 1);
  assert.equal(f.window.EventSource.CLOSED, 2);
  assert.equal(stream instanceof f.window.EventSource, true);
  assert.deepEqual(received, ['online','pageshow','visible','online','pageshow','visible']);
  assert.equal(f.requests.length, 0);
});
test('nonexistent conversation failures are surfaced as generic native metadata', async () => {
  const f = fixture();
  f.nodes.get('sync-status').textContent = '无法打开通知会话：not found';
  await f.mutate();
  assert.equal(f.messages.at(-1).routeError, true);
  assert.equal(JSON.stringify(f.messages).includes('not found'), false);
});
test('logout revokes bridge readiness and hides old account', async () => {
  const f = fixture();
  await f.authenticate();
  f.nodes.get('workspace').hidden = true;
  await f.mutate();
  assert.equal(f.messages.at(-1).accountID, null);
  assert.equal(f.window.IfengAdminBridge.openConversation({accountID:2, conversationID:123}), 'waiting');
});
