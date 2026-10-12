#!/usr/bin/env python3
"""Outil en ligne de commande pour la base clients (SQLite, aucune dépendance).

Exemples :
    python crm.py init                      # crée crm.db
    python crm.py demo                      # ajoute des données d'exemple
    python crm.py clients                   # ventes et soldes par client
    python crm.py recevables                # comptes à recevoir par ancienneté
    python crm.py ventes                    # ventes par mois
    python crm.py recurrent                 # revenu récurrent mensuel
    python crm.py facturer                  # génère les factures des abonnements dus
    python crm.py relances                  # crée des suivis pour les factures en retard
    python crm.py suivis                    # liste des suivis à faire
    python crm.py payer CLIENT_ID MONTANT [--methode interac] [--ref X]
    python crm.py import-clients fichier.csv   # import d'un export Notion / Excel
"""
import argparse
import csv
import sqlite3
import sys
from datetime import date, timedelta
from pathlib import Path

ICI = Path(__file__).resolve().parent
SCHEMA = ICI / "schema.sql"
DB_DEFAUT = ICI / "crm.db"


def connecter(chemin):
    con = sqlite3.connect(chemin)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA foreign_keys = ON")
    return con


def init(con):
    con.executescript(SCHEMA.read_text(encoding="utf-8"))
    con.commit()


def afficher(con, sql, params=()):
    cur = con.execute(sql, params)
    lignes = cur.fetchall()
    cols = [d[0] for d in cur.description]
    if not lignes:
        print("(aucun résultat)")
        return
    fmt = lambda v: "" if v is None else (f"{v:,.2f}".replace(",", " ") if isinstance(v, float) else str(v))
    data = [[fmt(r[c]) for c in cols] for r in lignes]
    larg = [max(len(c), *(len(l[i]) for l in data)) for i, c in enumerate(cols)]
    print("  ".join(c.ljust(w) for c, w in zip(cols, larg)))
    print("  ".join("-" * w for w in larg))
    for l in data:
        print("  ".join(v.ljust(w) for v, w in zip(l, larg)))


# ----------------------------------------------------------------------
# Dates de récurrence
# ----------------------------------------------------------------------
def ajouter_mois(d, n):
    m = d.month - 1 + n
    a, m = d.year + m // 12, m % 12 + 1
    fins = [31, 29 if a % 4 == 0 and (a % 100 or a % 400 == 0) else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    return date(a, m, min(d.day, fins[m - 1]))


def periode_suivante(d, frequence):
    return {
        "hebdomadaire": lambda: d + timedelta(weeks=1),
        "aux2semaines": lambda: d + timedelta(weeks=2),
        "mensuel": lambda: ajouter_mois(d, 1),
        "trimestriel": lambda: ajouter_mois(d, 3),
        "semestriel": lambda: ajouter_mois(d, 6),
        "annuel": lambda: ajouter_mois(d, 12),
    }[frequence]()


def prochain_numero(con, jour):
    prefixe = f"F{jour.year}-"
    r = con.execute("SELECT numero FROM factures WHERE numero LIKE ? ORDER BY numero DESC LIMIT 1",
                    (prefixe + "%",)).fetchone()
    n = int(r["numero"].split("-")[1]) + 1 if r else 1
    return f"{prefixe}{n:04d}"


def creer_facture(con, client_id, lignes, jour=None, abonnement_id=None, notes=None):
    """lignes : liste de dicts {description, quantite, prix_unitaire, taxable, produit_id}"""
    jour = jour or date.today()
    termes = con.execute("SELECT conditions_paiement_jours FROM clients WHERE id=?", (client_id,)).fetchone()[0]
    cur = con.execute(
        "INSERT INTO factures (numero, client_id, abonnement_id, date_emission, date_echeance, notes) "
        "VALUES (?,?,?,?,?,?)",
        (prochain_numero(con, jour), client_id, abonnement_id, jour.isoformat(),
         (jour + timedelta(days=termes)).isoformat(), notes))
    fid = cur.lastrowid
    for l in lignes:
        tax = l.get("taxable", 1)
        con.execute(
            "INSERT INTO lignes_facture (facture_id, produit_id, description, quantite, prix_unitaire, taux_tps, taux_tvq) "
            "VALUES (?,?,?,?,?,?,?)",
            (fid, l.get("produit_id"), l["description"], l.get("quantite", 1), l["prix_unitaire"],
             0.05 if tax else 0, 0.09975 if tax else 0))
    return fid


def facturer_recurrents(con, jusqua=None):
    """Crée une facture par période due (rattrape les périodes manquées)."""
    jusqua = jusqua or date.today()
    crees = 0
    for a in con.execute("SELECT * FROM abonnements WHERE statut='actif'").fetchall():
        prochaine = date.fromisoformat(a["prochaine_facturation"])
        fin = date.fromisoformat(a["date_fin"]) if a["date_fin"] else None
        while prochaine <= jusqua and (fin is None or prochaine <= fin):
            creer_facture(con, a["client_id"], [{
                "description": f"{a['description']} ({a['frequence']}, période du {prochaine.isoformat()})",
                "quantite": a["quantite"], "prix_unitaire": a["montant"],
                "taxable": a["taxable"], "produit_id": a["produit_id"]}],
                jour=prochaine, abonnement_id=a["id"])
            crees += 1
            prochaine = periode_suivante(prochaine, a["frequence"])
        statut = "termine" if fin and prochaine > fin else a["statut"]
        con.execute("UPDATE abonnements SET prochaine_facturation=?, statut=? WHERE id=?",
                    (prochaine.isoformat(), statut, a["id"]))
    con.commit()
    return crees


def creer_relances(con):
    """Un suivi « relance_paiement » par facture en retard qui n'en a pas déjà un ouvert."""
    rows = con.execute("""
        SELECT f.id, f.client_id, f.numero, f.solde, f.jours_retard FROM v_factures f
        WHERE f.statut = 'en_retard'
          AND NOT EXISTS (SELECT 1 FROM suivis s WHERE s.facture_id = f.id
                          AND s.type='relance_paiement' AND s.statut IN ('a_faire','en_cours'))
    """).fetchall()
    for r in rows:
        prio = "haute" if r["jours_retard"] > 30 else "normale"
        con.execute("INSERT INTO suivis (client_id, facture_id, type, sujet, date_prevue, priorite) "
                    "VALUES (?,?,'relance_paiement',?,date('now'),?)",
                    (r["client_id"], r["id"],
                     f"Relancer facture {r['numero']} : {r['solde']:.2f} $ ({r['jours_retard']} j de retard)", prio))
    con.commit()
    return len(rows)


def enregistrer_paiement(con, client_id, montant, methode=None, reference=None, jour=None):
    """Enregistre un paiement et l'applique aux plus vieilles factures impayées (FIFO)."""
    pid = con.execute("INSERT INTO paiements (client_id, date, montant, methode, reference) VALUES (?,?,?,?,?)",
                      (client_id, (jour or date.today()).isoformat(), montant, methode, reference)).lastrowid
    reste = round(montant, 2)
    for f in con.execute("SELECT id, solde FROM v_factures WHERE client_id=? AND solde > 0.005 "
                         "ORDER BY date_echeance, id", (client_id,)).fetchall():
        if reste <= 0:
            break
        part = round(min(reste, f["solde"]), 2)
        con.execute("INSERT INTO allocations_paiement (paiement_id, facture_id, montant) VALUES (?,?,?)",
                    (pid, f["id"], part))
        reste = round(reste - part, 2)
    con.commit()
    return pid, reste


# ----------------------------------------------------------------------
# Import CSV (export Notion, Excel, Google Sheets...)
# ----------------------------------------------------------------------
ALIAS = {
    "nom": ["nom", "name", "client", "nom du client", "nom complet"],
    "entreprise": ["entreprise", "company", "compagnie", "société", "societe", "organisation"],
    "courriel": ["courriel", "email", "e-mail", "mail", "adresse courriel"],
    "telephone": ["telephone", "téléphone", "phone", "tel", "tél", "cellulaire"],
    "adresse": ["adresse", "address"],
    "ville": ["ville", "city"],
    "statut": ["statut", "status", "état", "etat"],
    "source": ["source", "provenance"],
    "etiquettes": ["etiquettes", "étiquettes", "tags", "catégorie", "categorie"],
    "notes": ["notes", "note", "commentaires", "description"],
}
STATUTS = {"prospect": "prospect", "lead": "prospect", "actif": "actif", "active": "actif",
           "client": "actif", "inactif": "inactif", "inactive": "inactif", "perdu": "perdu", "lost": "perdu"}


def importer_clients(con, fichier):
    with open(fichier, newline="", encoding="utf-8-sig") as fh:
        lecteur = csv.DictReader(fh)
        entetes = {h.strip().lower(): h for h in lecteur.fieldnames or []}
        carte = {champ: entetes[a] for champ, alias in ALIAS.items() for a in alias if a in entetes}
        if "nom" not in carte:
            sys.exit(f"Colonne du nom introuvable. Colonnes vues : {list(entetes.values())}")
        print("Correspondance des colonnes :", {k: v for k, v in carte.items()})
        n = 0
        for ligne in lecteur:
            val = {k: (ligne.get(v) or "").strip() or None for k, v in carte.items()}
            if not val["nom"]:
                continue
            val["statut"] = STATUTS.get((val.get("statut") or "actif").lower(), "actif")
            cols = list(val)
            con.execute(f"INSERT INTO clients ({','.join(cols)}) VALUES ({','.join('?' * len(cols))})",
                        [val[c] for c in cols])
            n += 1
    con.commit()
    return n


# ----------------------------------------------------------------------
def demo(con):
    if con.execute("SELECT COUNT(*) FROM clients").fetchone()[0]:
        sys.exit("La base contient déjà des clients ; démo ignorée.")
    t = date.today()
    c1 = con.execute("INSERT INTO clients (nom, entreprise, courriel, statut, conditions_paiement_jours) "
                     "VALUES ('Marie Tremblay','Boulangerie MT','marie@exemple.ca','actif',15)").lastrowid
    c2 = con.execute("INSERT INTO clients (nom, entreprise, courriel, statut) "
                     "VALUES ('Jean Gagnon','Gagnon Construction','jean@exemple.ca','actif')").lastrowid
    c3 = con.execute("INSERT INTO clients (nom, statut, source) VALUES ('Sophie Roy','prospect','Référence')").lastrowid
    con.execute("INSERT INTO produits (nom, prix_unitaire) VALUES ('Consultation (heure)', 95), ('Forfait gestion mensuel', 450)")
    con.execute("INSERT INTO abonnements (client_id, produit_id, description, montant, frequence, date_debut, prochaine_facturation) "
                "VALUES (?,2,'Forfait gestion mensuel',450,'mensuel',?,?)",
                (c1, ajouter_mois(t, -3).isoformat(), ajouter_mois(t, -3).isoformat()))
    creer_facture(con, c2, [{"description": "Consultation", "quantite": 10, "prix_unitaire": 95}], jour=t - timedelta(days=75))
    creer_facture(con, c2, [{"description": "Consultation", "quantite": 4, "prix_unitaire": 95}], jour=t - timedelta(days=10))
    facturer_recurrents(con)
    enregistrer_paiement(con, c1, 1000, "interac")
    enregistrer_paiement(con, c2, 500, "cheque", "CHQ-1042")
    con.execute("INSERT INTO suivis (client_id, type, sujet, date_prevue, recurrence_jours) "
                "VALUES (?, 'appel', 'Appel de courtoisie trimestriel', date('now'), 90)", (c1,))
    con.execute("INSERT INTO suivis (client_id, type, sujet, date_prevue, priorite) "
                "VALUES (?, 'rencontre', 'Présenter la soumission', date('now','+3 days'), 'haute')", (c3,))
    con.commit()
    creer_relances(con)


def main():
    p = argparse.ArgumentParser(description="Base clients : ventes, recevables, récurrences, suivis")
    p.add_argument("--db", default=str(DB_DEFAUT))
    sp = p.add_subparsers(dest="cmd", required=True)
    for c in ["init", "demo", "clients", "recevables", "ventes", "recurrent", "facturer", "relances", "suivis"]:
        sp.add_parser(c)
    pp = sp.add_parser("payer")
    pp.add_argument("client_id", type=int)
    pp.add_argument("montant", type=float)
    pp.add_argument("--methode")
    pp.add_argument("--ref")
    pi = sp.add_parser("import-clients")
    pi.add_argument("fichier")
    a = p.parse_args()

    con = connecter(a.db)
    init(con)  # idempotent : garde le schéma à jour
    if a.cmd == "init":
        print(f"Base prête : {a.db}")
    elif a.cmd == "demo":
        demo(con); print("Données d'exemple ajoutées.")
    elif a.cmd == "clients":
        afficher(con, "SELECT id, nom, statut, nb_factures, ventes_avant_taxes, ventes_ttc, total_paye, "
                      "solde_du, solde_en_retard, prochain_suivi FROM v_clients_resume ORDER BY solde_du DESC")
    elif a.cmd == "recevables":
        afficher(con, "SELECT * FROM v_comptes_recevables")
        r = con.execute("SELECT ROUND(COALESCE(SUM(total_du),0),2) FROM v_comptes_recevables").fetchone()[0]
        print(f"\nTotal à recevoir : {r:,.2f} $".replace(",", " "))
    elif a.cmd == "ventes":
        afficher(con, "SELECT * FROM v_ventes_mensuelles")
    elif a.cmd == "recurrent":
        afficher(con, "SELECT * FROM v_revenu_recurrent ORDER BY revenu_mensuel DESC")
    elif a.cmd == "facturer":
        print(f"{facturer_recurrents(con)} facture(s) récurrente(s) créée(s).")
    elif a.cmd == "relances":
        print(f"{creer_relances(con)} relance(s) créée(s).")
    elif a.cmd == "suivis":
        afficher(con, "SELECT * FROM v_suivis_a_faire")
    elif a.cmd == "payer":
        pid, reste = enregistrer_paiement(con, a.client_id, a.montant, a.methode, a.ref)
        print(f"Paiement #{pid} enregistré." + (f" Crédit non appliqué : {reste:.2f} $" if reste else ""))
    elif a.cmd == "import-clients":
        print(f"{importer_clients(con, a.fichier)} client(s) importé(s).")


if __name__ == "__main__":
    main()
