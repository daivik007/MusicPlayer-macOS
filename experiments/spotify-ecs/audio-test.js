'use strict';
const player=document.getElementById('player'), status=document.getElementById('status');
const line=s=>status.textContent=(status.textContent+s+'\n').slice(-4000);
let ctx, url;
function wav(){
  const rate=44100,n=rate*5,b=new ArrayBuffer(44+n*2),v=new DataView(b);
  const str=(o,s)=>{for(let i=0;i<s.length;i++)v.setUint8(o+i,s.charCodeAt(i));};
  str(0,'RIFF');v.setUint32(4,36+n*2,true);str(8,'WAVE');str(12,'fmt ');
  v.setUint32(16,16,true);v.setUint16(20,1,true);v.setUint16(22,1,true);
  v.setUint32(24,rate,true);v.setUint32(28,rate*2,true);v.setUint16(32,2,true);v.setUint16(34,16,true);str(36,'data');v.setUint32(40,n*2,true);
  for(let i=0;i<n;i++)v.setInt16(44+i*2,Math.round(32767*.08*Math.sin(2*Math.PI*440*i/rate)*Math.min(1,i/1000,(n-i)/1000)),true);
  return new Blob([b],{type:'audio/wav'});
}
for(const e of ['playing','waiting','stalled','ended','error','pause'])player.addEventListener(e,()=>line('WAV '+e+' time='+player.currentTime.toFixed(2)+' error='+(player.error?.code??'none')));
document.getElementById('wav').onclick=async()=>{try{if(ctx){await ctx.close();ctx=null;}player.pause();if(url)URL.revokeObjectURL(url);url=URL.createObjectURL(wav());player.src=url;await player.play();line('WAV play accepted');}catch(e){line(e.name);}};
document.getElementById('osc').onclick=async()=>{try{player.pause();if(ctx)await ctx.close();ctx=new AudioContext();await ctx.resume();const o=ctx.createOscillator(),g=ctx.createGain();g.gain.value=.05;o.frequency.value=440;o.connect(g).connect(ctx.destination);o.start();o.stop(ctx.currentTime+5);line('Web Audio running: '+ctx.state);o.onended=()=>line('Web Audio ended');}catch(e){line(e.name);}};
