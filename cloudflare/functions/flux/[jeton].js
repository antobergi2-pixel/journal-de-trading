// Flux d'abonnement iCal : les RDV clients et les tâches, pour Google Agenda ou le Calendrier de l'iPhone.
//   GET /flux/<jeton>.ics
// Cette adresse est hors de Cloudflare Access (Google doit pouvoir la lire sans se connecter) :
// elle n'est protégée que par son jeton secret, long et aléatoire, que l'utilisateur peut changer dans l'application.
import { versUtc } from "../agenda.js";

const RAPPELS_DEFAUT = [1440, 300, 30];
const echapper = t => String(t ?? "").replace(/\\/g, "\\\\").replace(/;/g, "\;").replace(/,/g, "\\,").replace(/\r?\n/g, "\\n");
const plier = l => { const out = []; let x = l; const n = s => new TextEncoder().encode(s).length; while (n(x) > 73) { let k = 73; while (n(x.slice(0, k)) > 73) k--; out.push(x.slice(0, k)); x = " " + x.slice(k); } out.push(x); return out.join("\r\n"); };
const utc = ms => new Date(ms).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
const jourIcs = iso => iso.replace(/-/g, "");
const lendemain = iso => { const d = new Date(iso + "T00:00:00Z"); d.setUTCDate(d.getUTCDate() + 1); return d.toISOString().slice(0, 10); };
const duree = m => m % 1440 === 0 ? `-P${m / 1440}D` : m % 60 === 0 ? `-PT${m / 60}H` : `-PT${m}M`;
const libelle = m => m % 1440 === 0 ? `${m / 1440} jour${m > 1440 ? "s" : ""}` : m % 60 === 0 ? `${m / 60} h` : `${m} min`;

function egal(a, b) {   // comparaison à temps constant
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let r = 0; for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i); return r === 0;
}

export async function onRequestGet({ params, env }) {
  const jeton = String(params.jeton || "").replace(/\.ics$/, "");
  const refus = () => new Response("Introuvable", { status: 404, headers: { "cache-control": "no-store" } });
  if (!/^[A-Za-z0-9_-]{32,128}$/.test(jeton)) return refus();
  const p = await env.DB.prepare("SELECT data FROM docs WHERE collection = 'parametres' AND id = 'flux'").first();
  const reglage = p ? JSON.parse(p.data) : null;
  if (!reglage || !egal(jeton, reglage.jeton || "")) return refus();
  const tz = reglage.tz || "America/Toronto";

  const { results: clients } = await env.DB.prepare("SELECT id, data FROM docs WHERE collection = 'clients'").all();
  const nomClient = Object.fromEntries(clients.map(c => [c.id, JSON.parse(c.data).nom || "Client"]));
  const depuis = new Date(Date.now() - 30 * 86400000).toISOString().slice(0, 10);
  const { results } = await env.DB.prepare("SELECT id, data FROM docs WHERE collection = 'suivis'").all();

  const lignes = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Suivi des commissions//FR", "CALSCALE:GREGORIAN", "METHOD:PUBLISH",
    "X-WR-CALNAME:Commissions - RDV et tâches", `X-WR-TIMEZONE:${tz}`, "REFRESH-INTERVAL;VALUE=DURATION:PT15M", "X-PUBLISHED-TTL:PT15M"];
  const maintenant = utc(Date.now());
  for (const r of results) {
    const s = JSON.parse(r.data);
    if (!s.datePrevue || s.datePrevue < depuis || s.statut === "annule") continue;
    if (s.type !== "rencontre" && s.type !== "tache") continue;
    const rdv = s.type === "rencontre", client = s.clientId ? nomClient[s.clientId] : "";
    const titre = rdv ? `RDV ${client || "client"}${s.closer ? ` avec ${s.closer}` : ""}` : `${s.statut === "fait" ? "✓ " : ""}${s.sujet || "Tâche"}`;
    lignes.push("BEGIN:VEVENT", `UID:${r.id}@suivi-commissions`, `DTSTAMP:${maintenant}`, `SUMMARY:${echapper(titre)}`,
      `DESCRIPTION:${echapper([rdv ? s.sujet : "", client && !rdv ? `Client : ${client}` : "", s.closer ? `Closer : ${s.closer}` : ""].filter(Boolean).join("\n"))}`);
    if (s.heure && /^\d{2}:\d{2}$/.test(s.heure)) {
      const [y, mo, d] = s.datePrevue.split("-").map(Number), [h, mi] = s.heure.split(":").map(Number);
      const deb = versUtc(y, mo, d, h, mi, 0, tz), fin = deb + (Number(s.duree) || (rdv ? 60 : 30)) * 60000;
      lignes.push(`DTSTART:${utc(deb)}`, `DTEND:${utc(fin)}`);
      const rappels = Array.isArray(s.rappels) ? s.rappels : (rdv ? RAPPELS_DEFAUT : []);
      for (const m of rappels) if (m > 0) lignes.push("BEGIN:VALARM", "ACTION:DISPLAY", `DESCRIPTION:${echapper(`${titre} dans ${libelle(m)}`)}`, `TRIGGER:${duree(m)}`, "END:VALARM");
    } else {
      lignes.push(`DTSTART;VALUE=DATE:${jourIcs(s.datePrevue)}`, `DTEND;VALUE=DATE:${jourIcs(lendemain(s.datePrevue))}`);
    }
    if (s.statut === "fait") lignes.push("STATUS:CONFIRMED", "TRANSP:TRANSPARENT");
    lignes.push("END:VEVENT");
  }
  lignes.push("END:VCALENDAR");
  return new Response(lignes.map(plier).join("\r\n") + "\r\n", {
    headers: { "content-type": "text/calendar; charset=utf-8", "cache-control": "no-store", "x-robots-tag": "noindex" } });
}
