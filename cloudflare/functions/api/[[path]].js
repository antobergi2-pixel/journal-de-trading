// API du suivi des commissions (Cloudflare Pages Functions + D1).
//   GET    /api/data             tous les documents, groupés par collection
//   PUT    /api/:collection/:id  crée ou remplace un document
//   PATCH  /api/:collection/:id  fusionne des champs dans un document existant
//   DELETE /api/:collection/:id  supprime un document
// Chaque requête doit porter le jeton de Cloudflare Access : sans lui, rien n'est lu ni écrit,
// même si l'application Access était mal configurée.

const COLLECTIONS = new Set(["clients", "ventes", "paiements", "suivis", "factures", "parametres"]);
const ID_VALIDE = /^[A-Za-z0-9_.~:@+-]{1,200}$/;
const TAILLE_MAX = 256 * 1024;

const json = (corps, status = 200) =>
  new Response(JSON.stringify(corps), { status, headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" } });

export async function onRequest({ request, env, params }) {
  const acces = await verifierAcces(request, env);
  if (!acces.ok) return json({ erreur: acces.raison }, 403);

  const morceaux = [].concat(params.path || []);
  const methode = request.method;

  if (morceaux.length === 1 && morceaux[0] === "data" && methode === "GET") {
    const { results } = await env.DB.prepare("SELECT collection, id, data FROM docs ORDER BY collection, id").all();
    const sortie = Object.fromEntries([...COLLECTIONS].map(c => [c, []]));
    for (const r of results) sortie[r.collection].push({ id: r.id, data: JSON.parse(r.data) });
    return json(sortie);
  }

  // Fichier calendrier d'un rendez-vous, avec ses rappels : l'iPhone l'ajoute à Calendrier et sonne aux bons moments
  if (morceaux.length === 2 && morceaux[0] === "ics" && methode === "GET") {
    const id = morceaux[1].replace(/\.ics$/, "");
    if (!ID_VALIDE.test(id)) return json({ erreur: "identifiant invalide" }, 400);
    const ligne = await env.DB.prepare("SELECT data FROM docs WHERE collection = 'suivis' AND id = ?").bind(id).first();
    if (!ligne) return json({ erreur: "rendez-vous introuvable" }, 404);
    const rdv = JSON.parse(ligne.data);
    if (!rdv.datePrevue || !rdv.heure) return json({ erreur: "le rendez-vous n'a pas d'heure" }, 400);
    const cl = await env.DB.prepare("SELECT data FROM docs WHERE collection = 'clients' AND id = ?").bind(rdv.clientId || "").first();
    return new Response(calendrier(id, rdv, cl ? JSON.parse(cl.data).nom : "Client"), {
      headers: { "content-type": "text/calendar; charset=utf-8", "content-disposition": `inline; filename="rdv-${id}.ics"`, "cache-control": "no-store" } });
  }

  if (morceaux.length !== 2) return json({ erreur: "chemin inconnu" }, 404);
  const [collection, id] = morceaux;
  if (!COLLECTIONS.has(collection) || !ID_VALIDE.test(id) || id === "." || id === "..") return json({ erreur: "collection ou identifiant invalide" }, 400);

  if (methode === "DELETE") {
    await env.DB.prepare("DELETE FROM docs WHERE collection = ? AND id = ?").bind(collection, id).run();
    return new Response(null, { status: 204 });
  }

  if (methode === "PUT" || methode === "PATCH") {
    const texte = await request.text();
    if (texte.length > TAILLE_MAX) return json({ erreur: "document trop volumineux" }, 413);
    let corps;
    try { corps = JSON.parse(texte); } catch { return json({ erreur: "JSON invalide" }, 400); }
    if (!corps || typeof corps !== "object" || Array.isArray(corps)) return json({ erreur: "le document doit être un objet" }, 400);
    if (methode === "PUT") {
      await env.DB.prepare(
        "INSERT INTO docs (collection, id, data) VALUES (?, ?, ?) " +
        "ON CONFLICT (collection, id) DO UPDATE SET data = excluded.data, maj_le = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')"
      ).bind(collection, id, JSON.stringify(corps)).run();
      return new Response(null, { status: 204 });
    }
    // PATCH : fusion de premier niveau, comme la base de claude.ai pour les champs simples
    const ligne = await env.DB.prepare("SELECT data FROM docs WHERE collection = ? AND id = ?").bind(collection, id).first();
    if (!ligne) return json({ erreur: "document absent" }, 400);
    const fusion = { ...JSON.parse(ligne.data), ...corps };
    await env.DB.prepare("UPDATE docs SET data = ?, maj_le = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE collection = ? AND id = ?")
      .bind(JSON.stringify(fusion), collection, id).run();
    return new Response(null, { status: 204 });
  }

  return json({ erreur: "méthode non permise" }, 405);
}

// ---------------------------------------------------------------------------
// Calendrier (RFC 5545). Heure « flottante » : l'iPhone l'interprète dans son propre fuseau horaire.
const RAPPELS_DEFAUT = [1440, 300, 30];
const echapper = t => String(t ?? "").replace(/\\/g, "\\\\").replace(/;/g, "\\;").replace(/,/g, "\\,").replace(/\r?\n/g, "\\n");
const plier = l => { const out = []; let x = l; while (new TextEncoder().encode(x).length > 73) { let n = 73; while (new TextEncoder().encode(x.slice(0, n)).length > 73) n--; out.push(x.slice(0, n)); x = " " + x.slice(n); } out.push(x); return out.join("\r\n"); };
const duree = m => m % 1440 === 0 ? `-P${m / 1440}D` : m % 60 === 0 ? `-PT${m / 60}H` : `-PT${m}M`;
const libelle = m => m % 1440 === 0 ? `${m / 1440} jour${m > 1440 ? "s" : ""}` : m % 60 === 0 ? `${m / 60} h` : `${m} min`;
function calendrier(id, rdv, client) {
  const [y, mo, d] = rdv.datePrevue.split("-").map(Number), [h, mi] = rdv.heure.split(":").map(Number);
  const deb = new Date(Date.UTC(y, mo - 1, d, h, mi)), fin = new Date(deb.getTime() + 3600_000);
  const flottant = t => t.toISOString().replace(/[-:]/g, "").slice(0, 15);
  const titre = `RDV ${client}${rdv.closer ? ` avec ${rdv.closer}` : ""}`;
  const rappels = Array.isArray(rdv.rappels) ? rdv.rappels : RAPPELS_DEFAUT;
  const lignes = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Suivi des commissions//FR", "CALSCALE:GREGORIAN", "METHOD:PUBLISH", "BEGIN:VEVENT",
    `UID:${id}@suivi-commissions`, `DTSTAMP:${new Date().toISOString().replace(/[-:]/g, "").slice(0, 15)}Z`,
    `DTSTART:${flottant(deb)}`, `DTEND:${flottant(fin)}`, `SUMMARY:${echapper(titre)}`,
    `DESCRIPTION:${echapper([rdv.sujet, rdv.closer ? `Closer : ${rdv.closer}` : ""].filter(Boolean).join("\n"))}`];
  for (const m of rappels) if (m > 0) lignes.push("BEGIN:VALARM", "ACTION:DISPLAY", `DESCRIPTION:${echapper(`${titre} dans ${libelle(m)}`)}`, `TRIGGER:${duree(m)}`, "END:VALARM");
  lignes.push("END:VEVENT", "END:VCALENDAR");
  return lignes.map(plier).join("\r\n") + "\r\n";
}

// ---------------------------------------------------------------------------
// Vérification du jeton Cloudflare Access (JWT RS256 signé par ton équipe Zero Trust).
// Variables : TEAM_DOMAIN (ex. "monequipe.cloudflareaccess.com"), POLICY_AUD (étiquette AUD
// de l'application Access) et EMAIL_AUTORISE (ton adresse, seule acceptée).
// En développement local seulement : DEV_LOCAL = "1" dans .dev.vars et adresse localhost.
let certsCache = { cles: null, expire: 0 };

async function verifierAcces(request, env) {
  const hote = new URL(request.url).hostname;
  if (env.DEV_LOCAL === "1" && (hote === "localhost" || hote === "127.0.0.1")) return { ok: true };
  if (!env.TEAM_DOMAIN || !env.POLICY_AUD || !env.EMAIL_AUTORISE) return { ok: false, raison: "Cloudflare Access n'est pas configuré" };
  const jeton = request.headers.get("cf-access-jwt-assertion");
  if (!jeton) return { ok: false, raison: "connexion Cloudflare Access requise" };
  try {
    const [h, p, s] = jeton.split(".");
    const entete = JSON.parse(texteB64(h)), charge = JSON.parse(texteB64(p));
    if (entete.alg !== "RS256") throw new Error("algorithme");
    const cle = (await cles(env.TEAM_DOMAIN)).find(k => k.kid === entete.kid);
    if (!cle) throw new Error("clé inconnue");
    const pub = await crypto.subtle.importKey("jwk", cle, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
    const valide = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", pub, octetsB64(s), new TextEncoder().encode(`${h}.${p}`));
    if (!valide) throw new Error("signature");
    const maintenant = Date.now() / 1000;
    const aud = [].concat(charge.aud || []);
    if (!aud.includes(env.POLICY_AUD)) throw new Error("audience");
    if (charge.iss !== `https://${env.TEAM_DOMAIN}`) throw new Error("émetteur");
    if (!(charge.exp > maintenant) || (charge.nbf && charge.nbf > maintenant + 60)) throw new Error("expiré");
    if (String(charge.email || "").toLowerCase() !== env.EMAIL_AUTORISE.toLowerCase()) throw new Error("adresse non autorisée");
    return { ok: true };
  } catch (e) {
    return { ok: false, raison: "jeton Cloudflare Access refusé (" + e.message + ")" };
  }
}

async function cles(domaine) {
  if (certsCache.cles && Date.now() < certsCache.expire) return certsCache.cles;
  const r = await fetch(`https://${domaine}/cdn-cgi/access/certs`);
  if (!r.ok) throw new Error("certificats indisponibles");
  certsCache = { cles: (await r.json()).keys || [], expire: Date.now() + 3600_000 };
  return certsCache.cles;
}

function octetsB64(b64url) {
  const b64 = b64url.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((b64url.length + 3) % 4);
  return Uint8Array.from(atob(b64), c => c.charCodeAt(0));
}
const texteB64 = s => new TextDecoder().decode(octetsB64(s));
