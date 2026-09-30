// Keeps a copy of the page on the device so the deck can open before the network is up.
//
// A kiosk iPad launches the deck the moment it boots, before Wi-Fi and Tailscale have
// connected. Without a copy that first load fails, and a Home Screen web app shows a
// white page with nothing to retry it. With one, the page opens from the copy, shows
// "bridge offline", and its own reconnect loop picks the stream up once the network is.
//
// Network first, so an edited index.html still arrives on the next load; the copy is used
// only when the network fails or is slower than TIMEOUT_MS. Only page loads are handled —
// the event stream, the API and icons never pass through here.
var CACHE = 'agentdeck-page-v1';
var TIMEOUT_MS = 4000;

self.addEventListener('install', function () { self.skipWaiting(); });
self.addEventListener('activate', function (e) { e.waitUntil(self.clients.claim()); });

self.addEventListener('fetch', function (e) {
  if (e.request.mode !== 'navigate') return;
  e.respondWith(fromNetwork(e.request).catch(function () {
    return caches.open(CACHE)
      .then(function (c) { return c.match(e.request, { ignoreSearch: true }); })
      .then(function (hit) { return hit || Response.error(); });
  }));
});

// A load that outlives the timeout still finishes and refreshes the copy; it just no
// longer decides what this launch shows.
function fromNetwork(request) {
  return new Promise(function (resolve, reject) {
    var timer = setTimeout(function () { reject(new Error('timeout')); }, TIMEOUT_MS);
    fetch(request).then(function (res) {
      clearTimeout(timer);
      if (res.ok) {
        var copy = res.clone();
        caches.open(CACHE).then(function (c) { return c.put(request, copy); });
      }
      resolve(res);
    }, function (err) {
      clearTimeout(timer);
      reject(err);
    });
  });
}
