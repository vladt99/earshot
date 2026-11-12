// Reads Google Meet's captions the way Earshot does through Accessibility, but from inside the page, so it keeps
// working while the tab is in the background. Sends the newest caption blocks to Earshot (via background.js).
(() => {
  // aria-label of the captions region, as in MeetStrings.captionRegions (Earshot).
  const REGION_LABELS = new Set(["captions", "subtitrări", "subtitrari", "untertitel", "sous-titres", "subtítulos",
    "sottotitoli", "legendas", "ondertiteling", "napisy"]);
  const TAIL = 4;
  const page = crypto.randomUUID();
  const ids = new WeakMap();
  let nextId = 1;
  let region = null;
  let observer = null;
  let recording = false;
  let lastSent = "";
  let lastSentAt = 0;
  let pending = null;

  const idOf = (el) => { if (!ids.has(el)) ids.set(el, nextId++); return ids.get(el); };
  const code = () => (location.pathname.match(/[a-z]{3,4}-[a-z]{4}-[a-z]{3,4}/) || [null])[0];

  function findRegion() {
    for (const el of document.querySelectorAll("[aria-label]")) {
      if (REGION_LABELS.has(el.getAttribute("aria-label").trim().toLowerCase())) return el;
    }
    return null;
  }

  // Visible text pieces in document order, like the accessibility tree's static texts.
  function texts(el) {
    const out = [];
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, {
      acceptNode(n) {
        const p = n.parentElement;
        if (!p || !n.nodeValue.trim()) return NodeFilter.FILTER_REJECT;
        if (p.closest('[aria-hidden="true"], button, [role="button"], style, script')) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      },
    });
    for (let n = walker.nextNode(); n; n = walker.nextNode()) out.push(n.nodeValue.replace(/\s+/g, " ").trim());
    return out;
  }

  // Same rule as MeetParse.captionBlocks: skip single-child wrappers while their children are blocks
  // (a name and some text each); each block's first text is the speaker, the rest the caption.
  function blocks(root) {
    const kids = (el) => [...el.children].filter((c) => texts(c).length > 0);
    let el = root;
    for (let depth = 0; depth < 6; depth++) {
      const k = kids(el);
      if (k.length !== 1) break;
      const inner = kids(k[0]);
      if (inner.length === 0 || !inner.every((c) => texts(c).length >= 2)) break;
      el = k[0];
    }
    return kids(el).slice(-TAIL).flatMap((b) => {
      const t = texts(b);
      if (t.length < 2 || t[0].length > 80) return [];
      return [{ id: idOf(b), speaker: t[0], text: t.slice(1).join(" ") }];
    });
  }

  function send(force) {
    pending = null;
    if (!region || !region.isConnected) { attach(); if (!region) return; }
    const list = blocks(region);
    const key = JSON.stringify(list);
    const now = Date.now();
    // Changes go out at once; the same captions again once a second, so Earshot knows the extension is reading.
    if (!force && key === lastSent) return;
    if (key === lastSent && now - lastSentAt < (recording ? 1000 : 5000)) return;
    lastSent = key;
    lastSentAt = now;
    chrome.runtime.sendMessage({ type: "captions", body: { code: code(), page, blocks: list } }, (r) => {
      if (chrome.runtime.lastError) return;
      recording = !!(r && r.recording);
    });
  }

  const schedule = () => { if (!pending) pending = setTimeout(() => send(false), 250); };

  function attach() {
    const r = findRegion();
    if (r === region) return;
    observer?.disconnect();
    region = r;
    lastSent = "";
    if (!r) return;
    observer = new MutationObserver(schedule);
    observer.observe(r, { childList: true, subtree: true, characterData: true });
    schedule();
  }

  setInterval(() => { if (!region || !region.isConnected) attach(); send(true); }, 1000);
  attach();
})();
