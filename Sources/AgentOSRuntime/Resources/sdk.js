(() => {
  const pending = new Map(), tools = new Map(), subscriptions = new Map();
  let exposed = () => null, frames = 0;
  const frame = () => { frames++; requestAnimationFrame(frame); }; requestAnimationFrame(frame);
  function rpc(method, args = {}) {
    return new Promise((resolve, reject) => {
      const id = crypto.randomUUID(), timer = setTimeout(() => { pending.delete(id); reject(Object.assign(new Error('Host request timed out'), {code:'timeout'})); }, 30000);
      pending.set(id, {resolve, reject, timer});
      dispatchEvent(new CustomEvent('aos-request', {detail:JSON.stringify({id, method, args})}));
    });
  }
  addEventListener('aos-response', e => {
    try {
      const r = JSON.parse(e.detail), p = pending.get(r.id); if (!p) return;
      pending.delete(r.id); clearTimeout(p.timer);
      r.error ? p.reject(Object.assign(new Error(r.error.message), r.error)) : p.resolve(r.result);
    } catch {}
  });
  addEventListener('aos-invoke', async e => {
    let request;
    try {
      request = JSON.parse(e.detail);
      let result;
      if (request.kind === 'tool') {
        const fn = tools.get(request.name); if (!fn) throw Object.assign(new Error('Tool handler missing'), {code:'unavailable'});
        result = await fn(request.args);
      } else if (request.kind === 'event') {
        const fn = subscriptions.get(request.name); if (!fn) throw new Error('Subscription handler missing');
        await fn(request.args); result = {ok:true};
      } else if (request.kind === 'state') result = {state:await exposed(),frames};
      else throw new Error('Unknown invocation');
      dispatchEvent(new CustomEvent('aos-result', {detail:JSON.stringify({id:request.id,result:result === undefined ? null : result})}));
    } catch (error) {
      dispatchEvent(new CustomEvent('aos-result', {detail:JSON.stringify({id:request?.id,error:{code:error.code||'app_error',message:String(error.message||error)}})}));
    }
  });
  const collection = name => Object.freeze({
    get:id=>rpc('data.get',{collection:name,id}),
    query:(options={})=>rpc('data.query',{...options,collection:name}),
    put:(record, options={})=>rpc('data.put',{collection:name,record,rev:options.rev??record._rev}),
    delete:(id,options={})=>rpc('data.delete',{collection:name,id,rev:options.rev}),
    history:id=>rpc('data.history',{collection:name,id})
  });
  const serviceGroup = (name, methods) => Object.freeze(Object.fromEntries(methods.map(method=>[method,args=>rpc(name+'.'+method,args||{})])));
  const sdk = Object.freeze({
    wasm:Object.freeze({async load(path,imports={}) {
      const url=new URL(path,location.href);
      if(url.protocol!=='agentos:'||url.host!==location.host||url.username||url.password) throw new Error('WASM must be an application asset');
      const response=await fetch(url.href);if(!response.ok)throw new Error('WASM asset unavailable');
      const bytes=await response.arrayBuffer();if(bytes.byteLength>10000000)throw new Error('WASM module exceeds 10 MB');
      return (await WebAssembly.instantiate(bytes,imports)).instance.exports;
    }}),
    backend:Object.freeze({call:(method,args={})=>rpc('backend.call',{method,args})}),
    net:serviceGroup('net',['fetch']),web:serviceGroup('web',['fetch','search']),
    mail:serviceGroup('mail',['accounts','list','search','get','send']),
    calendar:serviceGroup('calendar',['calendars','list','create','undo']),contacts:serviceGroup('contacts',['list','search']),
    files:serviceGroup('files',['listFolders','list','read','write','mkdir','trash','undo']),
    media:serviceGroup('media',['scan','metadata','play','pause','resume','seek','stop','status']),
    ai:serviceGroup('ai',['complete','embed']),agent:Object.freeze({ask:task=>rpc('agent.ask',{task})}),
    browser:Object.freeze({open:url=>rpc('browser.open',{url})}),clipboard:serviceGroup('clipboard',['read','write']),
    notify:args=>rpc('notify',args),
    tools:Object.freeze({register(name,fn){ if(typeof fn!=='function'||tools.has(name)) throw new Error('Invalid or duplicate handler'); tools.set(name,fn); return rpc('tools.register',{name}).catch(e=>{tools.delete(name);console.error(e);throw e;}); }}),
    self:Object.freeze({call:(name,args={})=>rpc('self.call',{name,args})}),
    call:(tool,args={})=>rpc('apps.call',{tool,args}),
    data:Object.freeze({collection}),
    events:Object.freeze({subscribe(pattern,fn){subscriptions.set(pattern,fn);return rpc('events.subscribe',{pattern});},emit:(type,data)=>rpc('events.emit',{type,data})}),
    service:(name,args={})=>rpc(name,args),
    expose(fn){exposed=fn;}
  });
  Object.defineProperty(window,'agentos',{value:sdk,writable:false,configurable:false});
  for(const level of ['log','warn','error']) {
    const original=console[level].bind(console);
    console[level]=(...args)=>{original(...args);rpc('console',{level,message:args.map(v=>typeof v==='string'?v:JSON.stringify(v)).join(' ').slice(0,4000)}).catch(()=>{});};
  }
  addEventListener('error',e=>rpc('console',{level:'error',message:e.message}).catch(()=>{}));
  addEventListener('unhandledrejection',e=>rpc('console',{level:'error',message:String(e.reason)}).catch(()=>{}));
})();
