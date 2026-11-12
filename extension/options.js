const $ = (id) => document.getElementById(id);

function show(s) {
  if (!s) { $("status").textContent = "Nothing sent yet: open a Meet call with captions on."; return; }
  const ago = Math.round((Date.now() - s.at) / 1000);
  $("status").textContent = s.ok
    ? `${s.recording ? (s.accepted ? "Sending captions to Earshot" : "Earshot is recording another call") : "Connected; Earshot isn't recording a Meet call"} (${ago}s ago)`
    : `Error: ${s.error} (${ago}s ago)`;
}

chrome.storage.local.get(["port", "token", "status"]).then(({ port, token, status }) => {
  $("port").value = port || "";
  $("token").value = token || "";
  show(status);
});
chrome.storage.onChanged.addListener((c) => { if (c.status) show(c.status.newValue); });

$("save").addEventListener("click", async () => {
  const port = parseInt($("port").value, 10);
  await chrome.storage.local.set({ token: $("token").value.trim(), port: port > 0 && port < 65536 ? port : 7788 });
  $("status").textContent = "Saved.";
});
