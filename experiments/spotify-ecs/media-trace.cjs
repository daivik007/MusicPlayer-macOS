// Read-only Chromium DevTools Media domain. Never export raw messages, URLs or player IDs.
function installMediaTrace(wc, record, trusted) {
  const ids=new Map();
  let state='not attached';
  let seq=0;
  const num=id=>{if(!ids.has(id)){if(ids.size>=128)ids.clear();ids.set(id,++seq);}return ids.get(id);};
  const enumValue=v=>typeof v==='string' && /^(?:k[A-Z][A-Za-z0-9_]{0,70}|PIPELINE_[A-Z0-9_]{1,70}|DEMUXER_[A-Z0-9_]{1,70}|DECODER_[A-Z0-9_]{1,70}|MEDIA_[A-Z0-9_]{1,70}|BUFFERING_[A-Z0-9_]{1,70})$/.test(v)?v:'other';
  const listener=(_event,method,p)=>{
    if(!trusted(wc.getURL()))return;
    if(method==='Media.playersCreated') for(const id of (p.players??[]).slice(0,32)) record('cdp-player-created',{player:num(id)});
    if(method==='Media.playerErrorsRaised') for(const e of (p.errors??[]).slice(0,16)) record('cdp-player-error',{player:num(p.playerId),code:Number.isInteger(e.code)?e.code:null,group:enumValue(e.group)});
    if(method==='Media.playerEventsAdded') for(const e of (p.events??[]).slice(0,32)){
      try {const v=JSON.parse(e.value);const name=enumValue(v.event);if(name!=='other')record('cdp-player-event',{player:num(p.playerId),name});}catch{}
    }
    if(method==='Media.playerPropertiesChanged') for(const prop of (p.properties??[]).slice(0,32)){
      if(['kIsAudioDecryptingDemuxerStream','kIsPlatformAudioDecoder','kIsVideoDecryptingDemuxerStream','kIsPlatformVideoDecoder'].includes(prop.name))
        record('cdp-player-property',{player:num(p.playerId),name:prop.name,value:prop.value==='true'?true:prop.value==='false'?false:null});
    }
  };
  wc.debugger.on('message',listener);
  wc.debugger.on('detach',()=>{state='detached';record('cdp-detached');});
  async function enable(){
    try{
      if(!wc.debugger.isAttached())wc.debugger.attach('1.3');
      await wc.debugger.sendCommand('Media.enable');
      state='enabled';record('cdp-enabled');
    }catch{state='unavailable';record('cdp-unavailable');}
  }
  return {enable,status:()=>state};
}
module.exports={installMediaTrace};
