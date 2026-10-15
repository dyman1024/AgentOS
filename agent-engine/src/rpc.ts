// JSON-RPC 2.0 over newline-delimited JSON on stdin/stdout.
// stdout is reserved for protocol messages; diagnostics go to stderr via `log`.
import readline from 'node:readline';

type RequestHandler = (params: any) => Promise<unknown>;
type NotificationHandler = (params: any) => void;

export const log = (...args: unknown[]) => {
  process.stderr.write(args.map((a) => (typeof a === 'string' ? a : JSON.stringify(a))).join(' ') + '\n');
};

export class Peer {
  private nextId = 1;
  private pending = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
  private requestHandlers = new Map<string, RequestHandler>();
  private notificationHandlers = new Map<string, NotificationHandler>();

  constructor(onClose: () => void = () => process.exit(0)) {
    const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
    rl.on('line', (line) => void this.onLine(line));
    rl.on('close', onClose);
  }

  onRequest(method: string, handler: RequestHandler) {
    this.requestHandlers.set(method, handler);
  }

  onNotification(method: string, handler: NotificationHandler) {
    this.notificationHandlers.set(method, handler);
  }

  request<T = any>(method: string, params: unknown, timeoutMs = 120_000): Promise<T> {
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Host did not answer ${method} within ${timeoutMs} ms`));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: (v) => (clearTimeout(timer), resolve(v)),
        reject: (e) => (clearTimeout(timer), reject(e)),
      });
      this.send({ jsonrpc: '2.0', id, method, params });
    });
  }

  notify(method: string, params: unknown) {
    this.send({ jsonrpc: '2.0', method, params });
  }

  private send(msg: unknown) {
    process.stdout.write(JSON.stringify(msg) + '\n');
  }

  private async onLine(line: string) {
    if (!line.trim()) return;
    let msg: any;
    try {
      msg = JSON.parse(line);
    } catch {
      log('[rpc] dropped malformed line:', line.slice(0, 200));
      return;
    }

    if (typeof msg.method === 'string') {
      const params = msg.params ?? {};
      if (msg.id === undefined || msg.id === null) {
        this.notificationHandlers.get(msg.method)?.(params);
        return;
      }
      const handler = this.requestHandlers.get(msg.method);
      if (!handler) {
        this.send({ jsonrpc: '2.0', id: msg.id, error: { code: -32601, message: `Unknown method ${msg.method}` } });
        return;
      }
      try {
        const result = await handler(params);
        this.send({ jsonrpc: '2.0', id: msg.id, result: result ?? null });
      } catch (e: any) {
        this.send({ jsonrpc: '2.0', id: msg.id, error: { code: -32000, message: String(e?.message ?? e) } });
      }
      return;
    }

    const waiter = this.pending.get(msg.id);
    if (!waiter) return;
    this.pending.delete(msg.id);
    if (msg.error) {
      const detail = msg.error.data == null ? '' : '\n' + JSON.stringify(msg.error.data).slice(0, 16000);
      waiter.reject(new Error((msg.error.message ?? 'Host error') + detail));
    }
    else waiter.resolve(msg.result);
  }
}
