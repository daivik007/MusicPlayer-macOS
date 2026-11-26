'use strict';
// Test fixture: mimics main.cjs bridge wiring without Electron. Used by bridge.test.cjs over real pipes.
const protocolWrite = process.stdout.write.bind(process.stdout);
process.stdout.write = (...a) => process.stderr.write(...a);
console.log = (...a) => console.error(...a);
const { createBridge, BridgeError } = require('./bridge.cjs');
const bridge = createBridge({
  input: process.stdin, write: (l, cb) => protocolWrite(l, cb), log: m => console.error('[bridge]', m),
  onInputClosed: () => { console.error('stdin closed'); process.exit(0); },
  handlers: {
    ping: async () => ({ pong: true }),
    echo: async args => args,
    boom: async () => { throw new Error('secret internal detail'); },
    typed: async () => { throw new BridgeError('custom_code', 'typed failure'); },
    slow: async () => new Promise(r => setTimeout(() => r({ slow: true }), 50)),
    shutdown: async (_a, c) => { c.afterResponse(() => process.exit(0)); return { shuttingDown: true }; }
  }
});
console.log('this stray console.log must not reach stdout');
bridge.emit('runtime.starting', { pid: process.pid });
