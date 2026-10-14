// Injected at document start into every generated app (main frame, page world).
// Provides window.agentos for app code and window.__agentos hooks the host uses for testing.
(() => {
  if (window.__agentos) return;

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

  // ---- synthetic input used by the agent's test tools
  const KEYS = {
    ArrowUp: ['ArrowUp', 38], ArrowDown: ['ArrowDown', 40], ArrowLeft: ['ArrowLeft', 37], ArrowRight: ['ArrowRight', 39],
    ' ': ['Space', 32], Enter: ['Enter', 13], Escape: ['Escape', 27], Tab: ['Tab', 9], Backspace: ['Backspace', 8],
    Shift: ['ShiftLeft', 16], Control: ['ControlLeft', 17], Alt: ['AltLeft', 18],
  };
  const keyInfo = (key) => {
    if (key === 'Space' || key === 'Spacebar') key = ' ';
    if (key === 'Esc') key = 'Escape';
    if (KEYS[key]) return { key, code: KEYS[key][0], keyCode: KEYS[key][1] };
    if (key.length === 1) {
      const upper = key.toUpperCase();
      if (upper >= 'A' && upper <= 'Z') return { key, code: 'Key' + upper, keyCode: upper.charCodeAt(0) };
      if (key >= '0' && key <= '9') return { key, code: 'Digit' + key, keyCode: key.charCodeAt(0) };
    }
    return { key, code: key, keyCode: 0 };
  };
  const dispatchKey = (type, key) => {
    const info = keyInfo(key);
    const ev = new KeyboardEvent(type, { key: info.key, code: info.code, bubbles: true, cancelable: true });
    Object.defineProperty(ev, 'keyCode', { get: () => info.keyCode });
    Object.defineProperty(ev, 'which', { get: () => info.keyCode });
    (document.activeElement || document.body || document).dispatchEvent(ev);
  };
  const dispatchClick = (x, y) => {
    const target = document.elementFromPoint(x, y) || document.body;
    const init = { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0, pointerId: 1, isPrimary: true };
    target.dispatchEvent(new PointerEvent('pointerdown', init));
    target.dispatchEvent(new MouseEvent('mousedown', init));
    target.dispatchEvent(new PointerEvent('pointerup', init));
    target.dispatchEvent(new MouseEvent('mouseup', init));
    target.dispatchEvent(new MouseEvent('click', init));
  };

  // ---- public API for app code
  let exposed;
  window.agentos = Object.freeze({
    expose(stateOrFn) { exposed = stateOrFn; },
  });

  // ---- host hooks
  window.__agentos = Object.freeze({
    frames: () => frames,
    hasExposed: () => exposed !== undefined,
    state() {
      if (exposed === undefined) return null;
      try {
        const v = typeof exposed === 'function' ? exposed() : exposed;
        return v === undefined ? null : JSON.parse(JSON.stringify(v));
      } catch (e) {
        return { __error: String(e) };
      }
    },
    key: dispatchKey,
    click: dispatchClick,
    viewport: () => ({ width: innerWidth, height: innerHeight, dpr: devicePixelRatio }),
  });
})();
