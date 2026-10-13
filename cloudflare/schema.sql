-- Base D1 du suivi des commissions.
-- Une table de documents JSON, même modèle que la base du site sur claude.ai :
-- une sauvegarde .json se restaure telle quelle d'un hébergement à l'autre.
CREATE TABLE IF NOT EXISTS docs (
  collection TEXT NOT NULL CHECK (collection IN ('clients', 'ventes', 'paiements', 'suivis', 'factures', 'parametres')),
  id         TEXT NOT NULL,
  data       TEXT NOT NULL CHECK (json_valid(data)),
  cree_le    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  maj_le     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  PRIMARY KEY (collection, id)
);
