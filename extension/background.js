// Posts caption blocks from the Meet tab to Earshot's local API. Earshot rejects any origin but an extension's on
// this route, and only with the extension token from Earshot → Settings → Integrations.
const DEFAULT_PORT = 7788;

async function post(body) {
  const { port = DEFAULT_PORT, token = "" } = await chrome.storage.local.get(["port", "token"]);
  let status;
  if (!token) {
    status = { ok: false, error: "No token: paste it in the extension's options." };
  } else {
    try {
      const r = await fetch(`http://127.0.0.1:${port}/v1/meet/captions`, {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const j = await r.json().catch(() => ({}));
      status = r.ok ? { ok: true, recording: !!j.recording, accepted: !!j.accepted }
                    : { ok: false, error: (j.error && (j.error.message || j.error)) || `HTTP ${r.status}` };
    } catch (e) {
      status = { ok: false, error: "Earshot isn't running (or uses another port)." };
    }
  }
  status.at = Date.now();
  await chrome.storage.local.set({ status });
  return status;
}

chrome.runtime.onMessage.addListener((msg, _sender, reply) => {
  if (msg?.type !== "captions") return;
  post(msg.body).then(reply);
  return true;
});
