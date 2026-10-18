// Service worker de l'application : garde la page et les icônes en mémoire pour un démarrage rapide.
// Les données (/api) ne sont jamais mises en cache : elles viennent toujours de la base D1.
const CACHE = "suivi-commissions-v4";
const COQUILLE = ["/", "/manifest.webmanifest", "/icone-192.png", "/icone-512.png", "/apple-touch-icon.png"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(COQUILLE)).catch(() => {}).then(() => self.skipWaiting()));
});
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(cles => Promise.all(cles.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener("fetch", e => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== location.origin || url.pathname.startsWith("/api/") || url.pathname.startsWith("/cdn-cgi/")) return;
  // Réseau d'abord (toujours la dernière version), copie en mémoire si le réseau ne répond pas.
  e.respondWith(fetch(e.request).then(rep => {
    if (rep.ok && rep.type === "basic") { const copie = rep.clone(); caches.open(CACHE).then(c => c.put(e.request, copie)); }
    return rep;
  }).catch(() => caches.match(e.request, { ignoreSearch: true }).then(r => r || caches.match("/"))));
});
