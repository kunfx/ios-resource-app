/* Page-triggered desktop notifications. No Push API or background message source. */
'use strict';
(() => {
 const kind='chat-server-admin-message';
 const positive=value=>Number.isSafeInteger(Number(value))&&Number(value)>0;
 function targetURL(target){return positive(target?.account_id)&&positive(target?.conversation_id)?'/app/?account_id='+Number(target.account_id)+'&conversation_id='+Number(target.conversation_id):null;}
 function targetFromURL(value){try{const url=new URL(value,location.origin);if(url.origin!==location.origin||!['/','/app','/app/'].includes(url.pathname))return null;const target={account_id:Number(url.searchParams.get('account_id')),conversation_id:Number(url.searchParams.get('conversation_id'))};return targetURL(target)?target:null;}catch{return null;}}
 function attach({context,onOpen}){
  let prompted=false,registration=null,registering=false;const notes=new Set();
  const current=()=>{const c=context();return c?.active&&positive(c.accountId)&&positive(c.userId)?c:null;};
  const scope=c=>Number(c.accountId)+':'+Number(c.userId);
  const supported=()=>window.isSecureContext===true&&typeof window.Notification==='function';
  try{prompted=localStorage.getItem('chat-server.notifications.prompted.v1')==='1';}catch{}
  function prepareWorker(){
   if(!supported()||registration||registering||!window.navigator?.serviceWorker)return;
   registering=true;
   try{Promise.resolve(window.navigator.serviceWorker.register('/admin-notification-sw.js',{scope:'/app/'})).then(reg=>{registration=reg;}).catch(()=>{}).finally(()=>{registering=false;});}catch{registering=false;}
  }
  function gesture(event){
   if(event.isTrusted!==true||!current()||!supported())return;
   if(event.type==='keydown'&&!['Enter',' '].includes(event.key))return;
   const api=window.Notification;
   if(api.permission==='granted'){prepareWorker();return;}
   if(api.permission!=='default'||prompted)return;
   prompted=true;try{localStorage.setItem('chat-server.notifications.prompted.v1','1');}catch{}
   // Invoke in this trusted interaction, not after an asynchronous login or SSE.
   try{const pending=api.requestPermission(result=>{if(result==='granted')prepareWorker();});if(pending?.then)pending.then(result=>{if(result==='granted')prepareWorker();}).catch(()=>{});}catch{}
  }
  document.addEventListener('click',gesture,true);document.addEventListener('keydown',gesture,true);
  function navigate(target,owner){
   const url=targetURL(target);if(!url)return;
   const c=current();
   try{window.focus();}catch{}
   if(!c||owner&&scope(c)!==owner){try{window.location.assign(url);}catch{}return;}
   try{Promise.resolve(onOpen(target)).catch(()=>{});}catch{}
  }
  try{window.navigator?.serviceWorker?.addEventListener('message',event=>{
   if(event.data?.kind!==kind)return;
   const target={account_id:event.data.account_id,conversation_id:event.data.conversation_id};
   if(!targetURL(target))return;
   const owner=positive(event.data.user_id)?Number(target.account_id)+':'+Number(event.data.user_id):'';
   navigate(target,owner);
  });}catch{}
  function closePersistent(owner){
   if(!registration?.getNotifications)return;
   try{registration.getNotifications().then(items=>{for(const item of items)if(item.tag?.startsWith('chat-server:'+owner+':'))item.close();}).catch(()=>{});}catch{}
  }
  function stop(){const c=current();for(const n of notes)try{n.close();}catch{}notes.clear();if(c)closePersistent(scope(c));}
  window.addEventListener('pagehide',()=>{for(const n of notes)try{n.close();}catch{}notes.clear();});
  function created(data){
   const c=current();if(!c||!supported()||window.Notification.permission!=='granted'||data?.message_type!==0||!positive(data.message_id)||!positive(data.conversation_id))return;
   if(data.account_id!==undefined&&Number(data.account_id)!==Number(c.accountId))return;
   if(c.viewingConversation&&Number(c.selectedConversationId)===Number(data.conversation_id))return;
   const owner=scope(c),target={account_id:Number(c.accountId),conversation_id:Number(data.conversation_id)},tag='chat-server:'+owner+':'+Number(data.message_id);
   const options={body:'收到一条新消息，请及时查看',icon:'/assets/notification-icon.svg',tag,silent:true,data:{kind,...target,user_id:Number(c.userId)}};
   function fallback(){
    const live=current();if(!live||scope(live)!==owner)return;
    try{const n=new window.Notification('在线客服',options);notes.add(n);n.onclose=()=>notes.delete(n);n.onclick=()=>{try{n.close();}catch{}notes.delete(n);navigate(target,owner);};n.onerror=()=>{try{n.close();}catch{}notes.delete(n);};}catch{}
   }
   if(registration?.active&&typeof registration.showNotification==='function'){
    try{registration.showNotification('在线客服',options).then(()=>{const live=current();if(!live||scope(live)!==owner)closePersistent(owner);}).catch(fallback);}catch{fallback();}
   }else{prepareWorker();fallback();}
  }
  if(supported()&&window.Notification.permission==='granted')prepareWorker();
  return Object.freeze({created,stop});
 }
 window.ChatServerNotifications=Object.freeze({attach,targetURL,targetFromURL});
})();
