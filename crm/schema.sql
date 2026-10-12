-- =====================================================================
--  Suivi des paiements et commissions
--  Structure calquée sur le gabarit « Suivi paiements (commissions) » :
--  Transaction, Date de follow up, Date du premier contact, Type, Client,
--  Statut, REV, MONTANT PAYÉ, Différence REV - payé, MONTANT DE LA COMMISSION,
--  DU THIS MONTH, Commission 5% REV, Commission 5% REV collecté, Notes,
--  Devise, Méthode, État
--
--  Les colonnes calculées du gabarit (Différence, DU THIS MONTH,
--  Commission 5 %, Commission collectée, État) ne sont PAS saisies :
--  elles sont produites par les vues ci-dessous.
--  Moteur : SQLite 3
-- =====================================================================
PRAGMA foreign_keys = ON;

-- ---------------------------------------------------------------------
-- CLIENTS
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS clients (
    id              INTEGER PRIMARY KEY,
    nom             TEXT    NOT NULL UNIQUE COLLATE NOCASE,
    entreprise      TEXT,
    courriel        TEXT,
    telephone       TEXT,
    statut          TEXT    NOT NULL DEFAULT 'actif'
                    CHECK (statut IN ('prospect','actif','inactif','perdu')),
    source          TEXT,
    devise          TEXT    NOT NULL DEFAULT 'CAD',
    notes           TEXT,
    date_creation   TEXT    NOT NULL DEFAULT (date('now'))
);

-- ---------------------------------------------------------------------
-- RÉCURRENCES : un mandat récurrent génère une transaction par période
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS recurrences (
    id                  INTEGER PRIMARY KEY,
    client_id           INTEGER NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
    description         TEXT    NOT NULL,
    type                TEXT,
    rev                 REAL    NOT NULL CHECK (rev >= 0),
    devise              TEXT    NOT NULL DEFAULT 'CAD',
    taux_commission     REAL    NOT NULL DEFAULT 0.05,
    methode             TEXT,
    frequence           TEXT    NOT NULL DEFAULT 'mensuel'
                        CHECK (frequence IN ('hebdomadaire','aux2semaines','mensuel','trimestriel','semestriel','annuel')),
    delai_paiement_jours INTEGER NOT NULL DEFAULT 0,
    date_debut          TEXT    NOT NULL,
    date_fin            TEXT,
    prochaine_date      TEXT    NOT NULL,
    actif               INTEGER NOT NULL DEFAULT 1 CHECK (actif IN (0,1))
);
CREATE INDEX IF NOT EXISTS idx_rec_prochaine ON recurrences(actif, prochaine_date);

-- ---------------------------------------------------------------------
-- TRANSACTIONS (une ligne du gabarit)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS transactions (
    id                  INTEGER PRIMARY KEY,
    nom                 TEXT    NOT NULL,                 -- colonne « Transaction »
    client_id           INTEGER NOT NULL REFERENCES clients(id),
    recurrence_id       INTEGER REFERENCES recurrences(id) ON DELETE SET NULL,
    type                TEXT,                             -- « Type »
    statut              TEXT    NOT NULL DEFAULT 'en cours', -- « Statut » (étape de la vente)
    date_premier_contact TEXT,                            -- « Date du premier contact »
    date_transaction    TEXT    NOT NULL DEFAULT (date('now')),
    date_echeance       TEXT,                             -- date où le paiement est dû
    rev                 REAL    NOT NULL DEFAULT 0 CHECK (rev >= 0),  -- « REV »
    taux_commission     REAL    NOT NULL DEFAULT 0.05,    -- 5 % par défaut
    commission_manuelle REAL,                             -- « MONTANT DE LA COMMISSION » si différent de taux × REV
    devise              TEXT    NOT NULL DEFAULT 'CAD',   -- « Devise »
    methode             TEXT,                             -- « Méthode » prévue
    annulee             INTEGER NOT NULL DEFAULT 0 CHECK (annulee IN (0,1)),
    notes               TEXT                              -- « Notes »
);
CREATE INDEX IF NOT EXISTS idx_tx_client   ON transactions(client_id);
CREATE INDEX IF NOT EXISTS idx_tx_echeance ON transactions(date_echeance);

-- Échéancier optionnel : pour un paiement en plusieurs versements.
-- Sans échéancier, la transaction est due en entier à sa date d'échéance.
CREATE TABLE IF NOT EXISTS echeances (
    id              INTEGER PRIMARY KEY,
    transaction_id  INTEGER NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
    date            TEXT    NOT NULL,
    montant         REAL    NOT NULL CHECK (montant > 0)
);
CREATE INDEX IF NOT EXISTS idx_ech_tx ON echeances(transaction_id, date);

-- ---------------------------------------------------------------------
-- PAIEMENTS reçus (« MONTANT PAYÉ » = somme des paiements)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS paiements (
    id              INTEGER PRIMARY KEY,
    transaction_id  INTEGER NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
    date            TEXT    NOT NULL DEFAULT (date('now')),
    montant         REAL    NOT NULL CHECK (montant > 0),
    methode         TEXT,
    reference       TEXT,
    notes           TEXT
);
CREATE INDEX IF NOT EXISTS idx_paie_tx   ON paiements(transaction_id);
CREATE INDEX IF NOT EXISTS idx_paie_date ON paiements(date);

-- ---------------------------------------------------------------------
-- SUIVIS (« Date de follow up » et historique des relances)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS suivis (
    id              INTEGER PRIMARY KEY,
    client_id       INTEGER NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
    transaction_id  INTEGER REFERENCES transactions(id) ON DELETE SET NULL,
    type            TEXT    NOT NULL DEFAULT 'follow_up'
                    CHECK (type IN ('follow_up','appel','courriel','rencontre','relance_paiement','renouvellement','tache')),
    sujet           TEXT    NOT NULL,
    date_prevue     TEXT,
    date_realisee   TEXT,
    statut          TEXT    NOT NULL DEFAULT 'a_faire'
                    CHECK (statut IN ('a_faire','fait','annule')),
    priorite        TEXT    NOT NULL DEFAULT 'normale'
                    CHECK (priorite IN ('basse','normale','haute')),
    resultat        TEXT,
    recurrence_jours INTEGER CHECK (recurrence_jours IS NULL OR recurrence_jours > 0)
);
CREATE INDEX IF NOT EXISTS idx_suivis_todo ON suivis(statut, date_prevue);

-- Un suivi récurrent marqué « fait » se recrée automatiquement.
CREATE TRIGGER IF NOT EXISTS trg_suivi_recurrent
AFTER UPDATE OF statut ON suivis
WHEN NEW.statut = 'fait' AND OLD.statut <> 'fait' AND NEW.recurrence_jours IS NOT NULL
BEGIN
    INSERT INTO suivis (client_id, transaction_id, type, sujet, date_prevue, priorite, recurrence_jours)
    VALUES (NEW.client_id, NEW.transaction_id, NEW.type, NEW.sujet,
            date(COALESCE(NEW.date_realisee, date('now')), '+' || NEW.recurrence_jours || ' days'),
            NEW.priorite, NEW.recurrence_jours);
END;

-- =====================================================================
--  VUES
-- =====================================================================

-- Une ligne par transaction, avec toutes les colonnes calculées du gabarit
DROP VIEW IF EXISTS v_transactions;
CREATE VIEW v_transactions AS
WITH payes AS (
    SELECT transaction_id, ROUND(SUM(montant),2) AS paye, MAX(date) AS dernier_paiement
    FROM paiements GROUP BY transaction_id
), ech_cumul AS (
    SELECT e.transaction_id, e.date, e.montant,
           SUM(e.montant) OVER (PARTITION BY e.transaction_id ORDER BY e.date, e.id) AS cumul,
           COALESCE(p.paye, 0) AS paye
    FROM echeances e LEFT JOIN payes p ON p.transaction_id = e.transaction_id
), ech AS (   -- montant prévu jusqu'à la fin du mois courant, et plus vieille échéance non couverte
    SELECT transaction_id,
           SUM(CASE WHEN date(date) <= date('now','start of month','+1 month','-1 day') THEN montant ELSE 0 END) AS prevu_fin_mois,
           SUM(CASE WHEN date(date) <  date('now') THEN montant ELSE 0 END) AS prevu_echu,
           MIN(CASE WHEN cumul > paye + 0.005 THEN date END) AS echeance_impayee
    FROM ech_cumul GROUP BY transaction_id
), suiv AS (
    SELECT transaction_id, MIN(date_prevue) AS prochain_follow_up
    FROM suivis WHERE statut = 'a_faire' AND transaction_id IS NOT NULL GROUP BY transaction_id
), base AS (
    SELECT t.*, c.nom AS client,
           COALESCE(p.paye,0.0) AS paye, p.dernier_paiement,
           ROUND(t.rev - COALESCE(p.paye,0), 2) AS difference,
           -- Montant prévu d'ici la fin du mois : échéancier s'il existe, sinon tout le REV à la date d'échéance
           CASE WHEN e.transaction_id IS NOT NULL THEN e.prevu_fin_mois
                WHEN date(COALESCE(t.date_echeance, t.date_transaction)) <= date('now','start of month','+1 month','-1 day') THEN t.rev
                ELSE 0 END AS prevu_fin_mois,
           CASE WHEN e.transaction_id IS NOT NULL THEN e.prevu_echu
                WHEN date(COALESCE(t.date_echeance, t.date_transaction)) < date('now') THEN t.rev
                ELSE 0 END AS prevu_echu,
           -- date due du plus vieux montant non payé
           CASE WHEN e.transaction_id IS NOT NULL THEN e.echeance_impayee
                ELSE COALESCE(t.date_echeance, t.date_transaction) END AS prochaine_echeance,
           s.prochain_follow_up
    FROM transactions t
    JOIN clients c ON c.id = t.client_id
    LEFT JOIN payes p ON p.transaction_id = t.id
    LEFT JOIN ech   e ON e.transaction_id = t.id
    LEFT JOIN suiv  s ON s.transaction_id = t.id
)
SELECT id, nom AS transaction_, client_id, client, type, statut,
       date_premier_contact, date_transaction, date_echeance, prochaine_echeance, prochain_follow_up,
       devise, methode, rev,
       paye                                              AS montant_paye,
       difference                                        AS difference_rev_paye,
       ROUND(COALESCE(commission_manuelle, rev * taux_commission), 2) AS montant_commission,
       CASE WHEN annulee = 1 THEN 0
            ELSE ROUND(MAX(0, prevu_fin_mois - paye), 2) END AS du_ce_mois,
       CASE WHEN annulee = 1 THEN 0
            ELSE ROUND(MAX(0, prevu_echu - paye), 2) END     AS en_retard,
       CASE WHEN annulee = 0 AND prevu_echu - paye > 0.005
            THEN CAST(julianday('now') - julianday(prochaine_echeance) AS INTEGER) ELSE 0 END AS jours_retard,
       taux_commission,
       ROUND(rev * taux_commission, 2)                   AS commission_rev,
       ROUND(paye * taux_commission, 2)                  AS commission_collectee,
       ROUND(COALESCE(commission_manuelle, rev * taux_commission) - paye * taux_commission, 2) AS commission_a_recevoir,
       CASE WHEN annulee = 1                               THEN 'Annulée'
            WHEN rev > 0 AND paye >= rev - 0.005           THEN 'Payé'
            WHEN prevu_echu - paye > 0.005                 THEN 'En retard'
            WHEN paye > 0                                  THEN 'Partiel'
            ELSE 'À recevoir' END                          AS etat,
       dernier_paiement, notes, annulee
FROM base;

-- Résumé par client et par devise (on n'additionne jamais CAD et USD ensemble)
DROP VIEW IF EXISTS v_clients;
CREATE VIEW v_clients AS
SELECT client_id, client, devise,
       COUNT(*)                                  AS nb_transactions,
       ROUND(SUM(rev),2)                         AS ventes_rev,
       ROUND(SUM(montant_paye),2)                AS total_paye,
       ROUND(SUM(difference_rev_paye),2)         AS solde_du,
       ROUND(SUM(du_ce_mois),2)                  AS du_ce_mois,
       ROUND(SUM(en_retard),2)                   AS en_retard,
       ROUND(SUM(montant_commission),2)          AS commissions,
       ROUND(SUM(commission_collectee),2)        AS commissions_collectees,
       MIN(date_premier_contact)                 AS premier_contact,
       MAX(date_transaction)                     AS derniere_transaction,
       (SELECT MIN(date_prevue) FROM suivis s WHERE s.client_id = v.client_id AND s.statut='a_faire') AS prochain_follow_up
FROM v_transactions v
WHERE annulee = 0
GROUP BY client_id, devise;

-- Ce qui est dû ce mois-ci (inclut les retards)
DROP VIEW IF EXISTS v_du_ce_mois;
CREATE VIEW v_du_ce_mois AS
SELECT id, transaction_, client, devise, prochaine_echeance, du_ce_mois, en_retard, etat, methode, prochain_follow_up
FROM v_transactions
WHERE du_ce_mois > 0.005
ORDER BY en_retard DESC, prochaine_echeance;

-- Ancienneté des sommes en retard (selon la plus vieille échéance impayée)
DROP VIEW IF EXISTS v_recevables;
CREATE VIEW v_recevables AS
SELECT client, devise,
       ROUND(SUM(difference_rev_paye - en_retard),2)                                  AS a_venir,
       ROUND(SUM(CASE WHEN jours_retard BETWEEN 0 AND 30  THEN en_retard ELSE 0 END),2) AS j_1_30,
       ROUND(SUM(CASE WHEN jours_retard BETWEEN 31 AND 60 THEN en_retard ELSE 0 END),2) AS j_31_60,
       ROUND(SUM(CASE WHEN jours_retard BETWEEN 61 AND 90 THEN en_retard ELSE 0 END),2) AS j_61_90,
       ROUND(SUM(CASE WHEN jours_retard > 90              THEN en_retard ELSE 0 END),2) AS j_90_plus,
       ROUND(SUM(difference_rev_paye),2)                                              AS total_du
FROM v_transactions
WHERE annulee = 0 AND difference_rev_paye > 0.005
GROUP BY client, devise ORDER BY total_du DESC;

-- Par mois : ventes (REV) signées et argent / commissions réellement encaissés
DROP VIEW IF EXISTS v_mensuel;
CREATE VIEW v_mensuel AS
WITH ventes AS (
    SELECT strftime('%Y-%m', date_transaction) AS mois, devise,
           COUNT(*) AS nb, SUM(rev) AS rev, SUM(COALESCE(commission_manuelle, rev*taux_commission)) AS comm
    FROM transactions WHERE annulee = 0 GROUP BY 1, 2
), encaisse AS (
    SELECT strftime('%Y-%m', p.date) AS mois, t.devise,
           SUM(p.montant) AS paye, SUM(p.montant * t.taux_commission) AS comm_coll
    FROM paiements p JOIN transactions t ON t.id = p.transaction_id GROUP BY 1, 2
), cles AS (SELECT mois, devise FROM ventes UNION SELECT mois, devise FROM encaisse)
SELECT k.mois, k.devise,
       COALESCE(v.nb,0)                    AS nb_transactions,
       ROUND(COALESCE(v.rev,0),2)          AS rev,
       ROUND(COALESCE(v.comm,0),2)         AS commissions_generees,
       ROUND(COALESCE(e.paye,0),2)         AS encaisse,
       ROUND(COALESCE(e.comm_coll,0),2)    AS commissions_collectees
FROM cles k
LEFT JOIN ventes   v ON v.mois = k.mois AND v.devise = k.devise
LEFT JOIN encaisse e ON e.mois = k.mois AND e.devise = k.devise
ORDER BY k.mois, k.devise;

-- Revenu récurrent mensuel normalisé
DROP VIEW IF EXISTS v_recurrent;
CREATE VIEW v_recurrent AS
SELECT r.client_id, c.nom AS client, r.devise, COUNT(*) AS nb,
       ROUND(SUM(r.rev * CASE r.frequence
            WHEN 'hebdomadaire' THEN 52/12.0 WHEN 'aux2semaines' THEN 26/12.0
            WHEN 'mensuel' THEN 1 WHEN 'trimestriel' THEN 1/3.0
            WHEN 'semestriel' THEN 1/6.0 WHEN 'annuel' THEN 1/12.0 END), 2) AS rev_mensuel,
       ROUND(SUM(r.rev * r.taux_commission * CASE r.frequence
            WHEN 'hebdomadaire' THEN 52/12.0 WHEN 'aux2semaines' THEN 26/12.0
            WHEN 'mensuel' THEN 1 WHEN 'trimestriel' THEN 1/3.0
            WHEN 'semestriel' THEN 1/6.0 WHEN 'annuel' THEN 1/12.0 END), 2) AS commission_mensuelle,
       MIN(r.prochaine_date) AS prochaine_date
FROM recurrences r JOIN clients c ON c.id = r.client_id
WHERE r.actif = 1
GROUP BY r.client_id, r.devise;

-- Suivis à faire
DROP VIEW IF EXISTS v_suivis;
CREATE VIEW v_suivis AS
SELECT s.id, s.date_prevue, s.priorite, s.type, c.nom AS client, t.nom AS transaction_, s.sujet,
       CASE WHEN date(s.date_prevue) <  date('now') THEN 'en retard'
            WHEN date(s.date_prevue) =  date('now') THEN 'aujourd''hui'
            WHEN date(s.date_prevue) <= date('now','+7 days') THEN 'cette semaine'
            ELSE 'plus tard' END AS quand
FROM suivis s JOIN clients c ON c.id = s.client_id
LEFT JOIN transactions t ON t.id = s.transaction_id
WHERE s.statut = 'a_faire'
ORDER BY s.date_prevue IS NULL, date(s.date_prevue),
         CASE s.priorite WHEN 'haute' THEN 0 WHEN 'normale' THEN 1 ELSE 2 END;
