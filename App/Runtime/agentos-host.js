// Injected at document start into every generated app (main frame), in the host's own content world
// ("agentos-host"). Provides window.__agentos, the hooks the runtime tools call through evaluate.
// The app's code runs in the page world: it shares the DOM with this script but can neither see nor
// replace anything defined here.
(() => {
  if (window.__agentos) return;

  // Frame count and exposed state live in the page world (agentos-shim.js). Event dispatch is synchronous,
  // so the shim's reply has arrived by the time dispatchEvent returns; it comes back as a JSON string.
  const ask = (what) => {
    let reply = null;
    const onReply = (e) => { if (reply === null && typeof e.detail === 'string') reply = e.detail; };
    addEventListener('agentos-host-reply', onReply, true);
    try {
      dispatchEvent(new CustomEvent('agentos-host-request', { detail: what }));
    } finally {
      removeEventListener('agentos-host-reply', onReply, true);
    }
    try { return reply === null ? null : JSON.parse(reply); } catch { return null; }
  };

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
    // keyCode and which go into the init dictionary (WebKit still accepts these legacy members): a property
    // defined on this world's event wrapper would be invisible to the page's listeners.
    const ev = new KeyboardEvent(type, {
      key: info.key, code: info.code, keyCode: info.keyCode, which: info.keyCode, bubbles: true, cancelable: true,
    });
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

  window.__agentos = Object.freeze({
    frames: () => ask('frames')?.frames ?? -1,
    hasExposed: () => ask('frames')?.hasExposed === true,
    state() {
      const r = ask('state');
      if (!r || typeof r.state !== 'string') return null;
      try { return JSON.parse(r.state); } catch { return null; }
    },
    key: dispatchKey,
    click: dispatchClick,
    viewport: () => ({ width: innerWidth, height: innerHeight, dpr: devicePixelRatio }),
  });
})();
