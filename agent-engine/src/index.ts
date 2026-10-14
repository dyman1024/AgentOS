// AgentOS agent engine: a sidecar process the Swift host talks to over stdio (JSON-RPC 2.0, NDJSON).
//
// Host -> engine
//   request      session/prompt  { appId, appDir, text, sessionId?, model, effort, maxBudgetUsd? } -> PromptResult
//   notification session/cancel  { appId }
// Engine -> host
//   notification session/update  { appId, update: SessionUpdate }
//   request      runtime/<tool>  { appId, ...args }   (see runtimeTools.ts)
import path from 'node:path';
import { query, type HookCallback, type SDKMessage } from '@anthropic-ai/claude-agent-sdk';
import { Peer, log } from './rpc';
import { NO_VISION_NOTE, SYSTEM_PROMPT } from './prompt';
import { makeRuntimeServer, RUNTIME_SERVER, runtimeToolNames } from './runtimeTools';
import { extractPartialString } from './partialJson';

type PromptParams = {
  appId: string;
  appDir: string;
  text: string;
  sessionId?: string | null;
  model?: string;
  /** Claude-only parameter; the host sends null for other models (e.g. via OpenRouter). */
  effort?: 'low' | 'medium' | 'high' | 'xhigh' | 'max' | null;
  /** Whether the model accepts images; false removes the screenshot tool. */
  vision?: boolean;
  maxBudgetUsd?: number;
};

const FILE_TOOLS = ['Read', 'Write', 'Edit', 'Glob'];
const PROGRESS_INTERVAL_MS = 200;
const TAIL_LINES = 40;

const peer = new Peer();
const running = new Map<string, AbortController>();

peer.onNotification('session/cancel', ({ appId }: { appId: string }) => running.get(appId)?.abort());

peer.onRequest('session/prompt', async (p: PromptParams) => {
  const appDir = path.resolve(p.appDir);
  const vision = p.vision ?? true;
  running.get(p.appId)?.abort();
  const abort = new AbortController();
  running.set(p.appId, abort);

  const update = (u: Record<string, unknown>) => peer.notify('session/update', { appId: p.appId, update: u });
  const relative = (fp: string) => path.relative(appDir, path.resolve(appDir, fp));
  const insideApp = (fp: string) => {
    const abs = path.resolve(appDir, fp);
    return abs === appDir || abs.startsWith(appDir + path.sep);
  };

  const confineToApp: HookCallback = async (input) => {
    if (input.hook_event_name !== 'PreToolUse') return {};
    const ti = input.tool_input as { file_path?: unknown; path?: unknown };
    const fp = ti?.file_path ?? ti?.path;
    if (typeof fp === 'string' && !insideApp(fp)) {
      return {
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'deny',
          permissionDecisionReason: `Only files inside the app folder are accessible: ${fp}`,
        },
      };
    }
    return {};
  };

  const reportFileChange: HookCallback = async (input) => {
    if (input.hook_event_name === 'PostToolUse') {
      const fp = (input.tool_input as { file_path?: string })?.file_path;
      if (fp) update({ kind: 'file_changed', path: relative(fp) });
    }
    return {};
  };

  // Tool-call input streams in as partial JSON; surface the code being written as it arrives.
  type Stream = { id: string; name: string; json: string; lastEmit: number };
  const streams = new Map<number, Stream>();
  const emitProgress = (s: Stream) => {
    if (s.name !== 'Write' && s.name !== 'Edit') return;
    const body = extractPartialString(s.json, s.name === 'Write' ? 'content' : 'new_string');
    if (body === undefined) return;
    const filePath = extractPartialString(s.json, 'file_path');
    const lines = body.split('\n');
    update({
      kind: 'tool_progress',
      toolUseId: s.id,
      name: s.name,
      path: filePath ? relative(filePath) : undefined,
      chars: body.length,
      lines: lines.length,
      tail: lines.slice(-TAIL_LINES).join('\n'),
    });
    s.lastEmit = Date.now();
  };

  let sessionId = p.sessionId ?? undefined;
  let result: any;
  // Claude Code keeps retrying some failures (e.g. 401 behind a gateway) for minutes; errors in this
  // set will not fix themselves, so stop at the first retry and report them right away.
  const FATAL = new Set(['authentication_failed', 'billing_error', 'model_not_found', 'account_on_hold', 'invalid_request']);
  let fatalError: string | undefined;

  const handle = (m: SDKMessage) => {
    switch (m.type) {
      case 'system':
        if (m.subtype === 'init') {
          sessionId = m.session_id;
          update({ kind: 'session_started', sessionId, model: m.model, apiKeySource: m.apiKeySource });
        } else if (m.subtype === 'api_retry') {
          const status = m.error_status;
          if (FATAL.has(m.error) || status === 401 || status === 402 || status === 403 || status === 404) {
            fatalError = `API request failed: ${m.error}${status ? ` (HTTP ${status})` : ''}`;
            abort.abort();
          } else {
            update({ kind: 'api_retry', attempt: m.attempt, maxRetries: m.max_retries, status, error: m.error, delayMs: m.retry_delay_ms });
          }
        }
        break;

      case 'stream_event': {
        if (m.parent_tool_use_id) break;
        const ev: any = m.event;
        if (ev.type === 'message_start') {
          streams.clear();
        } else if (ev.type === 'content_block_start' && ev.content_block?.type === 'tool_use') {
          const s = { id: ev.content_block.id, name: ev.content_block.name, json: '', lastEmit: 0 };
          streams.set(ev.index, s);
          update({ kind: 'tool_start', toolUseId: s.id, name: s.name });
        } else if (ev.type === 'content_block_delta') {
          if (ev.delta?.type === 'text_delta') {
            update({ kind: 'text_delta', text: ev.delta.text });
          } else if (ev.delta?.type === 'input_json_delta') {
            const s = streams.get(ev.index);
            if (s) {
              s.json += ev.delta.partial_json;
              if (Date.now() - s.lastEmit >= PROGRESS_INTERVAL_MS) emitProgress(s);
            }
          }
        } else if (ev.type === 'content_block_stop') {
          const s = streams.get(ev.index);
          if (s) emitProgress(s);
          streams.delete(ev.index);
        }
        break;
      }

      case 'assistant':
        if (m.parent_tool_use_id) break;
        for (const block of m.message.content as any[]) {
          if (block.type !== 'tool_use') continue;
          update({ kind: 'tool_call', toolUseId: block.id, name: block.name, input: summarizeInput(block.name, block.input, relative) });
        }
        break;

      case 'user': {
        if (m.parent_tool_use_id) break;
        const content = (m.message as any).content;
        if (!Array.isArray(content)) break;
        for (const block of content) {
          if (block.type !== 'tool_result') continue;
          update({ kind: 'tool_result', toolUseId: block.tool_use_id, isError: !!block.is_error, text: resultText(block.content) });
        }
        break;
      }

      case 'result':
        result = m;
        break;
    }
  };

  const started = Date.now();
  try {
    const q = query({
      prompt: p.text,
      options: {
        cwd: appDir,
        model: p.model ?? 'claude-opus-5-5',
        effort: p.effort ?? undefined,
        systemPrompt: vision ? SYSTEM_PROMPT : SYSTEM_PROMPT + NO_VISION_NOTE,
        tools: FILE_TOOLS,
        allowedTools: [...FILE_TOOLS, ...runtimeToolNames(vision).map((n) => `mcp__${RUNTIME_SERVER}__${n}`)],
        permissionMode: 'dontAsk',
        mcpServers: { [RUNTIME_SERVER]: makeRuntimeServer(peer, p.appId, vision) },
        hooks: {
          PreToolUse: [{ hooks: [confineToApp] }],
          PostToolUse: [{ matcher: 'Write|Edit', hooks: [reportFileChange] }],
        },
        settingSources: [],
        includePartialMessages: true,
        resume: p.sessionId ?? undefined,
        maxTurns: 60,
        maxBudgetUsd: p.maxBudgetUsd,
        abortController: abort,
        pathToClaudeCodeExecutable: process.env.AGENTOS_CLAUDE_BIN || undefined,
        stderr: (d) => log('[claude]', d.trimEnd()),
      },
    });
    for await (const m of q) handle(m);
  } catch (e: any) {
    if (fatalError) throw new Error(fatalError);
    if (abort.signal.aborted) {
      return { sessionId, cancelled: true, isError: false, durationMs: Date.now() - started };
    }
    log('[engine] query failed:', e?.stack ?? String(e));
    throw e;
  } finally {
    if (running.get(p.appId) === abort) running.delete(p.appId);
  }

  if (fatalError) throw new Error(fatalError);
  if (!result) throw new Error('Agent ended without a result');
  return {
    sessionId: result.session_id ?? sessionId,
    cancelled: false,
    isError: result.is_error || result.subtype !== 'success',
    subtype: result.subtype,
    resultText: result.result ?? (result.errors ?? []).join('\n'),
    costUsd: result.total_cost_usd,
    durationMs: result.duration_ms ?? Date.now() - started,
    numTurns: result.num_turns,
    usage: result.usage,
  };
});

// Strip bulky fields (file contents) from tool inputs before they reach the chat UI.
function summarizeInput(name: string, input: any, relative: (fp: string) => string) {
  if (!input || typeof input !== 'object') return input;
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(input)) {
    if (k === 'file_path' && typeof v === 'string') out.path = relative(v);
    else if ((k === 'content' || k === 'old_string' || k === 'new_string') && typeof v === 'string') out[`${k}_lines`] = v.split('\n').length;
    else out[k] = v;
  }
  return out;
}

function resultText(content: unknown): string {
  const raw = Array.isArray(content)
    ? content.map((c: any) => (c.type === 'text' ? c.text : `[${c.type}]`)).join('\n')
    : String(content ?? '');
  return raw.length > 4000 ? raw.slice(0, 4000) + '…' : raw;
}

log(`[engine] ready (pid ${process.pid})`);
