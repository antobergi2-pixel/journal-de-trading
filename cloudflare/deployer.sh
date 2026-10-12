#!/usr/bin/env bash
# Met en ligne le suivi des commissions sur Cloudflare (Pages + D1 + Access).
# Peut être relancé sans risque : il réutilise ce qui existe déjà et ne touche jamais aux données.
#
# Variables requises :
#   CLOUDFLARE_API_TOKEN   jeton avec : D1 (Edit), Cloudflare Pages (Edit),
#                          Access: Apps and Policies (Edit), Access: Organizations (Read)
#   CLOUDFLARE_ACCOUNT_ID  identifiant du compte Cloudflare
#   EMAIL_AUTORISE         la seule adresse courriel qui pourra ouvrir le site
set -euo pipefail
ici="$(cd "$(dirname "$0")" && pwd)"
: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN manquant}"
: "${CLOUDFLARE_ACCOUNT_ID:?CLOUDFLARE_ACCOUNT_ID manquant}"
: "${EMAIL_AUTORISE:?EMAIL_AUTORISE manquant}"
export CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID WRANGLER_SEND_METRICS=false
PROJET="suivi-commissions"
API="https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID"
WR=(npx --yes wrangler@3.99.0)

cf() { curl -sS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "content-type: application/json" "$@"; }
# champ JSON : lit l'entrée standard, affiche la valeur au chemin donné (vide si absente)
champ() { python3 -c 'import json,sys
d=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d = d[int(k)] if isinstance(d, list) and k.isdigit() and int(k) < len(d) else (d.get(k) if isinstance(d, dict) else None)
    if d is None: break
print("" if d is None else d)' "$1"; }
verifie() { python3 -c 'import json,sys
d=json.load(sys.stdin)
if not d.get("success"):
    sys.exit("Erreur Cloudflare (" + sys.argv[1] + ") : " + "; ".join(e.get("message","?") for e in d.get("errors",[])))' "$1"; }

echo "1/6 Base de données D1"
id_db=$(cf "$API/d1/database?name=$PROJET" | champ result.0.uuid)
if [ -z "$id_db" ]; then
  rep=$(cf -X POST "$API/d1/database" -d "{\"name\":\"$PROJET\"}"); echo "$rep" | verifie "création D1"
  id_db=$(echo "$rep" | champ result.uuid)
fi
echo "    $PROJET ($id_db)"

echo "2/6 Projet Pages"
rep=$(cf "$API/pages/projects/$PROJET")
if [ "$(echo "$rep" | champ success)" != "True" ]; then
  rep=$(cf -X POST "$API/pages/projects" -d "{\"name\":\"$PROJET\",\"production_branch\":\"main\"}"); echo "$rep" | verifie "création Pages"
fi
domaine=$(echo "$rep" | champ result.subdomain)
echo "    https://$domaine"

echo "3/6 Cloudflare Access (Zero Trust)"
equipe=$(cf "$API/access/organizations" | champ result.auth_domain)
if [ -z "$equipe" ]; then
  echo "Zero Trust n'est pas encore activé sur ce compte. Dans le tableau de bord Cloudflare : Zero Trust,"
  echo "choisis un nom d'équipe et le forfait gratuit (Free), puis relance ce script." >&2
  exit 1
fi
apps=$(cf "$API/access/apps")
id_app=$(echo "$apps" | python3 -c 'import json,sys
for a in json.load(sys.stdin).get("result") or []:
    if a.get("domain") == sys.argv[1]: print(a["id"]); break' "$domaine")
if [ -z "$id_app" ]; then
  rep=$(cf -X POST "$API/access/apps" -d "$(python3 -c 'import json,sys
d=sys.argv[1]
print(json.dumps({"name":"Suivi des commissions","type":"self_hosted","domain":d,
  "destinations":[{"type":"public","uri":d},{"type":"public","uri":"*."+d}],
  "session_duration":"720h","app_launcher_visible":False}))' "$domaine")")
  echo "$rep" | verifie "application Access"
  id_app=$(echo "$rep" | champ result.id)
  rep=$(cf -X POST "$API/access/apps/$id_app/policies" -d "$(python3 -c 'import json,sys
print(json.dumps({"name":"Moi seulement","decision":"allow","precedence":1,"include":[{"email":{"email":sys.argv[1]}}]}))' "$EMAIL_AUTORISE")")
  echo "$rep" | verifie "règle Access"
fi
aud=$(cf "$API/access/apps/$id_app" | champ result.aud)
echo "    équipe $equipe, accès réservé à $EMAIL_AUTORISE"

echo "4/6 Préparation (copie de travail, rien n'est écrit dans le dépôt)"
travail="$ici/.deploiement"; rm -rf "$travail"; mkdir -p "$travail"
cp -r "$ici/functions" "$ici/schema.sql" "$travail/"
"$ici/construire.sh" >/dev/null && cp -r "$ici/public" "$travail/"
python3 - "$ici/wrangler.toml" "$travail/wrangler.toml" "$id_db" "$equipe" "$aud" "$EMAIL_AUTORISE" <<'PY'
import sys, re
src, dst, id_db, equipe, aud, email = sys.argv[1:]
t = open(src, encoding="utf-8").read()
for cle, val in [("database_id", id_db), ("TEAM_DOMAIN", equipe), ("POLICY_AUD", aud), ("EMAIL_AUTORISE", email)]:
    t = re.sub(rf'^{cle} = ".*"$', f'{cle} = "{val}"', t, flags=re.M)
open(dst, "w", encoding="utf-8").write(t)
PY

echo "5/6 Tables de la base"
(cd "$travail" && "${WR[@]}" d1 execute "$PROJET" --remote --file schema.sql -y)

echo "6/6 Mise en ligne"
(cd "$travail" && "${WR[@]}" pages deploy public --project-name "$PROJET" --branch main --commit-dirty=true)

echo
echo "C'est en ligne : https://$domaine"
echo "À la première visite, Cloudflare envoie un code à $EMAIL_AUTORISE pour te connecter."
