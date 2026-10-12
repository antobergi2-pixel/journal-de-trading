-- =====================================================================
--  Base de données clients : ventes, comptes à recevoir, récurrences, suivis
--  Moteur : SQLite 3 (aucune installation serveur requise)
-- =====================================================================
PRAGMA foreign_keys = ON;

-- ---------------------------------------------------------------------
-- CLIENTS
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS clients (
    id                      INTEGER PRIMARY KEY,
    nom                     TEXT    NOT NULL,
    entreprise              TEXT,
    courriel                TEXT,
    telephone               TEXT,
    adresse                 TEXT,
    ville                   TEXT,
    province                TEXT    DEFAULT 'QC',
    code_postal             TEXT,
    statut                  TEXT    NOT NULL DEFAULT 'actif'
                            CHECK (statut IN ('prospect','actif','inactif','perdu')),
    source                  TEXT,                       -- référence, site web, réseau...
    etiquettes              TEXT,                       -- ex. "VIP,mensuel"
    conditions_paiement_jours INTEGER NOT NULL DEFAULT 30, -- Net 30 par défaut
    limite_credit           REAL,
    notes                   TEXT,
    date_creation           TEXT    NOT NULL DEFAULT (date('now')),
    date_maj                TEXT    NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_clients_statut ON clients(statut);
CREATE INDEX IF NOT EXISTS idx_clients_nom    ON clients(nom);

-- Personnes-ressources (plusieurs par client)
CREATE TABLE IF NOT EXISTS contacts (
    id          INTEGER PRIMARY KEY,
    client_id   INTEGER NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
    nom         TEXT    NOT NULL,
    role        TEXT,
    courriel    TEXT,
    telephone   TEXT,
    principal   INTEGER NOT NULL DEFAULT 0 CHECK (principal IN (0,1))
);
CREATE INDEX IF NOT EXISTS idx_contacts_client ON contacts(client_id);

-- ---------------------------------------------------------------------
-- CATALOGUE
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS produits (
    id              INTEGER PRIMARY KEY,
    nom             TEXT    NOT NULL UNIQUE,
    description     TEXT,
    prix_unitaire   REAL    NOT NULL DEFAULT 0,
    taxable         INTEGER NOT NULL DEFAULT 1 CHECK (taxable IN (0,1)),
    actif           INTEGER NOT NULL DEFAULT 1 CHECK (actif IN (0,1))
);

-- ---------------------------------------------------------------------
-- RÉCURRENCES (abonnements / mandats récurrents)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS abonnements (
    id                      INTEGER PRIMARY KEY,
    client_id               INTEGER NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
    produit_id              INTEGER REFERENCES produits(id),
    description             TEXT    NOT NULL,
    montant                 REAL    NOT NULL,           -- avant taxes, par période
    quantite                REAL    NOT NULL DEFAULT 1,
    taxable                 INTEGER NOT NULL DEFAULT 1 CHECK (taxable IN (0,1)),
    frequence               TEXT    NOT NULL DEFAULT 'mensuel'
                            CHECK (frequence IN ('hebdomadaire','aux2semaines','mensuel','trimestriel','semestriel','annuel')),
    date_debut              TEXT    NOT NULL,
    date_fin                TEXT,                       -- NULL = sans fin
    prochaine_facturation   TEXT    NOT NULL,
    statut                  TEXT    NOT NULL DEFAULT 'actif'
                            CHECK (statut IN ('actif','pause','annule','termine')),
    notes                   TEXT
);
CREATE INDEX IF NOT EXISTS idx_abo_client    ON abonnements(client_id);
CREATE INDEX IF NOT EXISTS idx_abo_prochaine ON abonnements(statut, prochaine_facturation);

-- ---------------------------------------------------------------------
-- FACTURES (ventes)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS factures (
    id              INTEGER PRIMARY KEY,
    numero          TEXT    NOT NULL UNIQUE,
    client_id       INTEGER NOT NULL REFERENCES clients(id),
    abonnement_id   INTEGER REFERENCES abonnements(id) ON DELETE SET NULL,
    date_emission   TEXT    NOT NULL DEFAULT (date('now')),
    date_echeance   TEXT    NOT NULL,
    statut          TEXT    NOT NULL DEFAULT 'envoyee'
                    CHECK (statut IN ('brouillon','envoyee','annulee')),
                    -- payée / partielle / en retard sont CALCULÉS (voir v_factures)
    notes           TEXT
);
CREATE INDEX IF NOT EXISTS idx_factures_client   ON factures(client_id);
CREATE INDEX IF NOT EXISTS idx_factures_echeance ON factures(date_echeance);
CREATE INDEX IF NOT EXISTS idx_factures_emission ON factures(date_emission);

CREATE TABLE IF NOT EXISTS lignes_facture (
    id              INTEGER PRIMARY KEY,
    facture_id      INTEGER NOT NULL REFERENCES factures(id) ON DELETE CASCADE,
    produit_id      INTEGER REFERENCES produits(id),
    description     TEXT    NOT NULL,
    quantite        REAL    NOT NULL DEFAULT 1,
    prix_unitaire   REAL    NOT NULL,
    remise_pct      REAL    NOT NULL DEFAULT 0 CHECK (remise_pct BETWEEN 0 AND 100),
    taux_tps        REAL    NOT NULL DEFAULT 0.05,      -- TPS fédérale
    taux_tvq        REAL    NOT NULL DEFAULT 0.09975    -- TVQ Québec
);
CREATE INDEX IF NOT EXISTS idx_lignes_facture ON lignes_facture(facture_id);

-- ---------------------------------------------------------------------
-- PAIEMENTS (un paiement peut couvrir plusieurs factures, et une
-- facture peut être payée en plusieurs versements)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS paiements (
    id          INTEGER PRIMARY KEY,
    client_id   INTEGER NOT NULL REFERENCES clients(id),
    date        TEXT    NOT NULL DEFAULT (date('now')),
    montant     REAL    NOT NULL CHECK (montant > 0),
    methode     TEXT    CHECK (methode IN ('virement','interac','cheque','comptant','carte','paypal','stripe','autre')),
    reference   TEXT,
    notes       TEXT
);
CREATE INDEX IF NOT EXISTS idx_paiements_client ON paiements(client_id);

CREATE TABLE IF NOT EXISTS allocations_paiement (
    paiement_id INTEGER NOT NULL REFERENCES paiements(id) ON DELETE CASCADE,
    facture_id  INTEGER NOT NULL REFERENCES factures(id)  ON DELETE CASCADE,
    montant     REAL    NOT NULL CHECK (montant > 0),
    PRIMARY KEY (paiement_id, facture_id)
);
CREATE INDEX IF NOT EXISTS idx_alloc_facture ON allocations_paiement(facture_id);

-- ---------------------------------------------------------------------
-- SUIVIS (tracker : relances, appels, rendez-vous, tâches)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS suivis (
    id              INTEGER PRIMARY KEY,
    client_id       INTEGER NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
    facture_id      INTEGER REFERENCES factures(id) ON DELETE SET NULL,
    type            TEXT    NOT NULL DEFAULT 'tache'
                    CHECK (type IN ('appel','courriel','rencontre','relance_paiement','renouvellement','tache','note')),
    sujet           TEXT    NOT NULL,
    date_prevue     TEXT,
    date_realisee   TEXT,
    statut          TEXT    NOT NULL DEFAULT 'a_faire'
                    CHECK (statut IN ('a_faire','en_cours','fait','annule')),
    priorite        TEXT    NOT NULL DEFAULT 'normale'
                    CHECK (priorite IN ('basse','normale','haute')),
    resultat        TEXT,
    -- Suivi récurrent (ex. appel de courtoisie tous les 90 jours)
    recurrence_jours INTEGER CHECK (recurrence_jours IS NULL OR recurrence_jours > 0),
    date_creation   TEXT    NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_suivis_client ON suivis(client_id);
CREATE INDEX IF NOT EXISTS idx_suivis_todo   ON suivis(statut, date_prevue);

-- Quand un suivi récurrent est marqué « fait », on crée automatiquement le prochain.
CREATE TRIGGER IF NOT EXISTS trg_suivi_recurrent
AFTER UPDATE OF statut ON suivis
WHEN NEW.statut = 'fait' AND OLD.statut <> 'fait' AND NEW.recurrence_jours IS NOT NULL
BEGIN
    INSERT INTO suivis (client_id, type, sujet, date_prevue, priorite, recurrence_jours)
    VALUES (NEW.client_id, NEW.type, NEW.sujet,
            date(COALESCE(NEW.date_realisee, date('now')), '+' || NEW.recurrence_jours || ' days'),
            NEW.priorite, NEW.recurrence_jours);
END;

CREATE TRIGGER IF NOT EXISTS trg_clients_maj
AFTER UPDATE ON clients
BEGIN
    UPDATE clients SET date_maj = datetime('now') WHERE id = NEW.id;
END;

-- Empêche d'allouer plus que le montant du paiement.
CREATE TRIGGER IF NOT EXISTS trg_alloc_max
BEFORE INSERT ON allocations_paiement
WHEN (SELECT COALESCE(SUM(montant),0) FROM allocations_paiement WHERE paiement_id = NEW.paiement_id)
     + NEW.montant > (SELECT montant FROM paiements WHERE id = NEW.paiement_id) + 0.005
BEGIN
    SELECT RAISE(ABORT, 'Allocation supérieure au montant du paiement');
END;

-- =====================================================================
--  VUES DE CALCUL
-- =====================================================================

-- Totaux par facture, avec taxes, montant payé, solde et statut calculé
DROP VIEW IF EXISTS v_factures;
CREATE VIEW v_factures AS
WITH lignes AS (
    SELECT facture_id,
           ROUND(SUM(quantite * prix_unitaire * (1 - remise_pct/100.0)), 2)            AS sous_total,
           ROUND(SUM(quantite * prix_unitaire * (1 - remise_pct/100.0) * taux_tps), 2) AS tps,
           ROUND(SUM(quantite * prix_unitaire * (1 - remise_pct/100.0) * taux_tvq), 2) AS tvq
    FROM lignes_facture GROUP BY facture_id
), payes AS (
    SELECT facture_id, ROUND(SUM(montant), 2) AS paye FROM allocations_paiement GROUP BY facture_id
)
SELECT f.id, f.numero, f.client_id, c.nom AS client, f.abonnement_id,
       f.date_emission, f.date_echeance, f.statut AS statut_saisi,
       COALESCE(l.sous_total, 0)                                   AS sous_total,
       COALESCE(l.tps, 0)                                          AS tps,
       COALESCE(l.tvq, 0)                                          AS tvq,
       ROUND(COALESCE(l.sous_total,0)+COALESCE(l.tps,0)+COALESCE(l.tvq,0), 2) AS total,
       COALESCE(p.paye, 0)                                         AS paye,
       CASE WHEN f.statut IN ('annulee','brouillon') THEN 0
            ELSE ROUND(COALESCE(l.sous_total,0)+COALESCE(l.tps,0)+COALESCE(l.tvq,0) - COALESCE(p.paye,0), 2)
       END                                                         AS solde,
       CASE WHEN f.statut IN ('annulee','brouillon') THEN 0
            ELSE MAX(0, CAST(julianday('now') - julianday(f.date_echeance) AS INTEGER))
       END                                                         AS jours_retard,
       CASE
            WHEN f.statut = 'annulee'   THEN 'annulee'
            WHEN f.statut = 'brouillon' THEN 'brouillon'
            WHEN COALESCE(p.paye,0) >= ROUND(COALESCE(l.sous_total,0)+COALESCE(l.tps,0)+COALESCE(l.tvq,0), 2) - 0.005 THEN 'payee'
            WHEN date(f.date_echeance) < date('now') THEN 'en_retard'
            WHEN COALESCE(p.paye,0) > 0 THEN 'partielle'
            ELSE 'ouverte'
       END                                                         AS statut
FROM factures f
JOIN clients c ON c.id = f.client_id
LEFT JOIN lignes l ON l.facture_id = f.id
LEFT JOIN payes  p ON p.facture_id = f.id;

-- Ventes et soldes par client (le tableau de bord principal)
DROP VIEW IF EXISTS v_clients_resume;
CREATE VIEW v_clients_resume AS
SELECT c.id, c.nom, c.entreprise, c.statut,
       COUNT(f.id)                                                     AS nb_factures,
       ROUND(COALESCE(SUM(CASE WHEN f.statut NOT IN ('annulee','brouillon') THEN f.sous_total END),0),2) AS ventes_avant_taxes,
       ROUND(COALESCE(SUM(CASE WHEN f.statut NOT IN ('annulee','brouillon') THEN f.total END),0),2)      AS ventes_ttc,
       ROUND(COALESCE(SUM(f.paye),0),2)                                AS total_paye,
       ROUND(COALESCE(SUM(f.solde),0),2)                               AS solde_du,
       ROUND(COALESCE(SUM(CASE WHEN f.statut = 'en_retard' THEN f.solde END),0),2) AS solde_en_retard,
       MAX(f.date_emission)                                            AS derniere_facture,
       (SELECT ROUND(COALESCE(SUM(montant),0),2) FROM paiements p WHERE p.client_id = c.id)
         - (SELECT ROUND(COALESCE(SUM(a.montant),0),2) FROM allocations_paiement a
              JOIN paiements p ON p.id = a.paiement_id WHERE p.client_id = c.id) AS credit_non_applique,
       (SELECT MIN(date_prevue) FROM suivis s WHERE s.client_id = c.id AND s.statut IN ('a_faire','en_cours')) AS prochain_suivi
FROM clients c
LEFT JOIN v_factures f ON f.client_id = c.id
GROUP BY c.id;

-- Vieillissement des comptes à recevoir (aging) par client
DROP VIEW IF EXISTS v_comptes_recevables;
CREATE VIEW v_comptes_recevables AS
SELECT client_id, client,
       ROUND(SUM(CASE WHEN jours_retard = 0               THEN solde ELSE 0 END),2) AS courant,
       ROUND(SUM(CASE WHEN jours_retard BETWEEN 1  AND 30 THEN solde ELSE 0 END),2) AS j_1_30,
       ROUND(SUM(CASE WHEN jours_retard BETWEEN 31 AND 60 THEN solde ELSE 0 END),2) AS j_31_60,
       ROUND(SUM(CASE WHEN jours_retard BETWEEN 61 AND 90 THEN solde ELSE 0 END),2) AS j_61_90,
       ROUND(SUM(CASE WHEN jours_retard > 90              THEN solde ELSE 0 END),2) AS j_90_plus,
       ROUND(SUM(solde),2) AS total_du
FROM v_factures
WHERE solde > 0.005
GROUP BY client_id
ORDER BY total_du DESC;

-- Ventes par mois (hors annulées / brouillons)
DROP VIEW IF EXISTS v_ventes_mensuelles;
CREATE VIEW v_ventes_mensuelles AS
SELECT strftime('%Y-%m', date_emission) AS mois,
       COUNT(*)                          AS nb_factures,
       ROUND(SUM(sous_total),2)          AS ventes_avant_taxes,
       ROUND(SUM(tps),2)                 AS tps_percue,
       ROUND(SUM(tvq),2)                 AS tvq_percue,
       ROUND(SUM(total),2)               AS ventes_ttc,
       ROUND(SUM(paye),2)                AS encaisse
FROM v_factures
WHERE statut NOT IN ('annulee','brouillon')
GROUP BY mois ORDER BY mois;

-- Revenu récurrent mensuel (MRR) normalisé par client
DROP VIEW IF EXISTS v_revenu_recurrent;
CREATE VIEW v_revenu_recurrent AS
SELECT a.client_id, c.nom AS client, COUNT(*) AS nb_abonnements,
       ROUND(SUM(a.montant * a.quantite *
           CASE a.frequence
               WHEN 'hebdomadaire' THEN 52/12.0
               WHEN 'aux2semaines' THEN 26/12.0
               WHEN 'mensuel'      THEN 1
               WHEN 'trimestriel'  THEN 1/3.0
               WHEN 'semestriel'   THEN 1/6.0
               WHEN 'annuel'       THEN 1/12.0
           END), 2) AS revenu_mensuel,
       MIN(a.prochaine_facturation) AS prochaine_facturation
FROM abonnements a JOIN clients c ON c.id = a.client_id
WHERE a.statut = 'actif'
GROUP BY a.client_id;

-- Abonnements à facturer aujourd'hui (ou en retard de facturation)
DROP VIEW IF EXISTS v_abonnements_a_facturer;
CREATE VIEW v_abonnements_a_facturer AS
SELECT a.*, c.nom AS client
FROM abonnements a JOIN clients c ON c.id = a.client_id
WHERE a.statut = 'actif'
  AND date(a.prochaine_facturation) <= date('now')
  AND (a.date_fin IS NULL OR date(a.prochaine_facturation) <= date(a.date_fin));

-- Liste de suivis à faire (en retard en premier)
DROP VIEW IF EXISTS v_suivis_a_faire;
CREATE VIEW v_suivis_a_faire AS
SELECT s.id, s.date_prevue, s.priorite, s.type, c.nom AS client, s.sujet, s.facture_id,
       CASE WHEN date(s.date_prevue) <  date('now') THEN 'en_retard'
            WHEN date(s.date_prevue) =  date('now') THEN 'aujourdhui'
            WHEN date(s.date_prevue) <= date('now','+7 days') THEN 'cette_semaine'
            ELSE 'plus_tard' END AS echeance
FROM suivis s JOIN clients c ON c.id = s.client_id
WHERE s.statut IN ('a_faire','en_cours')
ORDER BY CASE s.priorite WHEN 'haute' THEN 0 WHEN 'normale' THEN 1 ELSE 2 END,
         s.date_prevue IS NULL, s.date_prevue;
