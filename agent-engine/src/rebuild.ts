import {query,type SDKMessage} from '@anthropic-ai/claude-agent-sdk';
import {Peer,log} from './rpc';
import {hostServer,hostToolNames} from './hostTools';
import {systemPrompt} from './rebuildPrompt';
type Prompt={runId:string,sessionId?:string,role:'operator'|'builder',appId?:string,text:string,cwd:string,model:string,effort?:'low'|'medium'|'high'|'xhigh'|'max',maxBudgetUsd:number};
const active=new Map<string,AbortController>();
const shutdown=()=>{for(const abort of active.values())abort.abort();setTimeout(()=>process.exit(0),2000).unref();};
const peer=new Peer(shutdown);
for(const signal of ['SIGTERM','SIGINT'] as const)process.on(signal,shutdown);
peer.onNotification('session/cancel',p=>active.get(p.runId)?.abort());
peer.onRequest('session/prompt',async(p:Prompt)=>{
 if(active.has(p.runId))throw new Error('Run already active');
 const abort=new AbortController();active.set(p.runId,abort);
 const emit=(update:unknown)=>peer.notify('session/update',{runId:p.runId,update});
 let result:any,sessionId=p.sessionId,fatal:string|undefined;
 try{
  const stream=query({prompt:p.text,options:{cwd:p.cwd,model:p.model,effort:p.effort,systemPrompt:systemPrompt(p.role,p.appId),tools:[],allowedTools:hostToolNames.map(n=>`mcp__agentos__${n}`),permissionMode:'dontAsk',mcpServers:{agentos:hostServer(peer,p.runId)},settingSources:[],includePartialMessages:true,resume:p.sessionId,maxTurns:100,maxBudgetUsd:p.maxBudgetUsd,abortController:abort,pathToClaudeCodeExecutable:process.env.AGENTOS_CLAUDE_BIN||undefined,canUseTool:async(name,input)=>name.startsWith('mcp__agentos__')?{behavior:'allow',updatedInput:input}:{behavior:'deny',message:'Use host-owned tools'},stderr:d=>log('[sdk]',d.trimEnd())}});
  for await(const message of stream){const m:SDKMessage=message;
   if(m.type==='system'&&m.subtype==='init'){sessionId=m.session_id;emit({kind:'session_started',sessionId});}
   else if(m.type==='system'&&m.subtype==='api_retry'){if(['authentication_failed','billing_error','model_not_found','account_on_hold','invalid_request'].includes(m.error)||[401,402,403,404].includes(m.error_status??0)){fatal=`API failed: ${m.error}`;abort.abort();}else emit({kind:'retry',attempt:m.attempt});}
   else if(m.type==='stream_event'&&!m.parent_tool_use_id){const e:any=m.event;if(e.type==='content_block_delta'&&e.delta?.type==='text_delta')emit({kind:'text_delta',text:e.delta.text});}
   else if(m.type==='assistant'&&!m.parent_tool_use_id){for(const b of m.message.content as any[])if(b.type==='tool_use')emit({kind:'tool_call',name:b.name,toolUseId:b.id});}
   else if(m.type==='result')result=m;
  }
  if(fatal)throw new Error(fatal);if(!result&&!abort.signal.aborted)throw new Error('Agent ended without a result');
  return{sessionId,cancelled:abort.signal.aborted,isError:!!result?.is_error||result?.subtype!=='success',text:result?.result||(result?.errors||[]).join('\n'),costUsd:result?.total_cost_usd??null};
 }catch(e){if(fatal)throw new Error(fatal);if(abort.signal.aborted)return{sessionId,cancelled:true,costUsd:result?.total_cost_usd??null};throw e;}finally{active.delete(p.runId);}
});
log('[engine] host interface ready');
