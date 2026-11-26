'use strict';
// M4B end-to-end smoke test against the REAL ECS runtime (needs macOS + npm install). No Swift involved.
//   node bridge-smoke.cjs [--fresh] [--login-wait 180] [--watch-playback 15] [--expect-signed-in]
// Flow: A) start, protocol + malformed-input checks, duplicate-instance guard, optional login wait, playback watch
//       B) kill -9 (crash) -> exit observed   C) restart -> ready, auth state persisted, clean shutdown (exit 0)
const { spawn } = require('node:child_process');
const readline = require('node:readline');
const arg = (n, d) => { const i = process.argv.indexOf(n); return i === -1 ? d : (process.argv[i + 1]?.startsWith('--') || i + 1 >= process.argv.length ? true : process.argv[i + 1]); };
const fresh = process.argv.includes('--fresh');
const loginWait = Number(arg('--login-wait', 0)) || 0;
const watchSec = Number(arg('--watch-playback', 0)) || 0;
const expectSignedIn = process.argv.includes('--expect-signed-in');
const results = [];
const check = (name, ok, detail = '') => { results.push({ name, ok }); console.log((ok ? 'PASS ' : 'FAIL ') + name + (detail ? '  ' + detail : '')); };
const sleep = ms => new Promise(r => setTimeout(r, ms));

function launch(extra = []) {
  const electronPath = require('electron'); // path string when required from plain node
  const child = spawn(electronPath, ['.', '--bridge', '--clean-ua', ...(fresh ? ['--fresh-session'] : []), ...extra], { cwd: __dirname, stdio: ['pipe', 'pipe', 'pipe'], env: (({ ELECTRON_RUN_AS_NODE, ...rest }) => rest)(process.env) });
  const rt = { child, events: [], pending: new Map(), nonJson: 0, exit: null, seq: 0 };
  rt.exited = new Promise(r => child.on('exit', (code, sig) => { rt.exit = { code, sig }; for (const p of rt.pending.values()) p.reject(new Error('process exited')); r(rt.exit); }));
  readline.createInterface({ input: child.stdout }).on('line', line => {
    let m; try { m = JSON.parse(line); } catch { rt.nonJson++; return; }
    if (m.id !== undefined && m.id !== null && rt.pending.has(m.id)) { rt.pending.get(m.id).resolve(m); rt.pending.delete(m.id); }
    else if (m.event) rt.events.push(m); else if (m.id === null) rt.unmatched = (rt.unmatched || []).concat(m);
  });
  readline.createInterface({ input: child.stderr }).on('line', () => {}); // diagnostics stay on stderr; drain them
  rt.send = (cmd, args = {}, ms = 10000) => new Promise((resolve, reject) => {
    const id = 'smoke-' + (++rt.seq); const t = setTimeout(() => { rt.pending.delete(id); reject(new Error('timeout ' + cmd)); }, ms);
    rt.pending.set(id, { resolve: m => { clearTimeout(t); resolve(m); }, reject });
    child.stdin.write(JSON.stringify({ v: 1, id, cmd, args }) + '\n');
  });
  rt.waitEvent = async (name, ms) => { const end = Date.now() + ms; while (Date.now() < end) { const e = rt.events.find(x => x.event === name); if (e) return e; if (rt.exit) return null; await sleep(100); } return null; };
  return rt;
}

(async () => {
  console.log('== A: first run ==');
  const a = launch();
  check('runtime.starting event', !!(await a.waitEvent('runtime.starting', 30000)));
  check('runtime.ready event (components + Spotify document loaded)', !!(await a.waitEvent('runtime.ready', 120000)));
  const ping = await a.send('ping');
  check('ping', ping.ok && ping.result.pong === true);
  const st = await a.send('runtime.status');
  check('runtime.status: clean UA mode', st.ok && st.result.uaMode === 'clean-chromium', JSON.stringify(st.result));
  // malformed input must yield errors and leave the runtime responsive
  a.child.stdin.write('this is not json\n'); a.child.stdin.write('{"id":"m1","cmd":"nope"}\n'); a.child.stdin.write('{"cmd":"ping"}\n');
  await sleep(500);
  check('malformed JSON -> invalid_json', (a.unmatched || []).some(m => m.error?.code === 'invalid_json'));
  check('missing id -> invalid_request', (a.unmatched || []).some(m => m.error?.code === 'invalid_request'));
  check('still responsive after malformed input', (await a.send('ping')).ok);
  check('no non-protocol lines on stdout', a.nonJson === 0, 'count=' + a.nonJson);
  // duplicate guard (same profile directory)
  const dup = launch(); const dupErr = await dup.waitEvent('runtime.error', 30000); await dup.exited;
  check('second runtime refused (duplicate_instance, exit 73)', dupErr?.data?.code === 'duplicate_instance' && dup.exit?.code === 73, JSON.stringify(dup.exit));
  check('first runtime unaffected by duplicate attempt', (await a.send('ping')).ok);

  let auth = (await a.send('auth.status')).result;
  console.log('auth.status ->', JSON.stringify(auth));
  if (auth.state !== 'signed-in' && loginWait > 0 && !fresh) {
    console.log(`Log in to Spotify in the ECS window (waiting up to ${loginWait}s)...`);
    const e = await a.waitEvent('auth.changed', loginWait * 1000); auth = (await a.send('auth.status')).result;
    check('auth.changed event after login', !!e);
  }
  if (watchSec > 0) {
    console.log(`Play something in the ECS window. Sampling playback.state for ${watchSec}s...`);
    let maxT = 0, sawAudible = false, first = null;
    for (let i = 0; i < watchSec; i++) {
      const p = (await a.send('playback.state')).result; const t = p.element?.currentTimeSec ?? null;
      if (typeof t === 'number') { if (first === null && t > 0) first = t; maxT = Math.max(maxT, t); } sawAudible ||= !!p.audible;
      console.log(`  ${p.status} audible=${p.audible} t=${t ?? 'unavailable'} elements=${p.elementCount ?? 'unknown'} duration=${p.element?.durationSec ?? 'unavailable'} mediaSession=${p.mediaSession?.playbackState ?? 'unknown'} ${p.mediaSession?.title ?? ''}`); await sleep(1000);
    }
    check('playback observed (audible and position advancing)', sawAudible && first !== null && maxT > first, `first=${first} max=${maxT}`);
  }
  if (expectSignedIn) check('signed in before restart', auth.state === 'signed-in');

  console.log('== B: crash (kill -9) ==');
  a.child.kill('SIGKILL'); const ex = await a.exited;
  check('crash observed by parent', ex.sig === 'SIGKILL');
  await sleep(1500); // let Chromium helpers die and the profile lock release

  console.log('== C: restart ==');
  const b = launch();
  check('restart reaches runtime.ready', !!(await b.waitEvent('runtime.ready', 120000)));
  const auth2 = (await b.send('auth.status')).result;
  console.log('auth.status after restart ->', JSON.stringify(auth2));
  if (!fresh) check('session persisted across restart', auth2.state === auth.state, `${auth.state} -> ${auth2.state}`);
  if (expectSignedIn && !fresh) check('still signed in after restart', auth2.state === 'signed-in');
  const sd = await b.send('shutdown'); check('shutdown acknowledged', sd.ok && sd.result.shuttingDown === true);
  const ex2 = await Promise.race([b.exited, sleep(15000).then(() => null)]);
  check('clean shutdown (exit code 0)', ex2 && ex2.code === 0, JSON.stringify(ex2));
  if (!ex2) b.child.kill('SIGKILL');

  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed ? 1 : 0);
})().catch(e => { console.error('smoke aborted:', e.message); process.exit(2); });
