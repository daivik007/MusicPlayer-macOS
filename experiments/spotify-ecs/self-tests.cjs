const { BrowserWindow } = require('electron');
const path = require('node:path');
const labURL = 'https://castlabs.github.io/wv-vmp-lab/';
const windows = new Set();
function labOrigin(raw) {
  try { const u = new URL(raw); return u.origin === 'https://castlabs.github.io' && !u.username && !u.password; } catch { return false; }
}
function labPage(raw) {
  try { return labOrigin(raw) && new URL(raw).pathname.startsWith('/wv-vmp-lab/'); } catch { return false; }
}
function openTest(kind, log) {
  const lab = kind === 'drm';
  const w = new BrowserWindow({width:1000,height:760,title:lab?'Independent Widevine test':'Local audio test',
    webPreferences:{nodeIntegration:false,contextIsolation:true,sandbox:true,webSecurity:true,partition:lab?'ecs-lab':'ecs-local-audio'}});
  windows.add(w);
  const wc = w.webContents;
  const emit = (event, data={}) => log(kind + ':' + event,data);
  wc.session.setPermissionRequestHandler((sender,permission,cb,details)=>{
    const grant = lab && sender===wc && permission==='mediaKeySystem' && labPage(wc.getURL()) && labOrigin(details?.requestingUrl) && details?.isMainFrame!==false && (!details?.securityOrigin || labOrigin(details.securityOrigin));
    emit('permission',{permission,granted:grant}); cb(grant);
  });
  wc.session.setPermissionCheckHandler((sender,permission,origin,details)=>{
    const grant = lab && sender===wc && permission==='mediaKeySystem' && labPage(wc.getURL()) && labOrigin(origin) && details?.isMainFrame!==false && (!details?.requestingUrl || labOrigin(details.requestingUrl)) && (!details?.securityOrigin || labOrigin(details.securityOrigin));
    emit('permission-check',{permission,granted:grant}); return grant;
  });
  wc.on('will-navigate',(e,url)=>{if (!lab || !labPage(url)) e.preventDefault();});
  wc.on('will-redirect',(e,url)=>{if (!lab || !labPage(url)) e.preventDefault();});
  wc.setWindowOpenHandler(()=>({action:'deny'}));
  wc.on('media-started-playing',()=>emit('media-started'));
  wc.on('media-paused',()=>emit('media-paused'));
  wc.on('audio-state-changed',()=>emit('audio-state',{audible:wc.isCurrentlyAudible()}));
  wc.on('did-fail-load',(_e,code,_desc,_url,main)=>{if(main && code!==-3) emit('load-failed',{code});});
  w.on('closed',()=>windows.delete(w));
  const load=lab?w.loadURL(labURL):w.loadFile(path.join(__dirname,'audio-test.html'));
  load.catch(()=>emit('load-error'));
}
function closeTests(){for(const w of windows) if(!w.isDestroyed()) w.close();}
module.exports={openTest,closeTests};
