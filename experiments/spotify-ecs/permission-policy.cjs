const trustedOrigin = 'https://open.spotify.com';
function trusted(raw) {
  try { const u = new URL(raw); return u.origin === trustedOrigin &&
    !u.username && !u.password; } catch { return false; }
}
function drmAllowed(permission, topURL, requester, isMainFrame, securityOrigin) {
  return permission === 'mediaKeySystem' && trusted(topURL) &&
    trusted(requester) && isMainFrame !== false &&
    (securityOrigin == null || trusted(securityOrigin));
}
function syncAllowed(permission, requester, topURL, worker, isMainFrame, securityOrigin) {
  return permission === 'background-sync' && trusted(requester) &&
    (securityOrigin == null || trusted(securityOrigin)) &&
    (worker === true || (trusted(topURL) && isMainFrame !== false));
}
module.exports = { trusted, drmAllowed, syncAllowed };
