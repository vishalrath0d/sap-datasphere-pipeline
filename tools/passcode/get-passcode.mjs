#!/usr/bin/env node
// Prints a fresh one-time Datasphere passcode on stdout - without opening tabs or windows.
//
//   node tools/passcode/get-passcode.mjs https://<tenant>.authentication.<region>.hana.ondemand.com/passcode
//
// How: the Chrome started by chrome-session.sh holds your signed-in session. Over its DevTools
// port (127.0.0.1 only) we read the session cookies for the passcode host, then fetch the
// passcode page ourselves with those cookies and read the code from the HTML. Every load of the
// page issues a new code (SAP CLI README: "retrieve more passcodes by refreshing the page").
// Nothing happens on screen; the Chrome window can stay minimised.
//
// If the session has expired and DS_AUTO_LOGIN=1, it signs in again in a BACKGROUND tab
// (no focus change) with DS_USER / DS_PASSWORD from .env (POC convenience - .env is git-ignored;
// in production there is no password at all: an OAuth technical user replaces all of this).
//
//   node tools/passcode/get-passcode.mjs --close      close the passcode Chrome (any OS)
//
// No npm dependencies: Node's built-in fetch and WebSocket (Node 22+). macOS, Linux, Windows.
// Exit codes: 2 = no Chrome session, 3 = not signed in / no code found.

const port = process.env.DS_PASSCODE_CDP_PORT || "9333";
const base = `http://127.0.0.1:${port}`;
const url = process.argv[2];
const debug = process.env.DS_PASSCODE_DEBUG === "1";

function fail(code, msg) { process.stderr.write(`get-passcode: ${msg}\n`); process.exit(code); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const dbg = (m) => { if (debug) process.stderr.write(`get-passcode[debug]: ${m}\n`); };

// Page text: "Temporary Authentication Code" then the code (seen on the trial tenant 2026-10-19,
// e.g. "fEfp_5lLXlFRMKpP2IlWC9S1XnyGme2i").
function extractPasscode(text) {
  const m = /Temporary Authentication Code\s+([A-Za-z0-9_-]{6,64})\b/i.exec(text || "");
  return m ? m[1] : null;
}
function htmlToText(html) {
  return html.replace(/<script[\s\S]*?<\/script>/gi, " ").replace(/<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<[^>]+>/g, " ").replace(/&nbsp;/g, " ").replace(/\s+/g, " ");
}

// ---- minimal CDP client ------------------------------------------------------------------------
async function cdp(wsUrl) {
  const ws = new WebSocket(wsUrl);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
  let seq = 0; const pending = new Map();
  ws.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
  };
  const send = (method, params = {}, sessionId) => new Promise((res) => {
    const id = ++seq; pending.set(id, res);
    ws.send(JSON.stringify(sessionId ? { id, method, params, sessionId } : { id, method, params }));
  });
  return { send, close: () => ws.close() };
}

async function browser() {
  let info;
  try { info = await (await fetch(`${base}/json/version`)).json(); }
  catch { fail(2, `no Chrome session on ${base} - run: make passcode-start`); }
  return cdp(info.webSocketDebuggerUrl);
}

// ---- 1. fetch the page with the browser's cookies (no tab, no window) ---------------------------
async function viaCookies(b) {
  const host = new URL(url).hostname;
  const r = await b.send("Storage.getCookies");
  const cookies = (r.result?.cookies || []).filter((c) => {
    const d = c.domain.replace(/^\./, "");
    return host === d || host.endsWith("." + d);
  });
  dbg(`${cookies.length} cookie(s) for ${host}`);
  if (!cookies.length) return null;
  const res = await fetch(url, {
    redirect: "manual",
    headers: { Cookie: cookies.map((c) => `${c.name}=${c.value}`).join("; "), Accept: "text/html" },
  });
  dbg(`GET ${url} -> ${res.status}`);
  if (res.status !== 200) return null;            // 302 to the login page = session expired
  return extractPasscode(htmlToText(await res.text()));
}

// ---- 2. sign in again in a background tab (only with DS_AUTO_LOGIN=1) ----------------------------
// Fills whatever step of the login form is visible (username, password, or both), submits,
// repeats until the passcode page shows. Works for one- and two-step SAP IdP forms.
// Clicking may do nothing (e.g. browser validation of a type=email field); then submit natively.
const FORCE_SUBMIT = `(() => {
  const f = [...document.querySelectorAll('input[type=password], input[type=email], input[type=text]')]
    .map((e) => e.form).find(Boolean);
  if (!f) return 'no form';
  HTMLFormElement.prototype.submit.call(f);
  return 'forced';
})()`;
const FILL_STEP = (user, pass) => `(() => {
  const vis = (e) => e && e.offsetParent !== null && !e.disabled;
  const set = (e, v) => { e.focus(); e.value = v; e.dispatchEvent(new Event('input', {bubbles: true}));
                          e.dispatchEvent(new Event('change', {bubbles: true})); };
  const body = document.body ? document.body.innerText : '';
  if (/Temporary Authentication Code/i.test(body)) return 'done';
  const pw = [...document.querySelectorAll('input[type=password]')].find(vis);
  const us = [...document.querySelectorAll('input[type=email], input[name=j_username], input[name=username], input[name=email], input[id*=user i], input[type=text]')].find(vis);
  let acted = '';
  if (us && !us.value) { set(us, ${JSON.stringify(user)}); acted += 'user '; }
  if (pw && !pw.value) { set(pw, ${JSON.stringify(pass)}); acted += 'password '; }
  if (!acted) return (us && us.value) || (pw && pw.value) ? 'filled' : 'waiting';
  const btn = [...document.querySelectorAll('button[type=submit], input[type=submit], #logOnFormSubmit, button')].find(vis);
  if (btn) btn.click(); else (pw || us).form && (pw || us).form.submit();
  return 'submitted ' + acted;
})()`;

async function autoLogin(b) {
  const user = process.env.DS_USER, pass = process.env.DS_PASSWORD;
  if (process.env.DS_AUTO_LOGIN !== "1") return false;
  if (!user || !pass) { process.stderr.write("get-passcode: DS_AUTO_LOGIN=1 needs DS_USER and DS_PASSWORD in .env\n"); return false; }
  const t = await b.send("Target.createTarget", { url, background: true });   // background: no focus change
  const targetId = t.result.targetId;
  const att = await b.send("Target.attachToTarget", { targetId, flatten: true });
  const sid = att.result.sessionId;
  let ok = false, stuck = 0;
  for (let i = 0; i < 40 && !ok; i++) {             // ~20 s
    await sleep(500);
    const r = await b.send("Runtime.evaluate", { expression: FILL_STEP(user, pass), returnByValue: true }, sid);
    const v = r.result?.result?.value; dbg(`login step: ${v}`);
    if (v === "done") ok = true;
    else if (typeof v === "string" && v.startsWith("submitted")) { stuck = 0; await sleep(1500); }
    else if (v === "filled" && ++stuck >= 3) {
      const f = await b.send("Runtime.evaluate", { expression: FORCE_SUBMIT, returnByValue: true }, sid);
      dbg(`login step: ${f.result?.result?.value}`); stuck = 0; await sleep(1500);
    }
  }
  await b.send("Target.closeTarget", { targetId });
  return ok;
}

// ---- fallback: read the page in a background tab (if the code is rendered by JavaScript) ---------
async function viaBackgroundTab(b) {
  const t = await b.send("Target.createTarget", { url, background: true });
  const targetId = t.result.targetId;
  const sid = (await b.send("Target.attachToTarget", { targetId, flatten: true })).result.sessionId;
  let code = null;
  for (let i = 0; i < 30 && !code; i++) {
    await sleep(500);
    const r = await b.send("Runtime.evaluate", { expression: "document.body ? document.body.innerText : ''", returnByValue: true }, sid);
    code = extractPasscode(r.result?.result?.value);
  }
  await b.send("Target.closeTarget", { targetId });
  return code;
}

async function main() {
  if (url === "--close") {                                    // `make passcode-stop`, any OS
    let info;
    try { info = await (await fetch(`${base}/json/version`)).json(); } catch { console.log("not running"); return; }
    const b = await cdp(info.webSocketDebuggerUrl);
    b.send("Browser.close"); await sleep(500); console.log("stopped"); process.exit(0);
  }
  if (!url) fail(1, "usage: get-passcode.mjs <passcode-url> | --close");
  if (typeof WebSocket === "undefined") fail(1, `Node ${process.version} has no built-in WebSocket - use Node 22+`);
  const b = await browser();
  let code = await viaCookies(b);                       // normal case: nothing on screen
  if (!code && await autoLogin(b)) code = await viaCookies(b);
  if (!code) code = await viaBackgroundTab(b);          // last resort, still no focus change
  b.close();
  if (!code) fail(3, "not signed in (session expired?) - sign in again in the Chrome window from `make passcode-start`"
    + (process.env.DS_AUTO_LOGIN === "1" ? "" : ", or enable DS_AUTO_LOGIN=1 (docs/00-RUNBOOK.md)"));
  process.stdout.write(code + "\n");
}

main();
