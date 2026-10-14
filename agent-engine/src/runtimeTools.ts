// MCP tools the agent uses to drive the live runtime. Each handler forwards to the Swift host,
// which owns the WKWebView, and returns the host's answer to the model.
import { createSdkMcpServer, tool } from '@anthropic-ai/claude-agent-sdk';
import { z } from 'zod';
import type { Peer } from './rpc';

export const RUNTIME_SERVER = 'runtime';
export const RUNTIME_TOOL_NAMES = [
  'run_app',
  'smoke_test',
  'send_input',
  'get_console',
  'screenshot',
  'inspect_state',
  'set_app_info',
] as const;

const InputStep = z.object({
  action: z
    .enum(['press', 'down', 'up', 'wait', 'click'])
    .describe('press = key down then up after ~80 ms; down/up hold or release a key; wait pauses; click clicks at x,y (CSS px)'),
  key: z.string().optional().describe('KeyboardEvent.key value, e.g. "ArrowUp", " ", "Enter", "p"'),
  ms: z.number().optional().describe('Milliseconds for wait, or how long to hold for press'),
  x: z.number().optional(),
  y: z.number().optional(),
});

const CheckName = z.enum(['no_errors', 'nonblank', 'frames_advancing', 'visual_change', 'state_changes']);

const text = (value: unknown) => ({
  content: [{ type: 'text' as const, text: typeof value === 'string' ? value : JSON.stringify(value, null, 2) }],
});

/** Tool names the agent may call; `screenshot` is left out for models without image input. */
export function runtimeToolNames(vision: boolean) {
  return RUNTIME_TOOL_NAMES.filter((n) => vision || n !== 'screenshot');
}

export function makeRuntimeServer(peer: Peer, appId: string, vision: boolean) {
  const call = (method: string, params: Record<string, unknown> = {}) =>
    peer.request<any>(`runtime/${method}`, { appId, ...params });

  const tools = [
    tool(
      'run_app',
      'Reload the app in the live runtime pane. Returns whether index.html loaded, load time, and any errors or warnings logged during the first second.',
      {},
      async () => text(await call('run_app')),
    ),
    tool(
      'smoke_test',
      'Reload the app (unless reload=false), replay the given input steps, then run automated checks. ' +
        'Checks: no_errors (no uncaught errors or console.error), nonblank (screen is not a single flat color), ' +
        'frames_advancing (requestAnimationFrame keeps running), visual_change (the screen changes during the test), ' +
        'state_changes (agentos.expose() state differs before vs after the inputs). Defaults to all checks. ' +
        'Returns pass/fail per check, fps, errors, and the exposed state before and after.',
      {
        inputs: z.array(InputStep).optional().describe('Input steps replayed after the app loads'),
        checks: z.array(CheckName).optional(),
        duration_ms: z.number().optional().describe('Minimum total test duration, default 2500'),
        reload: z.boolean().optional().describe('Reload before testing, default true'),
      },
      async (args) => text(await call('smoke_test', args)),
    ),
    tool(
      'send_input',
      'Send input steps to the running app without reloading it. Returns new console output and the exposed state afterwards.',
      { steps: z.array(InputStep) },
      async (args) => text(await call('send_input', args)),
    ),
    tool(
      'get_console',
      'Read console output captured from the running app.',
      {
        since_seq: z.number().optional().describe('Only entries with seq greater than this'),
        levels: z.array(z.enum(['error', 'warn', 'log'])).optional(),
        limit: z.number().optional().describe('Default 50'),
      },
      async (args) => text(await call('get_console', args)),
    ),
    tool(
      'screenshot',
      'Capture the runtime pane as an image so you can check how the app looks.',
      {},
      async () => {
        const r = await call('screenshot');
        return {
          content: [
            { type: 'image' as const, data: r.pngBase64, mimeType: 'image/png' },
            { type: 'text' as const, text: `Runtime pane: ${r.width}x${r.height} CSS px` },
          ],
        };
      },
    ),
    tool(
      'inspect_state',
      'Return the current state snapshot published by the app through agentos.expose().',
      {},
      async () => text(await call('inspect_state')),
    ),
    tool(
      'set_app_info',
      'Set the app title and icon shown in AgentOS.',
      {
        title: z.string().describe("Short title in the user's language"),
        icon: z.string().describe('A single emoji'),
      },
      async (args) => text(await call('set_app_info', args)),
    ),
  ];

  return createSdkMcpServer({
    name: RUNTIME_SERVER,
    version: '0.1.0',
    tools: vision ? tools : tools.filter((t) => t.name !== 'screenshot'),
  });
}
