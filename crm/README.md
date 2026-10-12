# Base de données clients

Suivi des **ventes**, des **montants dus** (comptes à recevoir), de la **facturation récurrente** et des **suivis clients**.
SQLite + Python 3, sans aucune dépendance à installer.

## Démarrage rapide

```bash
cd crm
python crm.py init          # crée crm.db
python crm.py demo          # (optionnel) données d'exemple
python crm.py clients       # ventes et solde dû par client
```

## Commandes

| Commande | Ce qu'elle fait |
|---|---|
| `clients` | Ventes (avant taxes / TTC), payé, **solde dû**, solde en retard, prochain suivi |
| `recevables` | Ancienneté des comptes à recevoir : courant, 1-30, 31-60, 61-90, 90+ jours |
| `ventes` | Ventes par mois, TPS/TVQ perçues, encaissé |
| `recurrent` | Revenu récurrent mensuel (MRR) par client |
| `facturer` | Génère les factures des abonnements arrivés à échéance (rattrape les périodes manquées) |
| `relances` | Crée un suivi « relance_paiement » pour chaque facture en retard |
| `suivis` | Liste des tâches à faire, triée par priorité et date |
| `payer CLIENT_ID MONTANT [--methode interac] [--ref X]` | Enregistre un paiement et l'applique aux plus vieilles factures |
| `import-clients fichier.csv` | Importe des clients depuis un export CSV (Notion, Excel, Sheets) |

Routine conseillée (quotidienne ou hebdomadaire) : `facturer` → `relances` → `suivis`.

## Structure

- **clients**, **contacts** : fiche client, statut (prospect/actif/inactif/perdu), conditions de paiement (Net 30 par défaut)
- **produits** : catalogue et prix
- **abonnements** : mandats récurrents (hebdo → annuel), prochaine date de facturation
- **factures** + **lignes_facture** : ventes, avec remise, TPS 5 % et TVQ 9,975 % par ligne
- **paiements** + **allocations_paiement** : un paiement peut couvrir plusieurs factures, et une facture peut être payée en plusieurs versements
- **suivis** : appels, courriels, rencontres, relances, renouvellements. Un suivi avec `recurrence_jours` se recrée automatiquement quand il est marqué `fait`

Les montants (total, payé, solde, jours de retard, statut payée/partielle/en retard) **ne sont jamais saisis à la main** : ils sont calculés par les vues `v_factures`, `v_clients_resume`, `v_comptes_recevables`, `v_ventes_mensuelles`, `v_revenu_recurrent`, `v_abonnements_a_facturer` et `v_suivis_a_faire`. Elles s'ouvrent dans n'importe quel outil SQLite (ex. DB Browser for SQLite).
