#!/usr/bin/env python3
"""Suivi des paiements et commissions (SQLite, aucune dépendance).

Consulter
    python crm.py transactions        tableau complet (mêmes colonnes que le gabarit)
    python crm.py clients             ventes, payé, solde dû et commissions par client
    python crm.py du                  ce qui est dû ce mois-ci (et les retards)
    python crm.py recevables          soldes dus par ancienneté
    python crm.py mensuel             REV, encaissements et commissions par mois
    python crm.py recurrent           revenu et commission récurrents par mois
    python crm.py suivis              follow-ups à faire
    python crm.py versements          versements mensuels dus ce mois-ci ou en retard
    python crm.py previsions          encaissements et commissions attendus mois par mois
    python crm.py plan TRANSACTION_ID détail du plan de paiement d'une vente

Saisir
    python crm.py ajouter "Client" REV [--nom ...] [--type ...] [--devise CAD] [--echeance AAAA-MM-JJ]
                          [--follow-up AAAA-MM-JJ] [--versements N | --mensualite 500] [--recurrent mensuel] ...
    python crm.py echeancier TRANSACTION_ID --debut AAAA-MM-JJ (--versements N | --mensualite 500)
    python crm.py payer TRANSACTION_ID MONTANT [--methode Interac] [--date AAAA-MM-JJ]
    python crm.py suivi "Client" "Sujet" --date AAAA-MM-JJ [--transaction ID] [--tous-les 30]
    python crm.py fait SUIVI_ID [--resultat "..."]

Automatiser (à lancer chaque jour ou chaque semaine)
    python crm.py generer             crée les transactions des récurrences arrivées à échéance
    python crm.py relances            crée un follow-up pour chaque paiement en retard

Échanger avec Notion / Google Sheets / Excel
    python crm.py import fichier.csv  importe un fichier au format du gabarit
    python crm.py export fichier.csv  exporte au format du gabarit (colonnes calculées remplies)
"""
import argparse
import csv
import re
import sqlite3
import sys
from datetime import date, datetime, timedelta
from pathlib import Path

ICI = Path(__file__).resolve().parent
SCHEMA = ICI / "schema.sql"
DB_DEFAUT = ICI / "crm.db"

# Colonnes exactes du gabarit -> colonnes de v_transactions
GABARIT = [
    ("Transaction", "transaction_"),
    ("Date de follow up", "prochain_follow_up"),
    ("Date du premier contact", "date_premier_contact"),
    ("Type", "type"),
    ("Client", "client"),
    ("Statut", "statut"),
    ("REV", "rev"),
    ("MONTANT PAYER", "montant_paye"),
    ("Différence REV - payé", "difference_rev_paye"),
    ("MONTANT DE LA COMMISSIONS", "montant_commission"),
    ("DU THIS MONTH", "du_ce_mois"),
    ("Commission 5% REV", "commission_rev"),
    ("Commission 5% REV collecté", "commission_collectee"),
    ("Notes", "notes"),
    ("Devise", "devise"),
    ("Méthode", "methode"),
    ("État", "etat"),
]


def connecter(chemin):
    con = sqlite3.connect(chemin)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA foreign_keys = ON")
    con.executescript(SCHEMA.read_text(encoding="utf-8"))
    return con


def afficher(con, sql, params=()):
    cur = con.execute(sql, params)
    lignes, cols = cur.fetchall(), [d[0].rstrip("_") for d in cur.description]
    if not lignes:
        print("(aucun résultat)")
        return
    fmt = lambda v: "" if v is None else (f"{v:,.2f}".replace(",", " ") if isinstance(v, float) else str(v))
    data = [[fmt(v) for v in r] for r in lignes]
    larg = [max(len(c), *(len(l[i]) for l in data)) for i, c in enumerate(cols)]
    print("  ".join(c.ljust(w) for c, w in zip(cols, larg)))
    print("  ".join("-" * w for w in larg))
    for l in data:
        print("  ".join(v.ljust(w) for v, w in zip(l, larg)))


# ----------------------------------------------------------------------
# Lecture tolérante des montants et des dates (formats Notion / Excel / FR / EN)
# ----------------------------------------------------------------------
def lire_montant(txt):
    if txt is None:
        return None
    s = re.sub(r"[^\d,.\-]", "", str(txt).replace(" ", "").replace(" ", ""))
    if not s or s in "-.,":
        return None
    if "," in s and "." in s:          # 1,234.56 ou 1.234,56
        s = s.replace(",", "") if s.rfind(".") > s.rfind(",") else s.replace(".", "").replace(",", ".")
    elif "," in s:                     # 1234,56 (FR) ou 1,234 (EN milliers)
        s = s.replace(",", "") if re.fullmatch(r"-?\d{1,3}(,\d{3})+", s) else s.replace(",", ".")
    try:
        return round(float(s), 2)
    except ValueError:
        return None


MOIS = {m: i + 1 for i, m in enumerate(
    ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"])}
MOIS.update({m: i + 1 for i, m in enumerate(
    ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"])})
MOIS.update({k[:3]: v for k, v in list(MOIS.items())})
MOIS.update({"fevrier": 2, "aout": 8, "decembre": 12})


def lire_date(txt):
    if not txt or not str(txt).strip():
        return None
    s = str(txt).strip().split("→")[0].strip()          # plages Notion « A → B »
    s = re.sub(r"\s+\d{1,2}:\d{2}.*$", "", s)            # retire l'heure
    for f in ("%Y-%m-%d", "%Y/%m/%d", "%d/%m/%Y", "%d-%m-%Y", "%d.%m.%Y"):
        try:
            return datetime.strptime(s, f).date().isoformat()
        except ValueError:
            pass
    m = re.fullmatch(r"([A-Za-zéû.]+)\s+(\d{1,2}),?\s+(\d{4})", s)          # October 12, 2026
    if m and m.group(1).lower().rstrip(".") in MOIS:
        return date(int(m.group(3)), MOIS[m.group(1).lower().rstrip(".")], int(m.group(2))).isoformat()
    m = re.fullmatch(r"(\d{1,2})(?:er)?\s+([A-Za-zéû.]+)\s+(\d{4})", s)    # 12 octobre 2026
    if m and m.group(2).lower().rstrip(".") in MOIS:
        return date(int(m.group(3)), MOIS[m.group(2).lower().rstrip(".")], int(m.group(1))).isoformat()
    print(f"  ! date non reconnue, ignorée : {txt!r}")
    return None


# ----------------------------------------------------------------------
# Dates de récurrence
# ----------------------------------------------------------------------
def ajouter_mois(d, n):
    m = d.month - 1 + n
    a, m = d.year + m // 12, m % 12 + 1
    fins = [31, 29 if a % 4 == 0 and (a % 100 or a % 400 == 0) else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    return date(a, m, min(d.day, fins[m - 1]))


def periode_suivante(d, frequence, n=1):
    return {"hebdomadaire": lambda: d + timedelta(weeks=n), "aux2semaines": lambda: d + timedelta(weeks=2 * n),
            "mensuel": lambda: ajouter_mois(d, n), "trimestriel": lambda: ajouter_mois(d, 3 * n),
            "semestriel": lambda: ajouter_mois(d, 6 * n), "annuel": lambda: ajouter_mois(d, 12 * n)}[frequence]()


# ----------------------------------------------------------------------
# Opérations
# ----------------------------------------------------------------------
def client_id(con, nom_ou_id, creer=True):
    if str(nom_ou_id).isdigit():
        r = con.execute("SELECT id FROM clients WHERE id=?", (int(nom_ou_id),)).fetchone()
        if r:
            return r["id"]
    r = con.execute("SELECT id FROM clients WHERE nom=?", (str(nom_ou_id).strip(),)).fetchone()
    if r:
        return r["id"]
    if not creer:
        sys.exit(f"Client introuvable : {nom_ou_id}")
    return con.execute("INSERT INTO clients (nom) VALUES (?)", (str(nom_ou_id).strip(),)).lastrowid


def ajouter_transaction(con, client, rev, nom=None, type_=None, statut="en cours", devise="CAD",
                        methode=None, date_tx=None, echeance=None, premier_contact=None,
                        taux=0.05, commission=None, notes=None, recurrence_id=None, follow_up=None):
    cid = client_id(con, client)
    date_tx = date_tx or date.today().isoformat()
    tid = con.execute(
        "INSERT INTO transactions (nom, client_id, recurrence_id, type, statut, date_premier_contact, date_transaction, "
        "date_echeance, rev, taux_commission, commission_manuelle, devise, methode, notes) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (nom or f"{client} {date_tx}", cid, recurrence_id, type_, statut or "en cours", premier_contact, date_tx,
         echeance, rev, taux, commission, (devise or "CAD").upper(), methode, notes)).lastrowid
    if follow_up:
        con.execute("INSERT INTO suivis (client_id, transaction_id, sujet, date_prevue) VALUES (?,?,?,?)",
                    (cid, tid, f"Follow up : {nom or client}", follow_up))
    return tid


def creer_echeancier(con, tid, debut, versements=None, mensualite=None, frequence="mensuel"):
    """Plan de paiement : REV réparti en N versements, ou en versements de `mensualite` (dernier = reste)."""
    rev = con.execute("SELECT rev FROM transactions WHERE id=?", (tid,)).fetchone()["rev"]
    if mensualite:
        mensualite = min(mensualite, rev)
        versements = max(1, int(-(-round(rev, 2) // round(mensualite, 2))))   # arrondi vers le haut
    else:
        mensualite = round(rev / versements, 2)
    con.execute("DELETE FROM echeances WHERE transaction_id=?", (tid,))
    for i in range(versements):
        montant = mensualite if i < versements - 1 else round(rev - mensualite * (versements - 1), 2)
        if montant > 0:
            con.execute("INSERT INTO echeances (transaction_id, date, montant) VALUES (?,?,?)",
                        (tid, periode_suivante(debut, frequence, i).isoformat(), montant))
    return versements


def generer_recurrences(con, jusqua=None):
    jusqua, n = jusqua or date.today(), 0
    for r in con.execute("SELECT r.*, c.nom AS client FROM recurrences r JOIN clients c ON c.id=r.client_id "
                         "WHERE r.actif=1").fetchall():
        d = date.fromisoformat(r["prochaine_date"])
        fin = date.fromisoformat(r["date_fin"]) if r["date_fin"] else None
        while d <= jusqua and (fin is None or d <= fin):
            ajouter_transaction(con, r["client_id"], r["rev"], nom=f"{r['description']} – {d:%Y-%m}",
                                type_=r["type"], statut="récurrent", devise=r["devise"], methode=r["methode"],
                                date_tx=d.isoformat(),
                                echeance=(d + timedelta(days=r["delai_paiement_jours"])).isoformat(),
                                taux=r["taux_commission"], recurrence_id=r["id"])
            d, n = periode_suivante(d, r["frequence"]), n + 1
        con.execute("UPDATE recurrences SET prochaine_date=?, actif=? WHERE id=?",
                    (d.isoformat(), 0 if fin and d > fin else 1, r["id"]))
    con.commit()
    return n


def creer_relances(con):
    rows = con.execute("""
        SELECT v.id, v.client_id, v.transaction_, v.en_retard, v.devise FROM v_transactions v
        WHERE v.en_retard > 0.005 AND NOT EXISTS (
            SELECT 1 FROM suivis s WHERE s.transaction_id = v.id AND s.type='relance_paiement' AND s.statut='a_faire')
    """).fetchall()
    for r in rows:
        con.execute("INSERT INTO suivis (client_id, transaction_id, type, sujet, date_prevue, priorite) "
                    "VALUES (?,?,'relance_paiement',?,date('now'),'haute')",
                    (r["client_id"], r["id"], f"Relancer paiement « {r['transaction_'] } » : {r['en_retard']:.2f} {r['devise']}"))
    con.commit()
    return len(rows)


# ----------------------------------------------------------------------
# Import / export au format du gabarit
# ----------------------------------------------------------------------
def importer(con, fichier):
    with open(fichier, newline="", encoding="utf-8-sig") as fh:
        lecteur = csv.DictReader(fh)
        norm = lambda s: re.sub(r"\s+", " ", s.strip().lower())
        entetes = {norm(h): h for h in lecteur.fieldnames or []}
        col = lambda ligne, nom: (ligne.get(entetes.get(norm(nom), ""), "") or "").strip() or None
        n = plans = 0
        for ligne in lecteur:
            client, nom = col(ligne, "Client"), col(ligne, "Transaction")
            if not (client or nom):
                continue
            rev = lire_montant(col(ligne, "REV")) or 0.0
            paye = lire_montant(col(ligne, "MONTANT PAYER")) or 0.0
            comm = lire_montant(col(ligne, "MONTANT DE LA COMMISSIONS"))
            contact = lire_date(col(ligne, "Date du premier contact"))
            tid = ajouter_transaction(
                con, client or "(sans nom)", rev, nom=nom, type_=col(ligne, "Type"), statut=col(ligne, "Statut"),
                devise=col(ligne, "Devise"), methode=col(ligne, "Méthode"), premier_contact=contact,
                date_tx=contact, notes=col(ligne, "Notes"),
                commission=comm if comm is not None and abs(comm - rev * 0.05) > 0.01 else None,
                follow_up=lire_date(col(ligne, "Date de follow up")))
            if paye > 0:
                con.execute("INSERT INTO paiements (transaction_id, date, montant, methode, notes) VALUES (?,?,?,?,?)",
                            (tid, contact or date.today().isoformat(), paye, col(ligne, "Méthode"), "importé"))
            # DU THIS MONTH = mensualité du plan : on reconstruit l'échéancier mensuel de sorte que
            # les versements déjà payés tombent dans les mois passés et le suivant dans le mois courant.
            mensualite = lire_montant(col(ligne, "DU THIS MONTH"))
            if mensualite and mensualite > 0 and rev > 0:
                deja = int((paye + 0.005) // mensualite)
                jour = date.fromisoformat(contact).day if contact else 1
                # même jour chaque mois (jour du premier contact), plafonné au 28 pour exister dans tous les mois
                debut = ajouter_mois(date.today().replace(day=min(jour, 28)), -deja)
                plans += 1
                creer_echeancier(con, tid, debut, mensualite=mensualite)
            n += 1
    con.commit()
    if plans:
        print(f"{plans} plan(s) de paiement mensuel reconstruit(s) à partir de DU THIS MONTH.")
    return n


def exporter(con, fichier):
    rows = con.execute(f"SELECT {', '.join(c for _, c in GABARIT)} FROM v_transactions ORDER BY date_transaction, id")
    with open(fichier, "w", newline="", encoding="utf-8-sig") as fh:
        w = csv.writer(fh)
        w.writerow([h for h, _ in GABARIT])
        n = 0
        for r in rows:
            w.writerow(["" if v is None else v for v in r])
            n += 1
    return n


# ----------------------------------------------------------------------
def demo(con):
    if con.execute("SELECT COUNT(*) FROM transactions").fetchone()[0]:
        sys.exit("La base contient déjà des transactions ; démo ignorée.")
    t = date.today()
    j = lambda n: (t + timedelta(days=n)).isoformat()
    a = ajouter_transaction(con, "Marie Tremblay", 12000, nom="Mandat site web", type_="Projet", statut="Signé",
                            premier_contact=j(-90), date_tx=j(-60), echeance=j(-30), methode="Virement", follow_up=j(2))
    con.execute("INSERT INTO paiements (transaction_id, date, montant, methode) VALUES (?,?,?,?)", (a, j(-40), 5000, "Virement"))
    b = ajouter_transaction(con, "Gagnon Construction", 8000, nom="Contrat rénovation", type_="Projet", statut="Signé",
                            premier_contact=j(-45), date_tx=j(-20), methode="Chèque")
    creer_echeancier(con, b, t - timedelta(days=20), versements=4)
    con.execute("INSERT INTO paiements (transaction_id, date, montant, methode) VALUES (?,?,?,?)", (b, j(-18), 2000, "Chèque"))
    ajouter_transaction(con, "Acme USA", 3000, nom="Consultation", type_="Service", statut="Signé", devise="USD",
                        date_tx=j(-5), echeance=j(25), methode="Wire")
    cid = client_id(con, "Marie Tremblay")
    con.execute("INSERT INTO recurrences (client_id, description, type, rev, frequence, date_debut, prochaine_date, methode) "
                "VALUES (?, 'Entretien mensuel', 'Récurrent', 500, 'mensuel', ?, ?, 'Interac')",
                (cid, ajouter_mois(t, -2).isoformat(), ajouter_mois(t, -2).isoformat()))
    generer_recurrences(con)
    con.execute("INSERT INTO suivis (client_id, type, sujet, date_prevue, recurrence_jours) VALUES "
                "(?, 'appel', 'Appel de courtoisie', date('now'), 90)", (cid,))
    con.commit()
    creer_relances(con)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--db", default=str(DB_DEFAUT))
    sp = p.add_subparsers(dest="cmd", required=True)
    for c in ["init", "demo", "transactions", "clients", "du", "recevables", "mensuel", "recurrent",
              "suivis", "versements", "previsions", "generer", "relances"]:
        sp.add_parser(c)

    s = sp.add_parser("ajouter", help="nouvelle transaction (ou récurrence)")
    s.add_argument("client"); s.add_argument("rev", type=float)
    s.add_argument("--nom"); s.add_argument("--type"); s.add_argument("--statut", default="en cours")
    s.add_argument("--devise", default="CAD"); s.add_argument("--methode"); s.add_argument("--notes")
    s.add_argument("--date", help="date de la transaction (défaut : aujourd'hui)")
    s.add_argument("--echeance", help="date où le paiement est dû")
    s.add_argument("--premier-contact"); s.add_argument("--follow-up")
    s.add_argument("--taux", type=float, default=0.05, help="taux de commission (défaut 0.05)")
    s.add_argument("--commission", type=float, help="montant de commission fixe (remplace taux × REV)")
    s.add_argument("--versements", type=int, help="plan de paiement : N versements mensuels")
    s.add_argument("--mensualite", type=float, help="plan de paiement : versements de ce montant")
    s.add_argument("--premier-versement", help="date du 1er versement (défaut : --echeance ou --date)")
    s.add_argument("--frequence", default="mensuel", help="fréquence des versements (défaut mensuel)")
    s.add_argument("--recurrent", choices=["hebdomadaire", "aux2semaines", "mensuel", "trimestriel", "semestriel", "annuel"],
                   help="crée une récurrence : une transaction par période")
    s.add_argument("--fin", help="date de fin de la récurrence")
    s.add_argument("--delai", type=int, default=0, help="jours accordés pour payer (récurrence)")

    s = sp.add_parser("payer"); s.add_argument("transaction_id", type=int); s.add_argument("montant", type=float)
    s.add_argument("--methode"); s.add_argument("--ref"); s.add_argument("--date")

    s = sp.add_parser("suivi"); s.add_argument("client"); s.add_argument("sujet")
    s.add_argument("--date", required=True); s.add_argument("--transaction", type=int)
    s.add_argument("--type", default="follow_up"); s.add_argument("--priorite", default="normale")
    s.add_argument("--tous-les", type=int, help="répéter tous les N jours")

    s = sp.add_parser("fait"); s.add_argument("suivi_id", type=int); s.add_argument("--resultat")
    s = sp.add_parser("plan", help="détail du plan de paiement d'une transaction")
    s.add_argument("transaction_id", type=int)
    s = sp.add_parser("echeancier", help="(re)crée le plan de paiement d'une transaction existante")
    s.add_argument("transaction_id", type=int); s.add_argument("--debut", required=True)
    s.add_argument("--versements", type=int); s.add_argument("--mensualite", type=float)
    s.add_argument("--frequence", default="mensuel")
    s = sp.add_parser("import"); s.add_argument("fichier")
    s = sp.add_parser("export"); s.add_argument("fichier")
    a = p.parse_args()

    con = connecter(a.db)
    c = a.cmd
    if c == "init":
        print(f"Base prête : {a.db}")
    elif c == "demo":
        demo(con); print("Données d'exemple ajoutées.")
    elif c == "transactions":
        afficher(con, "SELECT id, transaction_, client, statut, devise, rev, mensualite, versements_restants AS restants, "
                      "montant_paye, difference_rev_paye, du_ce_mois, montant_commission, commission_collectee, etat, prochain_follow_up "
                      "FROM v_transactions ORDER BY date_transaction, id")
    elif c == "clients":
        afficher(con, "SELECT client, devise, nb_transactions, ventes_rev, total_paye, solde_du, du_ce_mois, en_retard, "
                      "commissions, commissions_collectees, prochain_follow_up FROM v_clients ORDER BY solde_du DESC")
    elif c == "du":
        afficher(con, "SELECT * FROM v_du_ce_mois")
        for r in con.execute("SELECT devise, ROUND(SUM(du_ce_mois),2) t FROM v_du_ce_mois GROUP BY devise"):
            print(f"Total dû ce mois : {r['t']:,.2f} {r['devise']}".replace(",", " "))
    elif c == "recevables":
        afficher(con, "SELECT * FROM v_recevables")
    elif c == "mensuel":
        afficher(con, "SELECT * FROM v_mensuel")
    elif c == "recurrent":
        afficher(con, "SELECT client, devise, nb, rev_mensuel, commission_mensuelle, prochaine_date FROM v_recurrent")
    elif c == "suivis":
        afficher(con, "SELECT * FROM v_suivis")
    elif c == "versements":
        afficher(con, "SELECT transaction_id AS tx, client, transaction_, versement, date, devise, montant, paye, reste, etat "
                      "FROM v_echeances WHERE etat IN ('En retard','Ce mois') ORDER BY date, client")
    elif c == "previsions":
        afficher(con, "SELECT * FROM v_previsions")
    elif c == "plan":
        afficher(con, "SELECT versement, date, devise, montant, paye, reste, etat FROM v_echeances "
                      "WHERE transaction_id=? ORDER BY date", (a.transaction_id,))
    elif c == "echeancier":
        if not (a.versements or a.mensualite):
            sys.exit("Indique --versements N ou --mensualite MONTANT.")
        n = creer_echeancier(con, a.transaction_id, date.fromisoformat(a.debut), a.versements, a.mensualite, a.frequence)
        con.commit(); print(f"Plan de paiement : {n} versement(s).")
    elif c == "generer":
        print(f"{generer_recurrences(con)} transaction(s) récurrente(s) créée(s).")
    elif c == "relances":
        print(f"{creer_relances(con)} relance(s) créée(s).")
    elif c == "ajouter":
        if a.recurrent:
            debut = a.date or date.today().isoformat()
            rid = con.execute(
                "INSERT INTO recurrences (client_id, description, type, rev, devise, taux_commission, methode, frequence, "
                "delai_paiement_jours, date_debut, date_fin, prochaine_date) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                (client_id(con, a.client), a.nom or a.client, a.type, a.rev, a.devise.upper(), a.taux, a.methode,
                 a.recurrent, a.delai, debut, a.fin, debut)).lastrowid
            con.commit()
            print(f"Récurrence #{rid} créée ; {generer_recurrences(con)} transaction(s) générée(s).")
        else:
            tid = ajouter_transaction(con, a.client, a.rev, a.nom, a.type, a.statut, a.devise, a.methode, a.date,
                                      a.echeance, a.premier_contact, a.taux, a.commission, a.notes, follow_up=a.follow_up)
            if a.versements or a.mensualite:
                debut = date.fromisoformat(a.premier_versement or a.echeance or a.date or date.today().isoformat())
                n = creer_echeancier(con, tid, debut, a.versements, a.mensualite, a.frequence)
                print(f"Plan de paiement : {n} versement(s) {a.frequence}(s) à partir du {debut}.")
            con.commit()
            print(f"Transaction #{tid} créée.")
    elif c == "payer":
        tx = con.execute("SELECT difference_rev_paye, devise FROM v_transactions WHERE id=?", (a.transaction_id,)).fetchone()
        if not tx:
            sys.exit("Transaction introuvable.")
        con.execute("INSERT INTO paiements (transaction_id, date, montant, methode, reference) VALUES (?,?,?,?,?)",
                    (a.transaction_id, a.date or date.today().isoformat(), a.montant, a.methode, a.ref))
        con.commit()
        reste = round(tx["difference_rev_paye"] - a.montant, 2)
        print(f"Paiement enregistré. Reste à payer : {reste:.2f} {tx['devise']}"
              + ("  (attention : paiement supérieur au solde)" if reste < 0 else ""))
    elif c == "suivi":
        con.execute("INSERT INTO suivis (client_id, transaction_id, type, sujet, date_prevue, priorite, recurrence_jours) "
                    "VALUES (?,?,?,?,?,?,?)", (client_id(con, a.client), a.transaction, a.type, a.sujet,
                                               a.date, a.priorite, a.tous_les))
        con.commit(); print("Suivi ajouté.")
    elif c == "fait":
        con.execute("UPDATE suivis SET statut='fait', date_realisee=date('now'), resultat=? WHERE id=?",
                    (a.resultat, a.suivi_id))
        con.commit(); print("Suivi marqué fait.")
    elif c == "import":
        print(f"{importer(con, a.fichier)} transaction(s) importée(s).")
    elif c == "export":
        print(f"{exporter(con, a.fichier)} transaction(s) exportée(s) vers {a.fichier}.")


if __name__ == "__main__":
    main()
