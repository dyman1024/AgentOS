// Injected at document start into every generated app (main frame, page world).
// Captures console output and errors, counts animation frames and provides window.agentos for app code.
// The hooks the host uses for testing live in agentos-host.js, in a content world the app cannot reach.
(() => {
  if (window.agentos) return;

  const post = (m) => {
    try { window.webkit.messageHandlers.agentosLog.postMessage(m); } catch {}
  };

  // ---- console + error capture (rate limited so per-frame logging can't flood the host)
  const format = (a) => {
    if (a instanceof Error) return a.stack ? `${a.name}: ${a.message}\n${a.stack}` : String(a);
    if (typeof a === 'string') return a;
    try { return JSON.stringify(a); } catch { return String(a); }
  };
  let budget = 100, windowStart = Date.now(), dropped = 0;
  const send = (level, args, extra) => {
    const now = Date.now();
    if (now - windowStart > 1000) {
      if (dropped) post({ level: 'warn', msg: `[agentos] dropped ${dropped} console messages (rate limit)` });
      windowStart = now; budget = 100; dropped = 0;
    }
    if (level !== 'error' && budget-- <= 0) { dropped++; return; }
    let msg = args.map(format).join(' ');
    if (msg.length > 2000) msg = msg.slice(0, 2000) + '…';
    post(Object.assign({ level, msg }, extra || {}));
  };
  for (const name of ['log', 'info', 'debug', 'warn', 'error']) {
    const original = console[name].bind(console);
    const level = name === 'warn' || name === 'error' ? name : 'log';
    console[name] = (...args) => { send(level, args); original(...args); };
  }
  addEventListener('error', (e) => {
    const t = e.target;
    if (t && t !== window && (t.src || t.href)) {
      send('error', [`Failed to load resource: ${t.src || t.href}`]);
      return;
    }
    send('error', [e.message || 'Script error'], {
      file: e.filename, line: e.lineno, col: e.colno, stack: e.error && e.error.stack,
    });
  }, true);
  addEventListener('unhandledrejection', (e) => {
    send('error', ['Unhandled promise rejection: ' + format(e.reason)], { stack: e.reason && e.reason.stack });
  });
  document.addEventListener('securitypolicyviolation', (e) => {
    send('error', [`Blocked by the AgentOS sandbox (network and external resources are not allowed): ${e.blockedURI || 'inline'} [${e.effectiveDirective}]`]);
  });

  // ---- frame counter: lets the host check that the render loop is alive
  let frames = 0;
  const raf = window.requestAnimationFrame.bind(window);
  window.requestAnimationFrame = (cb) => raf((t) => { frames++; cb(t); });

  // ---- keep game keys from scrolling the page or making AppKit beep, except while typing in a field
  addEventListener('keydown', (e) => {
    if (e.metaKey || e.ctrlKey || e.altKey || e.defaultPrevented) return;
    const t = e.target;
    const editable = t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName));
    const activatable = t && /^(BUTTON|A)$/.test(t.tagName) && (e.key === 'Enter' || e.key === ' ');
    if (!editable && !activatable) e.preventDefault();
  });

  // ---- public API for app code
  let exposed;
  window.agentos = Object.freeze({
    expose(stateOrFn) { exposed = stateOrFn; },
  });

  // ---- answers the host hooks in agentos-host.js. The two worlds share the DOM but no JS objects, so the
  // host asks with an event and gets a JSON string back. Registered before any app code runs, and stopped
  // here so app listeners never see the request. Frame counts and exposed state are reported by the page
  // either way; what the host world protects is the hooks themselves and everything the host evaluates.
  const stringify = JSON.stringify;
  const reply = (detail) => dispatchEvent(new CustomEvent('agentos-host-reply', { detail }));
  const stateJSON = () => {
    if (exposed === undefined) return 'null';
    try {
      const v = typeof exposed === 'function' ? exposed() : exposed;
      return (v === undefined ? null : stringify(v)) ?? 'null';
    } catch (e) {
      return stringify({ __error: String(e) });
    }
  };
  addEventListener('agentos-host-request', (e) => {
    e.stopImmediatePropagation();
    const r = { frames, hasExposed: exposed !== undefined };
    if (e.detail === 'state') r.state = stateJSON();
    reply(stringify(r));
  }, true);
})();
