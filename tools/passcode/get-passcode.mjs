#!/usr/bin/env node
// Prints a fresh one-time Datasphere passcode on stdout.
//
//   node tools/passcode/get-passcode.mjs https://<tenant>.authentication.<region>.hana.ondemand.com/passcode
//
// Opens the passcode page in a new tab of the Chrome started by chrome-session.sh (Chrome DevTools
// Protocol on 127.0.0.1), reads the "Temporary Authentication Code", closes the tab. Each page load
// issues a new code - SAP's CLI README describes exactly this ("retrieve more passcodes by
// refreshing the page", and programmatic retrieval with a headless browser).
// No npm dependencies: uses Node's built-in fetch and WebSocket (Node 22+).
//
// Exit codes: 2 = no Chrome session, 3 = not signed in / no code found.

const port = process.env.DS_PASSCODE_CDP_PORT || "9333";
const base = `http://127.0.0.1:${port}`;
const url = process.argv[2];
const timeoutMs = Number(process.env.DS_PASSCODE_TIMEOUT_MS || 20000);

function fail(code, msg) {
  process.stderr.write(`get-passcode: ${msg}\n`);
  process.exit(code);
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// The page shows a heading followed by the code, e.g. "Temporary Authentication Code\nAbC123xYz9".
function extractPasscode(text) {
  const m = /Temporary Authentication Code\s+([A-Za-z0-9_-]{6,64})\b/i.exec(text || "");
  return m ? m[1] : null;
}

async function main() {
  if (!url) fail(1, "usage: get-passcode.mjs <passcode-url>");
  if (typeof WebSocket === "undefined") fail(1, `Node ${process.version} has no built-in WebSocket - use Node 22+`);

  let target;
  try {
    const r = await fetch(`${base}/json/new?${encodeURIComponent(url)}`, { method: "PUT" });
    target = await r.json();
  } catch {
    fail(2, `no Chrome session on ${base} - run: bash tools/passcode/chrome-session.sh`);
  }

  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
  let seq = 0;
  const pending = new Map();
  ws.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
  };
  const send = (method, params = {}) => new Promise((resolve) => {
    const id = ++seq;
    pending.set(id, resolve);
    ws.send(JSON.stringify({ id, method, params }));
  });

  let code = null, text = "", href = "";
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const r = await send("Runtime.evaluate", {
      expression: 'JSON.stringify({href: location.href, text: document.body ? document.body.innerText : ""})',
      returnByValue: true,
    });
    try { ({ href, text } = JSON.parse(r.result?.result?.value || "{}")); } catch { /* page still loading */ }
    code = extractPasscode(text);
    if (code) break;
    await sleep(500);
  }

  ws.close();
  await fetch(`${base}/json/close/${target.id}`).catch(() => {});

  if (!code) {
    if (process.env.DS_PASSCODE_DEBUG === "1") process.stderr.write(`--- page ${href}\n${(text || "").slice(0, 800)}\n`);
    fail(3, /\/passcode/.test(href || "")
      ? "passcode page loaded but no code found (set DS_PASSCODE_DEBUG=1 to see the page text)"
      : `not signed in (tab ended on ${href || "?"}) - sign in in the Chrome window from chrome-session.sh`);
  }
  process.stdout.write(code + "\n");
}

main();
