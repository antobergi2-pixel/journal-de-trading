#!/usr/bin/env bash
# Construit public/index.html à partir de site/index.html (source unique du site).
set -euo pipefail
ici="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ici/public"
{
  printf '<!doctype html><html lang="fr"><head><meta charset="utf-8">'
  printf '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">'
  printf '<meta name="hebergement" content="cloudflare"><meta name="robots" content="noindex">'
  printf '</head><body>\n'
  cat "$ici/../site/index.html"
  printf '\n</body></html>\n'
} > "$ici/public/index.html"
echo "public/index.html construit."
