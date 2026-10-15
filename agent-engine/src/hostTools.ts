import { createSdkMcpServer, tool } from '@anthropic-ai/claude-agent-sdk';
import { z } from 'zod';
import type { Peer } from './rpc';
const obj=z.record(z.string(),z.unknown()), app={app:z.string()}, record={collection:z.string(),record:obj,rev:z.number().optional()};
const definitions:[string,string,z.ZodRawShape][]=[
['apps_search','Discover installed application tools.',{query:z.string(),limit:z.number().optional()}],
['apps_describe','Read complete tool contracts or app skills before calling.',{app:z.string().optional(),tool:z.string().optional()}],
['apps_call','Call a tool using its input contract.',{tool:z.string(),args:obj}],
['apps_list','List installed applications and drafts.',{}],
['apps_create','Create a draft and assign its stable ID and namespace.',{title:z.string(),namespace:z.string()}],
['apps_commit','Run isolated contract tests then activate the candidate. Repair errors before retrying.',app],
['apps_diff','Compare validated versions or a version against the current draft. Returns bounded per-file before/after text and hashes.',{...app,from:z.string(),to:z.string().optional()}],
['apps_versions','List validated versions.',app],
['apps_rollback','Restore code while retaining all user data.',{...app,version:z.string()}],
['workspace_list','List source files.',app],
['workspace_read','Read a source file relative to the application root.',{...app,path:z.string()}],
['workspace_write','Write a complete UTF-8 source file or binary base64 asset, at most 2 MB. Supply exactly one of content/base64. Paths cannot escape the application root.',{...app,path:z.string(),content:z.string().optional(),base64:z.string().optional()}],
['workspace_remove','Remove a source file, not shared data.',{...app,path:z.string()}],
['data_query','Query shared data. Results carry source and privacy labels.',{collection:z.string(),text:z.string().optional(),where:obj.optional(),orderBy:z.string().optional(),limit:z.number().optional()}],
['data_get','Read a record.',{collection:z.string(),id:z.string()}],
['data_put','Create or update a record. Updates require the latest _rev.',record],
['data_delete','Soft delete at a specific revision.',{collection:z.string(),id:z.string(),rev:z.number()}],
['data_schemas','List shared data schemas.',{}],
['data_restore','Undo a recorded effect. Later overlapping edits return conflict.',{effectID:z.string()}],
['data_registerSchema','Register a new user collection.',{collection:z.string(),type:z.string(),definition:obj,private:z.boolean().optional()}],
['data_previewMigration','Validate a declarative user-schema migration against every record without writing. Installed dependents must be migrated together through apps.commit.',{schema:z.literal('agentos.migration/1'),collection:z.string(),fromVersion:z.number(),toVersion:z.number(),definition:obj,steps:z.array(obj)}],
['runtime_inspect','Read activated UI state, text and console.',app],
['runtime_input','Send key or click to an activated UI.',{...app,key:z.string().optional(),x:z.number().optional(),y:z.number().optional()}],
['system_call','Use system.describe to discover available system services, then call a documented method.',{method:z.string(),args:obj}],
['agent_build','Delegate creating or modifying an application to Builder.',{request:z.string(),app:z.string().optional()}],
];
export const hostToolNames=definitions.map(d=>d[0]);
export function hostServer(peer:Peer,runId:string){return createSdkMcpServer({name:'agentos',version:'1.0.0',tools:definitions.map(([name,description,schema])=>tool(name,description,schema,async args=>{
  try{const a=args as Record<string,unknown>, method=name==='system_call'?String(a.method):name.replace('_','.');const result=await peer.request('host/call',{runId,method,args:name==='system_call'?a.args:a},180000);return{content:[{type:'text' as const,text:JSON.stringify(result)}]};}
  catch(e:any){return{isError:true,content:[{type:'text' as const,text:String(e.message||e)}]};}
}))});}
