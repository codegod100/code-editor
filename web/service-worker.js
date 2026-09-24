// Keep editor resources available after the first successful visit without
// storing authenticated API responses or authentication pages in Cache Storage.
const CACHE_NAME = 'cloud-code-editor-v3';
const APP_SHELL = [
  './',
  './index.html',
  './manifest.json',
  './favicon-cloud-code-editor.png',
  './icons/cloud-code-editor-192.png',
  './icons/cloud-code-editor-512.png',
  './icons/cloud-code-editor-maskable-192.png',
  './icons/cloud-code-editor-maskable-512.png',
];

const isAppAsset = (url) =>
  url.origin === self.location.origin &&
  !url.pathname.startsWith('/api/') &&
  !url.pathname.startsWith('/auth/');

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_SHELL)),
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(
          keys
            .filter((key) => key.startsWith('cloud-code-editor-') && key !== CACHE_NAME)
            .map((key) => caches.delete(key)),
        ),
      )
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', (event) => {
  const { request } = event;
  const url = new URL(request.url);

  if (request.method !== 'GET' || !isAppAsset(url)) return;

  if (request.mode === 'navigate') {
    const response = fetch(request);
    event.respondWith(
      response.catch(() => caches.match('./index.html')),
    );
    event.waitUntil(
      response
        .then((result) => caches.open(CACHE_NAME).then((cache) => cache.put('./index.html', result.clone())))
        .catch(() => undefined),
    );
    return;
  }

  const network = fetch(request)
    .then((response) => {
      if (response.ok && response.type === 'basic') {
        return caches
          .open(CACHE_NAME)
          .then((cache) => cache.put(request, response.clone()))
          .then(() => response);
      }
      return response;
    })
    .catch(() => undefined);
  event.waitUntil(network);

  event.respondWith(
    caches.match(request).then((cached) => cached || network),
  );
});
