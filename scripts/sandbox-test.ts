// Sandbox regression suite behind `make sandbox-test`. Loads each tests/fixtures/sandbox-*.html into the runtime
// with `AgentOS --selftest-runtime <fixture> --selftest-neighbor`, reads logs/selftest-result.json and checks the
// state the fixture exposed. Exits non-zero if any escape attempt got through or a probe did not finish.
//
// Usage: bun scripts/sandbox-test.ts <path/to/AgentOS.app>
import { spawnSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';

type State = Record<string, any>;
type Check = { name: string; ok: (s: State) => boolean };

const blocked = (v: unknown) => typeof v === 'string' && v.startsWith('blocked');
// A fetch result from the probes: { ok, status, len } when a response came back, { error } when it threw.
const notRead = (v: any) => !!v && v.ok !== true;

const SUITE: Record<string, Check[]> = {
  'sandbox-escape.html': [
    { name: 'fetch to the internet is blocked', ok: (s) => blocked(s.fetch) },
    { name: 'import from a CDN is blocked', ok: (s) => blocked(s.cdnImport) },
    { name: 'WebSocket to the internet is blocked', ok: (s) => blocked(s.ws) },
  ],
  'sandbox-probe1-egress-and-isolation.html': [
    { name: 'probe finished and found the neighbor app', ok: (s) => s.done === true && s.hasNeighbor === true },
    { name: 'control: the app can still load its own files', ok: (s) => s.ownScript === 'load' },
    { name: 'cross-app: fetching a file of another app fails', ok: (s) => notRead(s.neighborFetch) },
    { name: 'cross-app: loading a script of another app is refused', ok: (s) => s.neighborScript === 'error' && s.neighborSecretLeaked === false },
    { name: 'cross-app: an unregistered app ID is refused', ok: (s) => s.unregisteredScript === 'error' },
    { name: 'traversal: fetching agentos://.. fails', ok: (s) => notRead(s.traversalFetch) },
    { name: 'traversal: loading a script from agentos://.. is refused', ok: (s) => s.traversalScriptExisting === 'error' },
    { name: 'WebRTC: unavailable in the main frame', ok: (s) => s.rtcAvailable === false },
    { name: 'WebRTC: unavailable in a same-origin iframe', ok: (s) => s.iframeSameOrigin === true && s.iframeRtcAvailable === false },
    { name: "WebRTC: unavailable in a fresh iframe's initial document", ok: (s) => s.blankIframeRtcAvailable === false },
    { name: 'test hooks: not reachable from the page world', ok: (s) => s.hooksVisible === false && s.hooksWritable === false },
  ],
  'sandbox-probe2-iframe-traversal.html': [
    { name: 'probe finished', ok: (s) => s.done === true },
    { name: 'traversal: an iframe at agentos://.. read nothing', ok: (s) => s.reader === undefined },
    { name: 'WebRTC: no ICE candidates gathered', ok: (s) => s.rtcAvailable === false && !s.rtc?.types?.length },
  ],
  'sandbox-probe3-toplevel-traversal.html': [
    { name: 'probe finished and found the neighbor app', ok: (s) => s.done === true && s.hasNeighbor === true },
    { name: 'traversal: nothing brought back from agentos://..', ok: (s) => s.broughtBack === undefined },
    { name: 'navigation: main frame cannot go to agentos://..', ok: (s) => s.attempts?.traversal === 'blocked' },
    { name: 'navigation: main frame cannot go to another app', ok: (s) => s.attempts?.neighbor === 'blocked' },
    { name: 'navigation: main frame cannot go to a data: URL', ok: (s) => s.attempts?.dataUrl === 'blocked' },
  ],
};

const root = resolve(import.meta.dir, '..');
const fixtures = join(root, 'tests/fixtures');
const app = resolve(process.argv[2] ?? join(root, 'build/Build/Products/Debug/AgentOS.app'));
const exe = join(app, 'Contents/MacOS/AgentOS');
const resultFile = join(homedir(), 'Library/Application Support/AgentOS/logs/selftest-result.json');

if (!existsSync(exe)) {
  console.error(`AgentOS not found at ${app}; run make build first`);
  process.exit(2);
}
// A fixture without expectations would silently test nothing.
const unlisted = readdirSync(fixtures).filter((f) => f.startsWith('sandbox-') && f.endsWith('.html') && !(f in SUITE));
if (unlisted.length) {
  console.error(`No expectations in scripts/sandbox-test.ts for: ${unlisted.join(', ')}`);
  process.exit(2);
}

let failures = 0;
for (const [fixture, checks] of Object.entries(SUITE)) {
  console.log(fixture);
  rmSync(resultFile, { force: true });
  const run = spawnSync(exe, ['--selftest-runtime', join(fixtures, fixture), '--selftest-neighbor'], {
    encoding: 'utf8', timeout: 90_000,
  });
  let report: State | undefined;
  try { report = JSON.parse(readFileSync(resultFile, 'utf8')); } catch {}
  if (!report || report.run_app?.loaded !== true) {
    failures++;
    console.log(`  ✗ the runtime did not load the fixture (exit ${run.status ?? run.signal})`);
    if (report) console.log(`    run_app: ${JSON.stringify(report.run_app)}`);
    continue;
  }
  const state: State = report.smoke_test?.state_after ?? {};
  let fixtureFailed = false;
  for (const check of checks) {
    let ok = false;
    try { ok = check.ok(state); } catch {}
    console.log(`  ${ok ? '✓' : '✗'} ${check.name}`);
    if (!ok) { failures++; fixtureFailed = true; }
  }
  if (fixtureFailed) {
    console.log(`    state: ${JSON.stringify(state)}`);
    const blockedLog = (report.console ?? []).filter((e: State) => /AgentOS sandbox/.test(e.msg ?? ''));
    for (const e of blockedLog.slice(0, 5)) console.log(`    console: ${e.msg}`);
  }
}

console.log(failures ? `\n${failures} sandbox check(s) failed` : '\nAll sandbox checks passed');
process.exit(failures ? 1 : 0);
