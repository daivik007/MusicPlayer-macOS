'use strict';
// Test fixture: mimics main.cjs bridge wiring without Electron. Used by bridge.test.cjs over real pipes.
const protocolWrite = process.stdout.write.bind(process.stdout);
process.stdout.write = (...a) => process.stderr.write(...a);
console.log = (...a) => console.error(...a);
const fixtureMode = process.argv[2];
if (fixtureMode === 'ignore-term') process.on('SIGTERM', () => {});
const { createBridge, BridgeError } = require('./bridge.cjs');
const bridge = createBridge({
  input: process.stdin, write: (l, cb) => protocolWrite(l, cb), log: m => console.error('[bridge]', m),
  onInputClosed: () => { console.error('stdin closed'); process.exit(0); },
  handlers: {
    ping: async () => ({ pong: true }),
    'auth.status': async () => ({ state: 'signed-in', basis: 'sp_dc_cookie_presence', verified: false }),
    'playback.state': async () => ({
      available: true, status: 'playing', audible: true,
      mediaSession: { playbackState: 'none', title: 'Fixture track' }, element: null
    }),
    echo: async args => args,
    boom: async () => { throw new Error('secret internal detail'); },
    typed: async () => { throw new BridgeError('custom_code', 'typed failure'); },
    hang: async () => {
      bridge.emit('test.command-pending');
      return new Promise(() => {});
    },
    slow: async () => new Promise(r => setTimeout(() => r({ slow: true }), 50)),
    shutdown: async (_a, c) => {
      if (fixtureMode === 'slow-shutdown') {
        bridge.emit('test.shutdown-pending');
        await new Promise(resolve => setTimeout(resolve, 200));
      }
      c.afterResponse(() => process.exit(0));
      return { shuttingDown: true };
    }
  }
});
console.log('this stray console.log must not reach stdout');
bridge.emit('runtime.starting', { pid: process.pid });

if (fixtureMode === 'duplicate') process.exit(73);
else if (fixtureMode === 'slow-ready') setTimeout(() => bridge.emit('runtime.ready'), 1500);
else if (fixtureMode && fixtureMode !== 'ignore-term') bridge.emit('runtime.ready');
