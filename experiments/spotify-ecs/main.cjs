const { app, BrowserWindow, Menu, dialog, components } = require('electron');
const path = require('node:path');
const {openTest,closeTests} = require('./self-tests.cjs');
const { trusted, drmAllowed, syncAllowed } = require('./permission-policy.cjs');
const {installMediaTrace}=require('./media-trace.cjs');
let mediaTrace;

// Independent persistent profile; never read Chrome, Phi or native app data.
app.setPath('userData', path.join(app.getPath('appData'), 'MusicPlayer-ECS-Experiment'));
const home = 'https://open.spotify.com/';
let win;
const trace = [];
let started = Date.now();
function record(event, details = {}) {
  trace.push({ms: Date.now() - started, event, ...details});
  if (trace.length > 180) trace.shift();
}
function resetTrace() { trace.length = 0; started = Date.now(); record('reset'); if(win && !win.isDestroyed() && trusted(win.webContents.getURL())) win.webContents.executeJavaScriptInIsolatedWorld(1001,[{code:'if(globalThis.__ecsTrace) globalThis.__ecsTrace.length=0'}]).catch(()=>{}); }
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
    report.chromiumMediaTrace=mediaTrace?.status()??'unavailable';
    report.components = componentVersions();
    report.runtime = { audible: win.webContents.isCurrentlyAudible(), muted: win.webContents.isAudioMuted() };
    report.trace = trace.slice();
    console.log('Capability report:', JSON.stringify(report, null, 2));
    dialog.showMessageBox(win, {title:'ECS diagnostics', message:'Capability report printed in terminal', detail:'Copy the report from the terminal. Trace is limited to 180 events.'});
  } catch { console.log('Diagnostics failed or navigation interrupted.'); }
}
async function createWindow() {
  win = new BrowserWindow({width:1100,height:760,title:'MusicPlayer ECS experiment',
    webPreferences:{nodeIntegration:false,contextIsolation:true,sandbox:true,webSecurity:true,partition:'persist:spotify-ecs'}});
  const wc = win.webContents;
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
      for(const name of ['loadstart','loadedmetadata','canplay','play','playing','pause','waiting','stalled','error','encrypted','ended','abort','emptied']) {
        document.addEventListener(name,e=>{
          const m=e.target;if(!(m instanceof HTMLMediaElement))return;
          events.push({event:name,time:Math.round(m.currentTime*10)/10,readyState:m.readyState,networkState:m.networkState,errorCode:m.error?.code??null});
          if(events.length>80)events.shift();
        },true);
      }
    })()`}]).catch(()=>{});
  });
  wc.on('media-started-playing', () => record('media-started'));
  wc.on('media-paused', () => record('media-paused'));
  wc.on('audio-state-changed', (_event, audible) => record('audio-state', {audible: typeof audible === 'boolean' ? audible : wc.isCurrentlyAudible()}));
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
  wc.on('render-process-gone', () => record('renderer-gone'));
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
      {label:'Enable Chromium Media Trace',click:()=>mediaTrace?.enable()}, {role:'toggleDevTools'}
    ]},
    {role:'editMenu'}, {role:'windowMenu'}
  ]));
  await mediaTrace.enable();
  await win.loadURL(home);
}
app.whenReady().then(async () => {
  console.log('Runtime:', process.platform, process.arch, process.versions.electron, process.versions.chrome);
  if (!components?.whenReady) throw new Error('Castlabs components API missing; check installed runtime.');
  console.log('Waiting for Widevine component initialization...');
  await components.whenReady();
  console.log('Components ready (not proof of license or playback).');
  console.log('Component versions:', JSON.stringify(componentVersions()));
  await createWindow();
}).catch(error => {
  console.error('Startup failed:', error.message);
  dialog.showErrorBox('ECS startup failed', 'Component initialization or browser startup failed. See terminal output.');
  app.quit();
});
app.on('window-all-closed', () => app.quit());
