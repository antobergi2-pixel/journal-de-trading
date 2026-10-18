#!/usr/bin/env bash
# Construit public/ à partir de site/index.html (source unique du site) et des fichiers d'application (pwa/).
set -euo pipefail
ici="$(cd "$(dirname "$0")" && pwd)"
rm -rf "$ici/public" && mkdir -p "$ici/public"
{
  printf '<!doctype html><html lang="fr"><head><meta charset="utf-8">'
  printf '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">'
  printf '<meta name="hebergement" content="cloudflare"><meta name="robots" content="noindex">'
  # application installable (écran d'accueil iPhone et Android)
  printf '<link rel="manifest" href="/manifest.webmanifest"><meta name="theme-color" content="#07090d">'
  printf '<link rel="apple-touch-icon" href="/apple-touch-icon.png"><link rel="icon" type="image/png" href="/icone-192.png">'
  printf '<meta name="apple-mobile-web-app-capable" content="yes"><meta name="mobile-web-app-capable" content="yes">'
  printf '<meta name="apple-mobile-web-app-title" content="Commissions"><meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">'
  printf '</head><body>\n'
  cat "$ici/../site/index.html"
  printf '\n</body></html>\n'
} > "$ici/public/index.html"
cp "$ici/pwa/manifest.webmanifest" "$ici/pwa/sw.js" "$ici"/pwa/*.png "$ici/public/"
echo "public/ construit."
