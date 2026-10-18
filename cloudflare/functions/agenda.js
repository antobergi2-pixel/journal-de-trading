// Lecture d'un agenda Google (adresse secrète iCal) : analyse RFC 5545, fuseaux horaires, récurrences courantes.
// Utilisé par l'API (/api/agenda). Ne garde rien : l'agenda est relu à chaque demande (cache Cloudflare de 5 min).

export const URL_GOOGLE = /^https:\/\/calendar\.google\.com\/calendar\/ical\/[^\s/]+\/[^\s/]+\/basic\.ics$/;

const JOURS = { SU: 0, MO: 1, TU: 2, WE: 3, TH: 4, FR: 5, SA: 6 };

function lignes(texte) {
  return texte.replace(/\r\n[ \t]/g, "").replace(/\n[ \t]/g, "").split(/\r?\n/);
}
function propriete(ligne) {
  const i = ligne.indexOf(":"); if (i < 0) return null;
  const [nom, ...params] = ligne.slice(0, i).split(";");
  const p = {}; for (const x of params) { const [k, v] = x.split("="); p[k.toUpperCase()] = (v || "").replace(/^"|"$/g, ""); }
  return { nom: nom.toUpperCase(), params: p, valeur: ligne.slice(i + 1) };
}
const texte = v => v.replace(/\\n/gi, "\n").replace(/\\([,;\\])/g, "$1");

// Décalage d'un fuseau (ms) à un instant donné
function decalage(instant, tz) {
  const f = new Intl.DateTimeFormat("en-US", { timeZone: tz, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit" });
  const o = Object.fromEntries(f.formatToParts(new Date(instant)).map(x => [x.type, x.value]));
  return Date.UTC(+o.year, +o.month - 1, +o.day, +o.hour, +o.minute, +o.second) - instant;
}
// Heure murale (dans le fuseau tz) -> instant UTC
export function versUtc(y, m, d, h, mi, s, tz) {
  const brut = Date.UTC(y, m - 1, d, h, mi, s);
  if (!tz) return brut;
  try { let t = brut - decalage(brut, tz); t = brut - decalage(t, tz); return t; } catch { return brut; }
}
function date(v, params, tzDefaut) {
  const m = v.match(/^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?$/);
  if (!m) return null;
  const [, y, mo, d, h, mi, s, z] = m;
  if (!h) return { journee: true, local: [+y, +mo, +d, 0, 0, 0], tz: null };
  return { journee: false, local: [+y, +mo, +d, +h, +mi, +s], tz: z ? "UTC" : (params.TZID || tzDefaut || null) };
}
const instant = dt => dt.journee ? Date.UTC(dt.local[0], dt.local[1] - 1, dt.local[2]) : versUtc(...dt.local, dt.tz === "UTC" ? null : dt.tz);
function duree(v) {
  const m = v.match(/^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/); if (!m) return 0;
  return (m[1] === "-" ? -1 : 1) * (((+m[2] || 0) * 7 + (+m[3] || 0)) * 86400 + (+m[4] || 0) * 3600 + (+m[5] || 0) * 60 + (+m[6] || 0)) * 1000;
}

export function lireAgenda(ics) {
  const evts = []; let cour = null, tzCal = null;
  for (const l of lignes(ics)) {
    if (l === "BEGIN:VEVENT") { cour = { exdates: [] }; continue; }
    if (l === "END:VEVENT") { if (cour?.debut) evts.push(cour); cour = null; continue; }
    const p = propriete(l); if (!p) continue;
    if (!cour) { if (p.nom === "X-WR-TIMEZONE") tzCal = p.valeur; continue; }
    if (p.nom === "DTSTART") cour.debut = date(p.valeur, p.params, tzCal);
    else if (p.nom === "DTEND") cour.fin = date(p.valeur, p.params, tzCal);
    else if (p.nom === "DURATION") cour.duree = duree(p.valeur);
    else if (p.nom === "SUMMARY") cour.titre = texte(p.valeur);
    else if (p.nom === "LOCATION") cour.lieu = texte(p.valeur);
    else if (p.nom === "UID") cour.uid = p.valeur;
    else if (p.nom === "STATUS") cour.statut = p.valeur.toUpperCase();
    else if (p.nom === "RRULE") cour.rrule = Object.fromEntries(p.valeur.split(";").map(x => x.split("=")));
    else if (p.nom === "EXDATE") for (const v of p.valeur.split(",")) { const d = date(v, p.params, tzCal); if (d) cour.exdates.push(instant(d)); }
    else if (p.nom === "RECURRENCE-ID") { const d = date(p.valeur, p.params, tzCal); if (d) cour.recurrenceId = instant(d); }
  }
  return { evts, tzCal };
}

// Occurrences dans [de, a[ (instants UTC en ms)
export function occurrences({ evts }, de, a) {
  const modifiees = new Map();
  for (const e of evts) if (e.recurrenceId !== undefined) { if (!modifiees.has(e.uid)) modifiees.set(e.uid, new Set()); modifiees.get(e.uid).add(e.recurrenceId); }
  const out = [];
  const pousser = (e, debut) => {
    const longueur = e.fin ? instant(e.fin) - instant(e.debut) : (e.duree ?? (e.debut.journee ? 86400000 : 0));
    const fin = debut + Math.max(0, longueur);
    if (fin > de && debut < a || (debut >= de && debut < a)) out.push({ titre: e.titre || "(sans titre)", lieu: e.lieu || "", debut: new Date(debut).toISOString(), fin: new Date(fin).toISOString(), journee: e.debut.journee });
  };
  for (const e of evts) {
    if (e.statut === "CANCELLED") continue;
    if (!e.rrule || e.recurrenceId !== undefined) { pousser(e, instant(e.debut)); continue; }
    const r = e.rrule, freq = r.FREQ, intervalle = Math.max(1, +r.INTERVAL || 1), compte = r.COUNT ? +r.COUNT : Infinity;
    const jusqua = r.UNTIL ? instant(date(r.UNTIL, {}, e.debut.tz) || { journee: true, local: [9999, 1, 1] }) : Infinity;
    const exclues = new Set([...e.exdates, ...(modifiees.get(e.uid) || [])]);
    const [y0, m0, d0, h, mi, s] = e.debut.local;
    const tz = e.debut.journee ? null : (e.debut.tz === "UTC" ? null : e.debut.tz);
    const quand = (y, m, d) => e.debut.journee ? Date.UTC(y, m - 1, d) : versUtc(y, m, d, h, mi, s, tz);
    const base = Date.UTC(y0, m0 - 1, d0);
    let n = 0, iter = 0;
    const essayer = (y, m, d) => {
      const t = quand(y, m, d); if (t < instant(e.debut)) return true;
      if (t > jusqua || n >= compte) return false;
      n++; if (!exclues.has(t)) pousser(e, t);
      return t < a;
    };
    let continuer = true;
    while (continuer && iter++ < 3000) {
      if (freq === "DAILY") { const x = new Date(base + (iter - 1) * intervalle * 86400000); continuer = essayer(x.getUTCFullYear(), x.getUTCMonth() + 1, x.getUTCDate()); }
      else if (freq === "WEEKLY") {
        const jours = (r.BYDAY ? r.BYDAY.split(",").map(j => JOURS[j.slice(-2)]) : [new Date(base).getUTCDay()]).sort((p, q) => p - q);
        const lundi = base - ((new Date(base).getUTCDay() + 6) % 7) * 86400000 + (iter - 1) * intervalle * 7 * 86400000;
        for (const j of jours) { const x = new Date(lundi + ((j + 6) % 7) * 86400000); if (!(continuer = essayer(x.getUTCFullYear(), x.getUTCMonth() + 1, x.getUTCDate()))) break; }
      } else if (freq === "MONTHLY") {
        const x = new Date(Date.UTC(y0, m0 - 1 + (iter - 1) * intervalle, 1)), jm = r.BYMONTHDAY ? +r.BYMONTHDAY : d0;
        const dernier = new Date(Date.UTC(x.getUTCFullYear(), x.getUTCMonth() + 1, 0)).getUTCDate();
        continuer = jm <= dernier ? essayer(x.getUTCFullYear(), x.getUTCMonth() + 1, jm) : quand(x.getUTCFullYear(), x.getUTCMonth() + 1, 1) < a;
      } else if (freq === "YEARLY") { continuer = essayer(y0 + (iter - 1) * intervalle, m0, d0); }
      else { pousser(e, instant(e.debut)); break; }
    }
  }
  return out.sort((p, q) => p.debut.localeCompare(q.debut));
}
