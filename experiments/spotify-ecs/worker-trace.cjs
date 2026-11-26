// Observe service workers without registering, replacing or modifying them.
function installWorkerTrace(session, record, trusted) {
  const workers=session.serviceWorkers;
  if(!workers?.on){record('sw-monitor-unavailable');return;}
  const status=new Set(['starting','running','stopping','stopped']);
  function isTrustedVersion(id){
    try{const info=workers.getWorkerFromVersionID(id);return trusted(info?.scope) || trusted(info?.scriptUrl);}catch{return false;}
  }
  // Electron's service-worker console messages may contain credentials or URLs.
  // Only record severity, never the message or source location.
  workers.on('console-message',(_event,details)=>{
    if(!isTrustedVersion(details?.versionId))return;
    const level=details?.level;
    record('sw-console',{level:typeof level==='number' && Number.isInteger(level)?level:['info','warning','error','debug','verbose'].includes(level)?level:'unknown'});
  });
  workers.on('registration-completed',(_event,details)=>{
    if(trusted(details?.scope))record('sw-registered');
  });
  workers.on('running-status-changed',(_event,details)=>{
    if(isTrustedVersion(details?.versionId))record('sw-running-status',{status:status.has(details?.runningStatus)?details.runningStatus:'unknown'});
  });
  record('sw-monitor-installed');
}
module.exports={installWorkerTrace};
