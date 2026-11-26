/* APP 专用界面；服务端 HTML、API 和普通网页均保持不变。 */
(() => {
  'use strict';
  if (!window.IfengAdminBridge || window.IfengAdminMobile) return;
  const css = __IFENG_CSS__;
  const $ = id => document.getElementById(id);
  let api = null, role = '', mounted = false, active = false, scheduled = false;
  let page = 'conversations', explicitPage = '', barkEpoch = 0, barkKnown = false;
  let barkEnabled = false, barkHasKey = false, barkBusy = false, initialFilter = false;
  let profile = {}, elements = {};
  const paths = {
    'message-circle-more': ['M2.992 16.342a2 2 0 0 1 .094 1.167l-1.065 3.29a1 1 0 0 0 1.236 1.168l3.413-.998a2 2 0 0 1 1.099.092 10 10 0 1 0-4.777-4.719','M8 12h.01','M12 12h.01','M16 12h.01'],
    inbox: ['M22 12h-6l-2 3h-4l-2-3H2','M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z'],
    settings: ['M9.671 4.136a2.34 2.34 0 0 1 4.659 0 2.34 2.34 0 0 0 3.319 1.915 2.34 2.34 0 0 1 2.33 4.033 2.34 2.34 0 0 0 0 3.831 2.34 2.34 0 0 1-2.33 4.033 2.34 2.34 0 0 0-3.319 1.915 2.34 2.34 0 0 1-4.659 0 2.34 2.34 0 0 0-3.32-1.915 2.34 2.34 0 0 1-2.33-4.033 2.34 2.34 0 0 0 0-3.831A2.34 2.34 0 0 1 6.35 6.051a2.34 2.34 0 0 0 3.319-1.915','M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0'],
    'list-filter': ['M3 6h18','M7 12h10','M10 18h4'],
    info: ['M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0','M12 16v-4','M12 8h.01'],
    'chevron-left': ['m15 18-6-6 6-6'],
    'log-out': ['m16 17 5-5-5-5','M21 12H9','M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4'],
    'user-round': ['M17 8a5 5 0 1 1-10 0 5 5 0 0 1 10 0','M20 21a8 8 0 0 0-16 0'],
    image: ['M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2','M11 9a2 2 0 1 1-4 0 2 2 0 0 1 4 0','m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21'],
    smile: ['M15 10V9','M16.472 15a6 6 0 0 1-8.943 0','M9 10V9','M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0'],
    send: ['M14.536 21.686a.5.5 0 0 0 .937-.024l6.5-19a.496.496 0 0 0-.635-.635l-19 6.5a.5.5 0 0 0-.024.937l7.93 3.18a2 2 0 0 1 1.112 1.11z','m21.854 2.147-10.94 10.939']
  };
  function icon(name) {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    for (const [key,value] of Object.entries({viewBox:'0 0 24 24', fill:'none',stroke:'currentColor','stroke-width':'1.65','stroke-linecap':'round','stroke-linejoin':'round','aria-hidden':'true',focusable:'false',class:'ifeng-icon'})) svg.setAttribute(key,value);
    svg.dataset.lucide = name;
    for (const d of paths[name] || []) {
      const path = document.createElementNS(svg.namespaceURI, 'path'); path.setAttribute('d',d); svg.append(path);
    }
    return svg;
  }
  function node(tag, className, text) {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (text !== undefined) element.textContent = text;
    return element;
  }
  function button(name, label, action, className = 'ifeng-circle') {
    const element = node('button', className); element.type = 'button';
    element.setAttribute('aria-label', label); element.append(icon(name));
    element.addEventListener('click', action); return element;
  }
  function text(element, value) { if (element && element.textContent !== value) element.textContent = value; }
  function attribute(element, name, value) { if (element && element.getAttribute(name) !== value) element.setAttribute(name, value); }
  function status(message) { text(elements.status, message); }

  // CSSOM 注入样式，不放宽后台的 style-src 'self' CSP，也不引入远程样式。
  function installStyle() {
    const sheet = new CSSStyleSheet();
    sheet.replaceSync(css);
    document.adoptedStyleSheets = [...document.adoptedStyleSheets,sheet];
    document.documentElement.classList.add('ifeng-mobile');
    document.documentElement.dataset.theme = 'light';
  }

  // 借用现有初始化传入的 request 闭包，继续使用原认证、权限及错误处理。
  // 不读取 LocalStorage 的 Token，不把认证材料传到 Swift，不改写服务端。
  let inboxModule;
  Object.defineProperty(window, 'InboxSettings', {
    configurable: true, enumerable: true,
    get: () => inboxModule,
    set(value) {
      inboxModule = value;
      if (!value?.init || value.__ifengWrapped) return;
      const init = value.init;
      value.init = function(options) {
        const result = init.call(this,options);
        api = options; role = options.role; barkKnown = false; barkEpoch++;
        renderBark(); schedule(); return result;
      };
      Object.defineProperty(value,'__ifengWrapped',{value:true});
    }
  });

  async function loadBark() {
    if (!api || role !== 'administrator' || barkBusy) return;
    const current = api, epoch = barkEpoch;
    barkBusy = true; renderBark();
    try {
      const data = await current.request(current.accountPath() + '/bark_settings');
      if (api !== current || epoch !== barkEpoch) return;
      barkKnown = true; barkEnabled = !!data.enabled; barkHasKey = !!data.has_key;
      status('');
    } catch { if (epoch === barkEpoch) status('Bark 设置加载失败，点击此行可重试。'); }
    finally { if (epoch === barkEpoch) { barkBusy = false; renderBark(); } }
  }
  function renderBark() {
    if (!elements.barkToggle) return;
    elements.barkToggle.checked = barkEnabled;
    elements.barkToggle.disabled = barkBusy || role !== 'administrator' || !barkKnown;
    attribute(elements.barkToggle, 'aria-busy', String(barkBusy));
  }
  async function changeBark() {
    if (!api || barkBusy || role !== 'administrator') return;
    const desired = elements.barkToggle.checked;
    if (desired && !barkHasKey) {
      elements.barkToggle.checked = false;
      $('bark-settings-button')?.click();
      return;
    }
    const current = api, epoch = barkEpoch, previousEnabled = barkEnabled;
    barkEnabled = desired;
    barkBusy = true; renderBark();
    try {
      const data = await current.request(current.accountPath() + '/bark_settings', {method:'PUT',body:{enabled:desired}});
      if (api !== current || epoch !== barkEpoch) return;
      barkEnabled = !!data.enabled; barkHasKey = !!data.has_key; status('');
    } catch { if (epoch === barkEpoch) { barkEnabled = previousEnabled; status('Bark 设置保存失败，请重试。'); } }
    finally { if (epoch === barkEpoch) { barkBusy = false; renderBark(); } }
  }

  function selectPage(next) {
    if (!active) return;
    $('message-input')?.blur(); document.activeElement?.blur();
    $('visitor-panel-close')?.click();
    if (next === 'inboxes') $('nav-inboxes')?.click();
    else {
      $('nav-chat')?.click(); $('back-button')?.click();
      if (next === 'settings') {
        // 保留网页对隐藏聊天页的输入状态/已读判断。
        $('workspace').classList.add('settings-open');
        loadBark();
      }
    }
    explicitPage = next === 'settings' ? next : '';
    elements.filterPopover.hidden = true;
    renderBark(); sync();
  }

  function mount() {
    if (mounted || !$('workspace') || !$('back-button')) return;
    installStyle(); mounted = true;
    const workspace = $('workspace');
    const header = node('header','ifeng-page-header'); header.id = 'ifeng-page-header';
    const title = node('h1','', '会话');
    const filter = button('list-filter','筛选会话', () => {
      elements.filterPopover.hidden = !elements.filterPopover.hidden;
      attribute(filter,'aria-expanded',String(!elements.filterPopover.hidden));
    });
    filter.id = 'ifeng-filter-button'; attribute(filter,'aria-expanded','false');
    attribute(filter,'aria-controls','ifeng-filter-popover');
    const popover = node('div','ifeng-filter-popover'); popover.id = 'ifeng-filter-popover'; popover.hidden = true;
    attribute(popover,'role','group'); attribute(popover,'aria-label','会话筛选');
    for (const [key,label] of [['open','待处理'],['resolved','已完成'],['all','全部']]) {
      const option = node('button','',label); option.type = 'button'; option.dataset.filterOption = key;
      option.addEventListener('click', () => {
        document.querySelector(`[data-filter="${key}"]`)?.click();
        popover.hidden = true; attribute(filter,'aria-expanded','false');
        sync(); filter.focus();
      }); popover.append(option);
    }
    header.append(title,filter,popover);
    const settings = node('section','ifeng-settings'); settings.id = 'ifeng-settings';
    attribute(settings,'aria-label','设置');
    const avatarRow = node('div','ifeng-setting-row ifeng-avatar-row');
    avatarRow.append(node('span','', '管理员头像'));
    const avatar = node('span','ifeng-admin-avatar'); avatar.append(icon('user-round')); avatarRow.append(avatar);
    const nameRow = node('div','ifeng-setting-row'); nameRow.append(node('span','','用户名'));
    const username = node('strong','ifeng-username',''); nameRow.append(username);
    const barkRow = node('div','ifeng-setting-row');
    const barkLabel = node('button','ifeng-bark-label','Bark 通知'); barkLabel.type='button';
    barkLabel.addEventListener('click', () => { if (role==='administrator') { if (!barkKnown) loadBark(); else $('bark-settings-button')?.click(); } });
    const toggle = node('input','ifeng-switch'); toggle.type='checkbox'; toggle.setAttribute('role','switch');
    attribute(toggle,'aria-label','开启 Bark 通知'); toggle.addEventListener('change',changeBark);
    barkRow.append(barkLabel,toggle);
    const logout = node('button','ifeng-setting-row ifeng-logout'); logout.type='button';
    logout.append(node('span','','退出登录'),icon('log-out'));
    logout.addEventListener('click', () => $('logout-button')?.click());
    settings.append(avatarRow,nameRow,barkRow,logout);
    const message = node('p','ifeng-setting-status'); attribute(message,'role','status'); settings.append(message);
    const dock = node('nav','ifeng-dock'); dock.id='ifeng-dock'; attribute(dock,'aria-label','主要导航');
    for (const [key,label,glyph] of [['conversations','会话','message-circle-more'],['inboxes','收件箱','inbox'],['settings','设置','settings']]) {
      const item = button(glyph,label,() => selectPage(key),'ifeng-dock-item'); item.dataset.page = key;
      dock.append(item);
    }
    const backdrop = node('button','ifeng-panel-backdrop'); backdrop.type='button';
    attribute(backdrop,'aria-label','关闭访客信息'); backdrop.addEventListener('click',()=> $('visitor-panel-close')?.click());
    workspace.append(header,settings,dock,backdrop);
    elements={header,title,filter,filterPopover:popover,settings,dock,avatar,username,barkToggle:toggle,status:message};
    $('back-button').replaceChildren(icon('chevron-left'));
    $('visitor-panel-toggle').replaceChildren(icon('info'));
    attribute($('visitor-panel-toggle'),'aria-label','访客信息和操作');
    document.querySelector('.visitor-panel-heading .eyebrow').textContent='访客信息';
    $('agent-emoji-button')?.replaceChildren(icon('smile'));
    const imageLabel=document.querySelector('label.agent-image-button');
    if(imageLabel) {
      for (const child of [...imageLabel.childNodes]) if(child!==$('agent-image-input')) child.remove();
      imageLabel.prepend(icon('image')); attribute(imageLabel,'aria-label','选择图片');
    }
    $('nav-chat').addEventListener('click',()=>{explicitPage='';schedule();});
    $('nav-inboxes').addEventListener('click',()=>{explicitPage='';schedule();});
    $('bark-dialog')?.addEventListener('close',()=>{if(page==='settings')loadBark();});
    document.addEventListener('click',event=>{if(!header.contains(event.target)) { popover.hidden=true; attribute(filter,'aria-expanded','false'); }});
    document.addEventListener('keydown',event=>{if(event.key==='Escape'){popover.hidden=true;attribute(filter,'aria-expanded','false');}});
    new MutationObserver(schedule).observe(workspace,{subtree:true,childList:true,characterData:true,attributes:true,attributeFilter:['hidden','class','aria-pressed','src','href']});
    sync();
  }

  function sync() {
    scheduled=false; if(!mounted)return;
    const workspace=$('workspace');
    const ready=!workspace.hidden;
    if (!ready) {
      if(active) {api=null;role='';barkEpoch++;barkBusy=false;barkKnown=false;initialFilter=false;profile={};}
      active=false; explicitPage=''; page='conversations';
      document.documentElement.removeAttribute('data-ifeng-page'); return;
    }
    active=true;
    // 外部通知/深度链接由网页先切换 nav-chat，可自然退出 APP 设置页。
    page=explicitPage || (workspace.classList.contains('settings-open') ? 'inboxes' : workspace.classList.contains('show-chat') ? 'chat' : 'conversations');
    attribute(document.documentElement,'data-ifeng-page',page);
    text(elements.title,({conversations:'会话',chat:'会话',inboxes:'收件箱',settings:'设置'})[page]);
    if(elements.filter.hidden !== (page!=='conversations'))elements.filter.hidden=page!=='conversations';
    for(const item of elements.dock.children) attribute(item,'aria-current',item.dataset.page===(page==='chat'?'conversations':page)?'page':'false');
    for(const option of elements.filterPopover.children) {
      const original=document.querySelector(`[data-filter="${option.dataset.filterOption}"]`);
      attribute(option,'aria-pressed',original?.getAttribute('aria-pressed')==='true'?'true':'false');
    }
    if(api&&!initialFilter) {initialFilter=true; document.querySelector('[data-filter="all"]')?.click();}
    text(elements.username,profile.name || $('current-user')?.textContent || '管理员');
    if (profile.avatar) {
      if(elements.avatar.firstElementChild?.getAttribute('src')!==profile.avatar) {
        const image=node('img'); image.src=profile.avatar; image.alt='管理员头像';
        image.addEventListener('error',()=>{elements.avatar.replaceChildren(icon('user-round'));profile.avatar='';},{once:true});
        elements.avatar.replaceChildren(image);
      }
    }
    for (const card of document.querySelectorAll('.conversation-card')) {
      const meta=card.querySelector('.card-meta > span');
      const id=meta?.textContent?.match(/#(\d+)/)?.[1];
      if(id&&!card.querySelector('.ifeng-conversation-id'))card.querySelector('.card-top')?.append(node('span','ifeng-conversation-id','#'+id));
    }
    const source=$('visitor-source'); let origin='';
    if(source&&!source.hidden)try{const url=new URL(source.href);if(['http:','https:'].includes(url.protocol))origin=url.origin+ (url.pathname==='/'?'':url.pathname);}catch{}
    text($('conversation-info'),origin?'来自 '+origin:'来源信息暂不可用');
  }
  function schedule() { if(!scheduled){scheduled=true;queueMicrotask(sync);} }
  window.IfengAdminMobile=Object.freeze({
    setProfile(value) {
      profile={name:typeof value?.name==='string'?value.name:''};
      try {const avatar=new URL(value?.avatar || '',location.origin); if(value?.avatar&&avatar.origin===location.origin&&avatar.protocol==='https:')profile.avatar=avatar.href;}catch{}
      schedule();
    }
  });
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',mount,{once:true});else mount();
})();
