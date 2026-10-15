import { expect, test } from 'bun:test';
import { spawn } from 'node:child_process';
import readline from 'node:readline';

test('contract failure details reach the repair loop with a bounded diagnostic', async () => {
  const source = `import {Peer} from './src/rpc.ts'; const peer=new Peer();
    peer.request('contract',{}).catch(error=>{console.log(JSON.stringify({observed:error.message}));process.exit(0)});`;
  const child = spawn(process.execPath, ['-e', source], { cwd: process.cwd(), stdio: ['pipe', 'pipe', 'pipe'] });
  const lines = readline.createInterface({ input: child.stdout });
  try {
    const message = await new Promise<string>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('RPC test timed out')), 5000);
      child.on('error', error => { clearTimeout(timer); reject(error); });
      lines.on('line', line => {
        const value = JSON.parse(line);
        if (value.method) child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: value.id, error: {
          message: 'Contract failed', data: { case: 'revision conflict', diagnostic: 'x'.repeat(20000) },
        } }) + '\n');
        if (value.observed) { clearTimeout(timer); resolve(value.observed); }
      });
    });
    expect(message).toStartWith('Contract failed\n');
    expect(message).toContain('revision conflict');
    expect(message.length).toBeLessThanOrEqual('Contract failed\n'.length + 16000);
  } finally { lines.close(); child.kill(); }
});
