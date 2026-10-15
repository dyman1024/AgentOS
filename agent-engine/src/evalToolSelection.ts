/** S3 synthetic discovery benchmark. No provider request is made without --run and an explicit budget. */
import { createSdkMcpServer, query, tool } from '@anthropic-ai/claude-agent-sdk';
import { z } from 'zod';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, resolve } from 'node:path';

const flags = process.argv.slice(2);
const option = (key: string, fallback: string) => {
  const at = flags.indexOf(key); return at < 0 ? fallback : flags[at + 1] ?? fallback;
};
const repetitions = Number(option('--repetitions', '10'));
const budget = Number(option('--budget-usd', '0'));
const caseBudget = Number(option('--case-budget-usd', '0.5'));
const model = option('--model', 'claude-opus-5-5');
const output = resolve(option('--output', '../evals/results/tool-selection.json'));
if (!flags.includes('--run')) {
  console.log(JSON.stringify({ status: 'not_run', counts: [50, 100, 200], strategies: ['meta', 'sdk-search'], cases: 6 * repetitions, requires: 'ANTHROPIC_API_KEY, --run and --budget-usd' }, null, 2));
  process.exit(0);
}
if (!process.env.ANTHROPIC_API_KEY || !Number.isFinite(budget) || budget <= 0 ||
  !Number.isFinite(caseBudget) || caseBudget < 0.01 || caseBudget > 50 || !Number.isInteger(repetitions) || repetitions < 1 || repetitions > 100) {
  throw new Error('A provider API key, positive total budget, case budget $0.01–50 and 1–100 repetitions are required');
}
const records: Record<string, unknown>[] = [];
let spent = 0;
async function save() {
  await mkdir(dirname(output), { recursive: true });
  await writeFile(output, JSON.stringify({ status: records.length === 6 * repetitions ? 'complete' : 'incomplete', model, costUsd: spent,
    synthetic: true, cases: records }, null, 2) + '\n');
}
const topics = ['笔记', '待办', '书签', '账单', '文档', '联系人', '日程', '库存', '日志', '媒体'];
const text = (value: unknown) => ({ content: [{ type: 'text' as const, text: JSON.stringify(value) }] });
for (const count of [50, 100, 200]) for (const strategy of ['meta', 'sdk-search']) {
  for (let repeat = 0; repeat < repetitions; repeat++) {
    if (spent + caseBudget > budget + 1e-9) { await save(); throw new Error('Stopped before exceeding the reserved total budget'); }
    const catalog = Array.from({ length: count }, (_, index) => ({
      name: 'lookup_' + String(index).padStart(3, '0'),
      description: `查询项目${String(Math.floor(index / 10)).padStart(3, '0')}的${topics[index % 10]}，按关键词筛选并返回记录。`,
    }));
    const target = (repeat * 37 + 11) % count;
    const selected: string[] = [];
    let searched = false;
    let result: any;
    const call = (name: string) => { if (!catalog.some(item => item.name === name)) throw new Error('Unknown fixture tool'); selected.push(name); return text({ records: [{ title: 'fixture', id: name }] }); };
    const definitions = strategy === 'meta' ? [
      tool('apps_search', 'Search available tools by project identifier or topic.', { query: z.string() }, async ({ query: q }) => text(catalog.filter(item => (item.name + item.description).includes(q)).slice(0, 20))),
      tool('apps_describe', 'Read the input and output contract for a tool.', { name: z.string() }, async ({ name }) => text({ tool: catalog.find(item => item.name === name), input: { query: 'string' }, output: { records: 'array' } })),
      tool('apps_call', 'Call one application tool after reading its contract.', { name: z.string(), args: z.object({ query: z.string() }) }, async ({ name }) => call(name)),
    ] : catalog.map(item => tool(item.name, item.description, { query: z.string() }, async () => call(item.name)));
    const server = createSdkMcpServer({ name: 'fixtures', tools: definitions, alwaysLoad: strategy === 'meta' });
    const directory = await mkdtemp(tmpdir() + '/agentos-selection-');
    const abort = new AbortController();
    const timer = setTimeout(() => abort.abort(), 180_000);
    const started = Date.now();
    try {
      for await (const event of query({
        prompt: `请查询项目${String(Math.floor(target / 10)).padStart(3, '0')}的${topics[target % 10]}，关键词为季度复盘。只调用一个最终业务工具。`,
        options: { cwd: directory, model, systemPrompt: '通过提供的工具完成查询。先查找并阅读合适的工具契约，再调用它。不修改文件，不使用外部工具。',
          settingSources: [], tools: strategy === 'sdk-search' ? ['ToolSearch'] : [],
          allowedTools: ['mcp__fixtures__*', ...(strategy === 'sdk-search' ? ['ToolSearch'] : [])], permissionMode: 'dontAsk',
          mcpServers: { fixtures: server }, maxTurns: 12, maxBudgetUsd: caseBudget, abortController: abort,
          env: { ...process.env, CLAUDE_CONFIG_DIR: directory + '/config', ENABLE_TOOL_SEARCH: strategy === 'sdk-search' ? 'true' : 'false' },
          canUseTool: async (name, input) => name.startsWith('mcp__fixtures__') || name === 'ToolSearch'
            ? { behavior: 'allow', updatedInput: input } : { behavior: 'deny', message: 'Fixture tools only' },
        },
      })) {
        if (event.type === 'result') result = event;
        if (event.type === 'assistant') searched ||= event.message.content.some(block => block.type === 'tool_use' && block.name === 'ToolSearch');
      }
      const cost = typeof result?.total_cost_usd === 'number' ? result.total_cost_usd : caseBudget;
      spent += cost;
      records.push({ count, strategy, repeat, passed: selected.length === 1 && selected[0] === catalog[target]!.name && result?.subtype === 'success',
        target: catalog[target]!.name, selected, costUsd: cost, costUnknown: typeof result?.total_cost_usd !== 'number',
        durationMs: Date.now() - started, toolSearchUsed: searched, comparable: strategy === 'meta' || searched });
    } catch (error) {
      spent += typeof result?.total_cost_usd === 'number' ? result.total_cost_usd : caseBudget;
      records.push({ count, strategy, repeat, passed: false, error: String(error), costUnknown: !result });
      await save(); throw error;
    } finally { clearTimeout(timer); await rm(directory, { recursive: true, force: true }); }
    await save();
  }
}
