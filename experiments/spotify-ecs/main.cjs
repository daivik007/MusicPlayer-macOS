const { app, BrowserWindow, Menu, dialog, components } = require('electron');
const path = require('node:path');

// Independent persistent profile; never read Chrome, Phi or native app data.
app.setPath('userData', path.join(app.getPath('appData'), 'MusicPlayer-ECS-Experiment'));
const home = 'https://open.spotify.com/';
let win;
function allowed(raw) {
  try {
    const u = new URL(raw);
    return u.protocol === 'https:' && !u.username && !u.password &&
      (!u.port || u.port === '443') &&
      (u.hostname === 'spotify.com' || u.hostname.endsWith('.spotify.com'));
  } catch { return false; }
}
async function diagnostics() {
  if (!win || win.isDestroyed() || !allowed(win.webContents.getURL())) return;
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
    console.log('Capability report:', JSON.stringify(report, null, 2));
    dialog.showMessageBox(win, {title:'ECS diagnostics', message:'Capability report printed in terminal', detail:JSON.stringify(report,null,2)});
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
  wc.session.setPermissionRequestHandler((_wc,_permission,callback) => callback(false));
  wc.session.setPermissionCheckHandler(() => false);
  wc.on('did-fail-load', (_e,code,_description,_url,isMainFrame) => {
    if (isMainFrame && code !== -3) console.log('Main frame load failed:',code);
  });
  win.on('closed', () => { win = null; });
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    {label:'MusicPlayer ECS',submenu:[{role:'quit'}]},
    {label:'Experiment',submenu:[
      {label:'Spotify Home',click:()=>win?.loadURL(home).catch(()=>{})},
      {role:'reload'}, {label:'Run Capability Diagnostics',accelerator:'CmdOrCtrl+Shift+D',click:diagnostics},
      {role:'toggleDevTools'}
    ]},
    {role:'editMenu'}, {role:'windowMenu'}
  ]));
  await win.loadURL(home);
}
app.whenReady().then(async () => {
  console.log('Runtime:', process.platform, process.arch, process.versions.electron, process.versions.chrome);
  if (!components?.whenReady) throw new Error('Castlabs components API missing; check installed runtime.');
  console.log('Waiting for Widevine component initialization...');
  await components.whenReady();
  console.log('Components ready (not proof of license or playback).');
  await createWindow();
}).catch(error => {
  console.error('Startup failed:', error.message);
  dialog.showErrorBox('ECS startup failed', 'Component initialization or browser startup failed. See terminal output.');
  app.quit();
});
app.on('window-all-closed', () => app.quit());
