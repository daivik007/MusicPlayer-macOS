const { app, BrowserWindow, Menu, dialog, components } = require('electron');
const path = require('node:path');
const {openTest,closeTests} = require('./self-tests.cjs');
const { trusted, drmAllowed, syncAllowed } = require('./permission-policy.cjs');
const {installMediaTrace}=require('./media-trace.cjs');
const {installWorkerTrace}=require('./worker-trace.cjs');
const freshSession=process.argv.includes('--fresh-session');
const partition=freshSession?'spotify-ecs-fresh-'+require('node:crypto').randomUUID():'persist:spotify-ecs';
let mediaTrace;
// One-variable experiment: --clean-ua replaces Electron's UA (app name + Electron token) with the plain Chromium UA that Phi sends. Nothing else changes.
const cleanUA=process.argv.includes('--clean-ua');
const cleanUserAgent=`Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${process.versions.chrome.split('.')[0]}.0.0.0 Safari/537.36`;

// Independent persistent profile; never read Chrome, Phi or native app data.
app.setPath('userData', path.join(app.getPath('appData'), 'MusicPlayer-ECS-Experiment'));
const home = 'https://open.spotify.com/';
let win;

// ---- M4B stdio bridge (opt-in via --bridge). Protocol lines go to the real stdout; all other output goes to stderr. ----
const bridgeMode = process.argv.includes('--bridge');
let bridge = null, bridgeHandlers = null, runtimeReady = false, duplicateInstance = false, exitReason = null;
function requestQuit(reason) { exitReason = exitReason ?? reason; app.quit(); setTimeout(() => app.exit(0), 8000).unref(); }
if (bridgeMode) {
  const protocolWrite = process.stdout.write.bind(process.stdout);
  process.stdout.write = (...args) => process.stderr.write(...args); // stray writes can never corrupt the protocol
  for (const m of ['log', 'info', 'debug']) console[m] = (...a) => console.error(...a);
  const { createBridge } = require('./bridge.cjs');
  const { createHandlers } = require('./bridge-handlers.cjs');
  bridgeHandlers = createHandlers({
    pid: process.pid, startedAtMs: Date.now(), now: () => Date.now(),
    versions: { electron: process.versions.electron, chrome: process.versions.chrome, node: process.versions.node, app: app.getVersion() },
    config: { sessionMode: freshSession ? 'fresh-in-memory' : 'persistent', uaMode: cleanUA ? 'clean-chromium' : 'electron-default' },
    getWebContents: () => (win && !win.isDestroyed() ? win.webContents : null),
    isReady: () => runtimeReady, trusted, requestQuit
  });
  bridge = createBridge({
    input: process.stdin, write: (line, cb) => protocolWrite(line, cb), handlers: bridgeHandlers,
    log: m => console.error('[bridge]', m), onInputClosed: () => requestQuit('stdin-closed') // parent gone => no orphan runtime
  });
  process.on('SIGTERM', () => requestQuit('sigterm'));
  process.on('SIGINT', () => requestQuit('sigint'));
  bridge.emit('runtime.starting', { pid: process.pid, protocol: 1 });
  if (!app.requestSingleInstanceLock()) { // one runtime per profile directory
    duplicateInstance = true;
    bridge.emit('runtime.error', { code: 'duplicate_instance', message: 'Another ECS runtime already owns this profile' }, () => app.exit(73));
  }
}
const trace = [];
let started = Date.now();
function record(event, details = {}) {
  trace.push({ms: Date.now() - started, event, ...details});
  if (trace.length > 180) trace.shift();
}
function resetTrace() { trace.length = 0; started = Date.now(); record('reset'); if(win && !win.isDestroyed() && trusted(win.webContents.getURL())) win.webContents.executeJavaScriptInIsolatedWorld(1001,[{code:'if(globalThis.__ecsTrace) globalThis.__ecsTrace.length=0; if(globalThis.__ecsWorkerTrace) globalThis.__ecsWorkerTrace.length=0'}]).catch(()=>{}); }
function permissionLabel(p) { return typeof p==='string' && /^[A-Za-z][A-Za-z0-9-]{0,63}$/.test(p) ? p : 'unknown'; }
function componentVersions() {
  try {
    const states=components.status();
    return Object.entries(states ?? {}).map(([id,value])=>({
      id: /^[a-z0-9_-]{1,64}$/i.test(id)?id:'unknown',
      version: [value?.version,value?.installedVersion,value?.currentVersion].find(v=>typeof v==='string' && /^\\d+(\\.\\d+){1,5}$/.test(v)) ?? 'not reported'
    }));
  } catch { return []; }
}
function networkKind(raw, type) {
  try {
    const u = new URL(raw);
    if (u.protocol !== 'https:') return null;
    const h = u.hostname;
    if (!(h === 'spotify.com' || h.endsWith('.spotify.com') || h.endsWith('.scdn.co') || h.endsWith('.spotifycdn.com'))) return null;
    if (/license|licence|widevine/i.test(u.pathname)) return 'possible-license';
    if (type === 'media') return 'media';
    if (type === 'xhr' || type === 'webSocket') return type;
    return null;
  } catch { return null; }
}
function allowed(raw) {
  try {
    const u = new URL(raw);
    return u.protocol === 'https:' && !u.username && !u.password &&
      (!u.port || u.port === '443') &&
      (u.hostname === 'spotify.com' || u.hostname.endsWith('.spotify.com'));
  } catch { return false; }
}
async function diagnostics() {
  if (!win || win.isDestroyed() || !trusted(win.webContents.getURL())) return;
  try {
    const report = await win.webContents.executeJavaScript(`(async () => {
      const a = document.createElement('audio');
      const probe = async (contentType, kind) => {
        try {
          await navigator.requestMediaKeySystemAccess('com.widevine.alpha', [{
            [kind]: [{contentType}], sessionTypes: ['temporary']
          }]);
          return 'accepted';
        } catch (e) { return e.name; }
      };
      return {
        userAgent: navigator.userAgent,
        browserIdentity: {
          platform: navigator.platform,
          userAgentData: navigator.userAgentData?.toJSON?.() ?? null,
          maxTouchPoints: navigator.maxTouchPoints,
          viewport: {width:innerWidth,height:innerHeight,devicePixelRatio},
          finePointer: matchMedia('(pointer: fine)').matches,
          hover: matchMedia('(hover: hover)').matches,
          secureContext: isSecureContext
        },
        bundleHints: (() => {
          const names = [...Array.from(document.scripts, s => s.src), ...performance.getEntriesByType('resource').filter(r => r.initiatorType === 'script').map(r => r.name)];
          const paths = names.flatMap(n => { try { const u = new URL(n); return [u.pathname]; } catch { return []; } });
          return {mobile: paths.some(p => p.includes('mobile-web-player')), desktop: paths.some(p => p.includes('desktop-web-player')), generic: paths.some(p => /(?:^|\\/)web-player[.~-]/.test(p))};
        })(),
        visibility: document.visibilityState,
        aac: a.canPlayType('audio/mp4; codecs="mp4a.40.2"'),
        opus: a.canPlayType('audio/webm; codecs="opus"'),
        mp3: a.canPlayType('audio/mpeg'),
        widevineAAC: await probe('audio/mp4; codecs="mp4a.40.2"', 'audioCapabilities'),
        widevineOpus: await probe('audio/webm; codecs="opus"', 'audioCapabilities'),
        widevineVP9: await probe('video/webm; codecs="vp9"', 'videoCapabilities'),
        media: [...document.querySelectorAll('audio,video')].slice(0,12).map(m => ({
          paused:m.paused, currentTime:m.currentTime, readyState:m.readyState,
          networkState:m.networkState, errorCode:m.error?.code ?? null
        }))
      };
    })()`);
    report.domMediaEvents = await win.webContents.executeJavaScriptInIsolatedWorld(1001,[{code:'globalThis.__ecsTrace ?? []'}]).catch(()=>[]);
    report.sessionMode = freshSession ? 'fresh-in-memory' : 'persistent';
    report.uaMode = cleanUA ? 'clean-chromium' : 'electron-default';
    report.serviceWorker = await win.webContents.executeJavaScript(`(async()=>{
      if(!navigator.serviceWorker)return {available:false};
      try{
        const regs=await navigator.serviceWorker.getRegistrations();
        return {available:true,controlled:!!navigator.serviceWorker.controller,
          controllerState:navigator.serviceWorker.controller?.state??null,
          registrations:regs.slice(0,12).map(r=>({active:r.active?.state??null,waiting:r.waiting?.state??null,installing:r.installing?.state??null,syncAvailable:!!r.sync})),
          navigationType:performance.getEntriesByType('navigation')[0]?.type??null};
      }catch(e){return {available:true,error:e.name};}
    })()`).catch(()=>({available:false}));
    report.workerPageEvents=await win.webContents.executeJavaScriptInIsolatedWorld(1001,[{code:'globalThis.__ecsWorkerTrace ?? []'}]).catch(()=>[]);
    report.chromiumMediaTrace=mediaTrace?.status()??'unavailable';
    report.components = componentVersions();
    report.runtime = { audible: win.webContents.isCurrentlyAudible(), muted: win.webContents.isAudioMuted() };
    report.trace = trace.slice();
    console.log('Capability report:', JSON.stringify(report, null, 2));
    dialog.showMessageBox(win, {title:'ECS diagnostics', message:'Capability report printed in terminal', detail:'Copy the report from the terminal. Trace is limited to 180 events.'});
  } catch { console.log('Diagnostics failed or navigation interrupted.'); }
}
async function createWindow() {
  win = new BrowserWindow({width:1100,height:760,title:freshSession?'MusicPlayer ECS — Fresh session':'MusicPlayer ECS experiment',
    webPreferences:{nodeIntegration:false,contextIsolation:true,sandbox:true,webSecurity:true,partition}});
  const wc = win.webContents;
  if (cleanUA) { wc.session.setUserAgent(cleanUserAgent); wc.setUserAgent(cleanUserAgent); } // session covers workers, wc covers this page
  installWorkerTrace(wc.session,record,trusted);
  if (bridge) { // push auth transitions so the parent need not poll while the user logs in
    let authTimer;
    wc.session.cookies.on('changed', (_e, cookie) => {
      if (cookie?.name !== 'sp_dc') return;
      clearTimeout(authTimer);
      authTimer = setTimeout(async () => {
        try { const r = await bridgeHandlers['auth.status']({}, { afterResponse() {} }); bridge.emit('auth.changed', { state: r.state }); } catch {}
      }, 400);
    });
  }
  wc.on('will-navigate', (e,url) => { if (!allowed(url)) e.preventDefault(); });
  wc.on('will-redirect', (e,url) => { if (!allowed(url)) e.preventDefault(); });
  wc.setWindowOpenHandler(({url}) => {
    if (allowed(url)) setImmediate(() => { if (!wc.isDestroyed()) wc.loadURL(url).catch(() => {}); });
    return {action:'deny'};
  });
  wc.session.setPermissionRequestHandler((requestWC, permission, callback, details) => {
    const grant = requestWC === wc && (drmAllowed(permission, wc.getURL(),
      details?.requestingUrl, details?.isMainFrame, details?.securityOrigin) ||
      syncAllowed(permission, details?.requestingUrl, wc.getURL(), false, details?.isMainFrame, details?.securityOrigin));
    record('permission-request', {permission: permissionLabel(permission), granted: grant, trustedRequester: trusted(details?.requestingUrl)});
    callback(grant);
  });
  wc.session.setPermissionCheckHandler((requestWC, permission, requestingOrigin, details) => {
    const grant = (requestWC === wc || requestWC === null) &&
      (!details?.requestingUrl || trusted(details.requestingUrl)) &&
      ((requestWC === wc && drmAllowed(permission, wc.getURL(), requestingOrigin, details?.isMainFrame, details?.securityOrigin)) ||
      syncAllowed(permission, requestingOrigin, wc.getURL(), requestWC === null, details?.isMainFrame, details?.securityOrigin));
    record('permission-check', {permission: permissionLabel(permission), granted: grant, trustedRequester: trusted(requestingOrigin), workerContext: requestWC === null});
    return grant;
  });
  wc.on('did-finish-load', () => {
    if (!trusted(wc.getURL())) return;
    wc.executeJavaScriptInIsolatedWorld(1001,[{code:`(() => {
      if(globalThis.__ecsTrace) return;
      const events=[];globalThis.__ecsTrace=events;
      const workerEvents=[];globalThis.__ecsWorkerTrace=workerEvents;
      const pushWorker=(event,state)=>{workerEvents.push({event,state});if(workerEvents.length>40)workerEvents.shift();};
      if(navigator.serviceWorker){
        const watched=new WeakSet();
        const watch=w=>{if(!w||watched.has(w))return;watched.add(w);pushWorker('worker-state',w.state);w.addEventListener('statechange',()=>pushWorker('worker-state',w.state));w.addEventListener('error',()=>pushWorker('worker-error',w.state));};
        const watchReg=r=>{watch(r.installing);watch(r.waiting);watch(r.active);r.addEventListener('updatefound',()=>watch(r.installing));};
        navigator.serviceWorker.addEventListener('controllerchange',()=>pushWorker('controller-change',navigator.serviceWorker.controller?.state??null));
        navigator.serviceWorker.getRegistrations().then(rs=>rs.forEach(watchReg)).catch(e=>pushWorker('registration-query-error',e.name));
      }
      for(const name of ['loadstart','loadedmetadata','canplay','play','playing','pause','waiting','stalled','error','encrypted','ended','abort','emptied']) {
        document.addEventListener(name,e=>{
          const m=e.target;if(!(m instanceof HTMLMediaElement))return;
          events.push({event:name,time:Math.round(m.currentTime*10)/10,readyState:m.readyState,networkState:m.networkState,errorCode:m.error?.code??null});
          if(events.length>80)events.shift();
        },true);
      }
    })()`}]).catch(()=>{});
  });
  wc.on('media-started-playing', () => { record('media-started'); bridge?.emit('playback.changed', {reason: 'media-started'}); });
  wc.on('media-paused', () => { record('media-paused'); bridge?.emit('playback.changed', {reason: 'media-paused'}); });
  wc.on('audio-state-changed', (_event, audible) => { const a = typeof audible === 'boolean' ? audible : wc.isCurrentlyAudible(); record('audio-state', {audible: a}); bridge?.emit('playback.changed', {reason: 'audio-state', audible: a}); });
  wc.on('did-start-loading', () => record('loading-start'));
  wc.on('did-stop-loading', () => record('loading-stop'));
  // Electron navigation events have used both positional and details-object signatures.
  const navDetails=(urlOrDetails,inPlace,main)=>typeof urlOrDetails==='object' && urlOrDetails!==null
    ? {mainFrame:!!urlOrDetails.isMainFrame,inPage:!!(urlOrDetails.isInPlace??urlOrDetails.isSameDocument),trusted:trusted(urlOrDetails.url)}
    : {mainFrame:!!main,inPage:!!inPlace,trusted:trusted(urlOrDetails)};
  wc.on('did-start-navigation',(_e,u,inPlace,main)=>record('navigation-start',navDetails(u,inPlace,main)));
  wc.on('did-redirect-navigation',(_e,u,inPlace,main)=>record('navigation-redirect',navDetails(u,inPlace,main)));
  wc.on('did-navigate-in-page',(_e,u,main)=>record('navigation-in-page',navDetails(u,true,main)));
  wc.on('did-frame-navigate',(_e,u,status,_statusText,main)=>record('navigation-commit',{...navDetails(u,false,main),status:Number.isInteger(status)?status:null}));
  wc.on('did-fail-provisional-load',(_e,code,_desc,_url,main)=>record('navigation-failed',{code,mainFrame:!!main}));
  mediaTrace=installMediaTrace(wc,record,trusted);
  wc.on('render-process-gone', (_e,details) => { record('renderer-gone'); console.log('Renderer exited:',details.reason,details.exitCode); });
  wc.session.webRequest.onCompleted(details => {
    const kind = networkKind(details.url, details.resourceType);
    if (kind && (kind === 'possible-license' || kind === 'media' || details.statusCode >= 400))
      record('network-completed', {kind, status: details.statusCode});
  });
  wc.session.webRequest.onErrorOccurred(details => {
    const kind = networkKind(details.url, details.resourceType);
    if (kind) record('network-failed', {kind, error: /^net::ERR_[A-Z0-9_]+$/.test(details.error) ? details.error : 'other'});
  });
  wc.on('did-fail-load', (_e,code,_description,_url,isMainFrame) => {
    if (isMainFrame && code !== -3) console.log('Main frame load failed:',code);
  });
  win.on('closed', () => { win = null; closeTests(); });
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    {label:'MusicPlayer ECS',submenu:[{role:'quit'}]},
    {label:'Experiment',submenu:[
      {label:'Spotify Home',click:()=>win?.loadURL(home).catch(()=>{})},
      {role:'reload'}, {label:'Test Unencrypted Audio',click:()=>openTest('audio',record)}, {label:'Test Widevine (Castlabs Lab)',click:()=>openTest('drm',record)}, {label:'Reset Playback Trace',click:resetTrace}, {label:'Run Capability Diagnostics',accelerator:'CmdOrCtrl+Shift+D',click:diagnostics},
      {label:'Enable Chromium Media Trace',click:()=>mediaTrace?.enable()}, {label:'Disable Chromium Media Trace',click:()=>mediaTrace?.disable()}, {role:'toggleDevTools'}
    ]},
    {role:'editMenu'}, {role:'windowMenu'}
  ]));
  // Diagnostics must never gate navigation; CDP is opt-in after the page loads.
  console.log('Session:',freshSession?'fresh-in-memory':'persistent');
  console.log('UA mode:',cleanUA?'clean-chromium':'electron-default');
  console.log('Loading Spotify (Chromium Media Trace off by default)...');
  await win.loadURL(home);
  console.log('Spotify document loaded.');
  runtimeReady = true;
  bridge?.emit('runtime.ready', {pid: process.pid, uaMode: cleanUA ? 'clean-chromium' : 'electron-default', sessionMode: freshSession ? 'fresh-in-memory' : 'persistent'});
}
app.whenReady().then(async () => {
  if (duplicateInstance) return; // exiting with code 73
  console.log('Runtime:', process.platform, process.arch, process.versions.electron, process.versions.chrome);
  if (!components?.whenReady) throw new Error('Castlabs components API missing; check installed runtime.');
  console.log('Waiting for Widevine component initialization...');
  await components.whenReady();
  console.log('Components ready (not proof of license or playback).');
  console.log('Component versions:', JSON.stringify(componentVersions()));
  await createWindow();
}).catch(error => {
  console.error('Startup failed:', error.message);
  bridge?.emit('runtime.error', {code: 'startup_failed', message: String(error.message).slice(0, 200)});
  dialog.showErrorBox('ECS startup failed', 'Component initialization or browser startup failed. See terminal output.');
  app.quit();
});
app.on('before-quit', () => bridge?.emit('runtime.exiting', {reason: exitReason ?? 'app-quit'}));
app.on('window-all-closed', () => { exitReason = exitReason ?? 'window-closed'; app.quit(); });
