import {mkdir,readFile,writeFile,copyFile} from 'node:fs/promises';import path from 'node:path';
const root=path.resolve(import.meta.dir,'../Sources/AgentOSRuntime/Resources/Library');await mkdir(root,{recursive:true});
// WebKit isolated worlds cannot reliably read a Blob created in that world.
// Keep the parser's byte assembly in memory; do not enable network/blob access.
const mailMemoryPlugin={name:'mail-memory-chunks',setup(build){build.onLoad({filter:/postal-mime.*(chunk-writer|pass-through-decoder)\.js$/},async ({path:sourcePath})=>{
 let source=await readFile(sourcePath,'utf8');
 const original="return blobToArrayBuffer(new Blob(this.chunks, { type: 'application/octet-stream' }));";
 if(!source.includes(original))throw new Error('Postal MIME chunk writer changed; review the isolated parser patch');
 source=source.replace(original,"const output = new Uint8Array(this.chunks.reduce((size, chunk) => size + chunk.length, 0)); let offset = 0; for (const chunk of this.chunks) { output.set(chunk, offset); offset += chunk.length; } return Promise.resolve(output.buffer);");
 return {contents:source,loader:'js'};
});}};
const modules=['ui','markdown','editor','readability','mail','chart','game','three','physics'];
for(const name of modules){const result=await Bun.build({entrypoints:[path.join(import.meta.dir,name+'.js')],target:'browser',plugins:name==='mail'?[mailMemoryPlugin]:[],format:['readability','mail'].includes(name)?'iife':'esm',minify:true});if(!result.success)throw new Error(result.logs.join('\n'));await writeFile(path.join(root,name+'.js'),await result.outputs[0].text());}
await copyFile(path.join(import.meta.dir,'tokens.css'),path.join(root,'tokens.css'));
const pkg=JSON.parse(await readFile(path.join(import.meta.dir,'package.json'),'utf8'));await writeFile(path.join(root,'versions.json'),JSON.stringify(pkg.dependencies,null,2));
let licenses='AgentOS bundled UI libraries\n\n';for(const name of Object.keys(pkg.dependencies)){const folder=path.join(import.meta.dir,'node_modules',name);for(const file of ['LICENSE','LICENSE.txt','LICENSE.md','license','LICENSE-MIT']){try{licenses+='\n--- '+name+' ---\n'+await readFile(path.join(folder,file),'utf8');break;}catch{}}}
await writeFile(path.join(root,'LICENSES.txt'),licenses);console.log('Built '+modules.length+' pinned browser modules');
