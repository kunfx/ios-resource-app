// 在真实网页源码上测试 APP 注入层，所有 API 使用内存 Mock，不访问服务器。
// IFENG_WEB_SOURCE=... IFENG_PLAYWRIGHT=... node ios-app/Tests/MobileUI.browser.mjs
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const require=createRequire(import.meta.url);
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const web=process.env.IFENG_WEB_SOURCE;
if(!web||!process.env.IFENG_PLAYWRIGHT)throw Error('Set IFENG_WEB_SOURCE and IFENG_PLAYWRIGHT for this integration test.');
const {chromium}=require(process.env.IFENG_PLAYWRIGHT);
const browser=await chromium.launch({headless:true,...(process.env.IFENG_BROWSER_CHANNEL?{channel:process.env.IFENG_BROWSER_CHANNEL}:{})});
const base='https://support.example.test';
const html=await fs.readFile(path.join(web,'index.html'),'utf8');
const bridge=(await fs.readFile(path.join(root,'IfengAdmin/Resources/AdminBridge.js'),'utf8')).replace('__ADMIN_ORIGIN__',JSON.stringify(base));
const mobile=(await fs.readFile(path.join(root,'IfengAdmin/Resources/MobileUI.js'),'utf8')).replace('__IFENG_CSS__',JSON.stringify(await fs.readFile(path.join(root,'IfengAdmin/Resources/MobileUI.css'),'utf8')));
const reports=[];
const user={id:1,name:'Admin',email:'admin@example.test',account_id:1,accounts:[{id:1,role:'administrator'}]};
const now=1795698000;
const names=['92016996@qq.com','Wu950408@Qq.Com','Usaxhi@Gmail.com'];
const makeMessage=(id,cid,content,type=0)=>({id,account_id:1,conversation_id:cid,content,message_type:type,content_type:'text',created_at:now+id,status:'sent',sender_id:type===0?cid:1,sender_type:type===0?'Contact':'User',sender:type===0?{id:cid,name:names[cid-11]||'访客',type:'contact'}:user,attachments:[]});
const messages=[makeMessage(101,11,'没有收到货，就在网站右上角【查询订单】'),makeMessage(102,11,'我帮您查看一下。',1)];
const conversations=names.map((name,i)=>({id:11+i,account_id:1,inbox_id:1,status:i===1?'resolved':'open',can_reply:true,visitor_messages_blocked:false,created_at:now,last_activity_at:now+101-i,meta:{sender:{id:11+i,name,thumbnail:'',type:'contact'},assignee:user},visitor_details:{ip_address:'203.0.113.1',city:'杭州',region:'浙江',country:'中国',source_url:'https://hktw.us/2/',browser:'Safari 18.0',operating_system:'iOS 18.0',language:'zh-CN'},messages:[makeMessage(101+i,11+i,i===0?'没有收到货，就在网站右上角【查询订单】':i===1?'没有了':'账户')],unread_count:i===0?1:0}));
const inbox={id:1,name:'网站客服',channel_type:'Channel::WebWidget',website_url:'https://hktw.us',selected_feature_flags:['attachments','emoji_picker'],visitor_input_label:'访客标题',visitor_input_placeholder:'请输入称呼',greeting_buttons:[],widget_color:'#267df1'};
let bark={enabled:false,has_key:true}, failBark=false, changes=[], errors=[], lists=[], page;
const assets=new Map([['/assets/markdown-it.min.js','vendor/markdown-it/markdown-it.min.js']]);
try {
  const context=await browser.newContext({viewport:{width:430,height:860},deviceScaleFactor:1,isMobile:true,hasTouch:true});
  page=await context.newPage(); page.on('pageerror',e=>errors.push(e.message));
  const csp=[]; page.on('console',m=>{if(m.type()==='error'&&m.text().includes('Content Security Policy'))csp.push(m.text());});
  await page.route('**/*',async route=>{
    const request=route.request(),url=new URL(request.url());
    if(url.origin!==base)return route.abort();
    const pathname=url.pathname;
    const json=(data,status=200,headers={})=>route.fulfill({status,headers:{'Content-Type':'application/json',...headers},body:JSON.stringify(data)});
    if(pathname==='/app/'||pathname==='/')return route.fulfill({contentType:'text/html',headers:{'Content-Security-Policy':"default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' blob:; connect-src 'self'; object-src 'none'"},body:html});
    if(pathname.startsWith('/assets/')||pathname.startsWith('/sounds/')) {
      const relative=assets.get(pathname)||pathname.replace(/^\/assets\//,'').replace(/^\//,'');
      try {return route.fulfill({contentType:relative.endsWith('.js')?'text/javascript':relative.endsWith('.css')?'text/css':relative.endsWith('.svg')?'image/svg+xml':'audio/mpeg',body:await fs.readFile(path.join(web,relative))});} catch{return route.fulfill({status:404,body:''});}
    }
    if(pathname==='/auth/sign_in')return json({data:user},200,{'access-token':'fixture-only','uid':user.email,client:'fixture-only'});
    if(pathname==='/api/v1/profile')return json(user);
    if(pathname==='/auth/sign_out')return json({});
    if(pathname.endsWith('/realtime/ticket'))return json({ticket:'fixture',events_url:'/api/v1/realtime/events'});
    if(pathname.endsWith('/realtime/events'))return route.fulfill({status:204,body:''});
    if(pathname.endsWith('/bark_settings')) {
      if(request.method()==='PUT'&&failBark)return json({error:'mock save failure'},500);
      if(request.method()==='PUT') {const body=request.postDataJSON(); changes.push({kind:'bark',body}); bark={enabled:body.enabled,has_key:bark.has_key||!!body.key};}
      return json(bark);
    }
    if(pathname.endsWith('/inboxes'))return json({payload:[inbox]});
    if(pathname.endsWith('/inboxes/1'))return json(inbox);
    if(pathname.endsWith('/conversations')) {
      const filter=url.searchParams.get('status'); lists.push(filter);
      return json({data:{payload:conversations.filter(c=>filter==='all'||c.status===filter),meta:{all_count:3}}});
    }
    const match=pathname.match(/\/conversations\/(\d+)(?:\/(.*))?$/);
    if(match) {
      const c=conversations.find(c=>c.id===Number(match[1])); if(!c)return json({error:'not found'},404);
      if(match[2]==='visitor_block') {const body=request.postDataJSON();changes.push({kind:'block',body}); c.visitor_messages_blocked=body.blocked;return json(c);}
      if(match[2]==='toggle_status'){const body=request.postDataJSON();c.status=body.status;return json({payload:{current_status:c.status}});}
      if(match[2]==='messages') {
        if(request.method()==='POST'){const body=request.postDataJSON(); const message=makeMessage(999,c.id,body.content,1);message.echo_id=body.echo_id;messages.push(message);changes.push({kind:'message',body});return json(message);}
        return json({payload:messages.filter(m=>m.conversation_id===c.id)});
      }
      if(match[2]==='message_receipts')return json({payload:[]});
      if(match[2]==='typing_status')return json({typing_status:'off'});
      if(match[2])return json({});
      return json(c);
    }
    return json({payload:[]});
  });
  await page.addInitScript({content:bridge+'\n'+mobile});
  await page.goto(base+'/app/');
  await page.locator('#email').fill(user.email);await page.locator('#password').fill('not-real-password');
  await page.locator('#login-button').click();
  await page.waitForFunction(()=>document.documentElement.dataset.ifengPage==='conversations');
  await page.waitForFunction(()=>document.querySelectorAll('.conversation-card').length===3);
  assert.equal(await page.locator('.topbar').isVisible(),false);
  assert.equal(await page.locator('#ifeng-page-header h1').innerText(),'会话');
  assert.equal(await page.locator('.ifeng-dock-item').count(),3);
  assert.ok(lists.includes('all'));
  assert.equal(await page.locator('.ifeng-dock-item svg').evaluateAll(nodes=>nodes.map(n=>n.dataset.lucide).join(',')),'message-circle-more,inbox,settings');
  assert.equal(await page.evaluate(()=>getComputedStyle(document.body).backgroundColor),'rgb(255, 255, 255)');
  assert.equal(csp.length,0,'CSS must work under existing strict CSP');
  reports.push('white list, three Lucide tabs, all-conversation default and strict CSP');
  if(process.env.IFENG_SCREENSHOTS){await fs.mkdir(process.env.IFENG_SCREENSHOTS,{recursive:true});await page.screenshot({path:path.join(process.env.IFENG_SCREENSHOTS,'conversations.png')});}
  await page.locator('#ifeng-filter-button').click();
  await page.locator('[data-filter-option=resolved]').click();
  await page.waitForFunction(()=>document.querySelectorAll('.conversation-card').length===1);
  assert.equal(await page.locator('[data-filter-option=resolved]').getAttribute('aria-pressed'),'true');
  await page.locator('#ifeng-filter-button').click();await page.locator('[data-filter-option=all]').click();
  await page.waitForFunction(()=>document.querySelectorAll('.conversation-card').length===3);
  await page.locator('.conversation-card').first().click();
  await page.waitForFunction(()=>document.documentElement.dataset.ifengPage==='chat');
  await page.locator('#message-items .chat-message').first().waitFor();
  assert.equal(await page.locator('#ifeng-dock').isVisible(),false);
  assert.equal(await page.locator('#contact-name').innerText(),names[0]);
  assert.equal(await page.locator('#conversation-info').innerText(),'来自 https://hktw.us/2/');
  await page.locator('#visitor-panel-toggle').click();await page.locator('#visitor-panel').waitFor();
  assert.equal(await page.locator('#visitor-os').innerText(),'iOS 18.0');
  assert.equal(await page.locator('#visitor-browser').innerText(),'Safari 18.0');
  await page.locator('#visitor-block-button').click();
  await page.waitForFunction(()=>document.getElementById('visitor-block-button').getAttribute('aria-pressed')==='true');
  await page.locator('#visitor-block-button').click();
  await page.waitForFunction(()=>document.getElementById('visitor-block-button').getAttribute('aria-pressed')==='false');
  await page.locator('#visitor-panel-close').click();
  await page.locator('.composer-editor-content').fill('APP 界面发送测试');
  await page.locator('#send-button').click();
  await page.waitForFunction(()=>document.querySelector('.composer-editor-content').textContent==='');
  assert.ok(changes.some(c=>c.kind==='message'&&c.body.content.includes('APP 界面发送测试')));
  reports.push('filter, chat title/source, visitor info, block/unblock and real webpage send handler');
  if(process.env.IFENG_SCREENSHOTS)await page.screenshot({path:path.join(process.env.IFENG_SCREENSHOTS,'chat.png')});
  await page.locator('.composer-editor-content').fill('跨标签页保留的草稿');
  await page.locator('#back-button').click();await page.locator('[data-page=settings]').click();
  await page.waitForFunction(()=>document.documentElement.dataset.ifengPage==='settings');
  await page.waitForFunction(()=>!document.querySelector('.ifeng-switch').disabled);
  assert.equal(await page.locator('.ifeng-setting-row').count(),4);
  assert.equal(await page.locator('.ifeng-username').innerText(),'Admin');
  await page.locator('.ifeng-switch').check();await page.waitForFunction(()=>document.querySelector('.ifeng-switch').checked);
  await page.waitForTimeout(100);
  assert.ok(changes.some(c=>c.kind==='bark'&&c.body.enabled===true));
  assert.equal(changes.find(c=>c.kind==='bark').body.key,undefined,'toggle preserves existing KEY');
  await page.locator('.ifeng-switch').uncheck();
  await page.waitForTimeout(100);
  assert.equal(bark.enabled,false);
  failBark=true;
  await page.locator('.ifeng-switch').check();
  await page.waitForFunction(()=>!document.querySelector('.ifeng-switch').disabled&&!document.querySelector('.ifeng-switch').checked);
  assert.match(await page.locator('.ifeng-setting-status').innerText(),/保存失败/);
  failBark=false;
  bark.has_key=false;
  await page.locator('.ifeng-bark-label').click();await page.locator('#bark-dialog').waitFor();
  await page.locator('#bark-close').click();
  await page.waitForFunction(()=>!document.querySelector('.ifeng-switch').disabled);
  await page.locator('.ifeng-switch').click();await page.locator('#bark-dialog').waitFor();
  assert.equal(bark.enabled,false,'no-key enable must show key setup');
  await page.locator('#bark-key').fill('fixture-key');await page.locator('#bark-enabled').check();await page.locator('#bark-save').click();
  await page.waitForFunction(()=>document.getElementById('bark-status').textContent.startsWith('已开启'));
  await page.locator('#bark-close').click();await page.waitForFunction(()=>document.querySelector('.ifeng-switch').checked);
  reports.push('settings four rows, live Bark toggle, existing KEY preserved, no-key setup uses original form');
  if(process.env.IFENG_SCREENSHOTS)await page.screenshot({path:path.join(process.env.IFENG_SCREENSHOTS,'settings.png')});
  await page.locator('[data-page=inboxes]').click();await page.locator('.inbox-card').waitFor();
  assert.equal(await page.locator('#ifeng-page-header h1').innerText(),'收件箱');
  await page.locator('.inbox-card button').click();await page.locator('#inbox-form').waitFor();
  assert.equal(await page.locator('#ib-name').inputValue(),'网站客服');
  reports.push('inbox list and original configuration form');
  await page.locator('[data-page=conversations]').click();await page.locator('.conversation-card').first().click();
  assert.equal(await page.locator('.composer-editor-content').innerText(),'跨标签页保留的草稿');
  await page.setViewportSize({width:844,height:390});
  assert.equal(await page.locator('#ifeng-dock').isVisible(),false);
  await page.locator('#visitor-panel-toggle').click();await page.locator('#visitor-panel').waitFor();
  await page.locator('#visitor-panel-close').click();await page.locator('#back-button').click();
  await page.setViewportSize({width:375,height:667});
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth),true);
  await page.locator('[data-page=settings]').click();await page.locator('.ifeng-logout').click();
  await page.locator('#login-view').waitFor();
  assert.equal(await page.locator('#ifeng-dock').isVisible(),false);
  assert.equal(await page.locator('#password').inputValue(),'');
  reports.push('landscape/compact layouts, logout and no horizontal overflow');
  assert.deepEqual(errors,[]);
  console.log(reports.map(x=>'PASS '+x).join('\n'));
  console.log('PASS no JavaScript page errors or CSP violations; no live server was contacted.');
} catch(error) {
  console.error({pageErrors:errors, state:page?await page.evaluate(()=>({page:document.documentElement.dataset.ifengPage,mobile:!!window.IfengAdminMobile,ready:document.getElementById('workspace')?.hidden,error:document.getElementById('login-error')?.textContent})):null});
  throw error;
} finally {await browser.close();}
