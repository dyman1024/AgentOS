(() => {
  const pending = new Map();
  addEventListener('aos-request', async e => {
    let request;
    try {
      if (typeof e.detail !== 'string' || e.detail.length > 2000000) return;
      request = JSON.parse(e.detail);
      const response = await webkit.messageHandlers.host.postMessage(request);
      dispatchEvent(new CustomEvent('aos-response',{detail:JSON.stringify({id:request.id,...response})}));
    } catch(error) {
      dispatchEvent(new CustomEvent('aos-response',{detail:JSON.stringify({id:request?.id,error:{code:'unavailable',message:String(error)}})}));
    }
  });
  addEventListener('aos-result', e => {
    try { const result=JSON.parse(e.detail), p=pending.get(result.id); if(p){pending.delete(result.id);clearTimeout(p.timer);p.resolve(result);} } catch {}
  });
  const invoke = (kind,name,args) => new Promise((resolve,reject)=>{
    const id=crypto.randomUUID();
    const timer=setTimeout(()=>{pending.delete(id);reject(new Error('Application timed out'));},30000);
    pending.set(id,{resolve,reject,timer});
    dispatchEvent(new CustomEvent('aos-invoke',{detail:JSON.stringify({id,kind,name,args})}));
  });
  Object.defineProperty(window,'__aosHost',{value:Object.freeze({invoke, click(x,y){const target=document.elementFromPoint(x,y);if(!target)throw new Error('No element');target.dispatchEvent(new MouseEvent('click',{bubbles:true,clientX:x,clientY:y}));}, key(key){for(const type of ['keydown','keyup'])(document.activeElement||document.body).dispatchEvent(new KeyboardEvent(type,{key,bubbles:true}));}, text(){return document.body.innerText.slice(0,12000);}})});
})();
