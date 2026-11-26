const test = require('node:test');
const assert = require('node:assert/strict');
const {drmAllowed} = require('./permission-policy.cjs');
const origin = 'https://open.spotify.com';
test('allow Spotify protected media', () => assert.equal(drmAllowed('mediaKeySystem', origin, origin, true), true));
test('deny other permissions', () => assert.equal(drmAllowed('media', origin, origin, true), false));
test('deny foreign requesting origin', () => assert.equal(drmAllowed('mediaKeySystem', origin, 'https://example.com', true), false));
test('deny foreign top level', () => assert.equal(drmAllowed('mediaKeySystem', 'https://example.com', origin, true), false));
test('deny explicit subframes, missing origin, and mismatched security origin', () => {
  assert.equal(drmAllowed('mediaKeySystem', origin, origin, false), false);
  assert.equal(drmAllowed('mediaKeySystem', origin, undefined, true), false);
  assert.equal(drmAllowed('mediaKeySystem', origin, origin, true, 'https://example.com'), false);
});
test('deny lookalike and insecure origins', () => {
  for (const raw of ['https://open.spotify.com.example.org','http://open.spotify.com','https://open.spotify.com:444'])
    assert.equal(drmAllowed('mediaKeySystem', origin, raw, true), false);
});
