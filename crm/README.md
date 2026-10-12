# Suivi des paiements et commissions

Base de données construite sur le gabarit **« Suivi paiements (commissions) »** : elle calcule les ventes par client, ce que chaque client doit, ce qui est dû ce mois-ci, les commissions de 5 % (générées et collectées), et gère les récurrences et les follow-ups.

SQLite + Python 3, sans rien à installer.

## Démarrage

```bash
cd crm
python crm.py import mon_suivi.csv   # importe ton fichier (même format que le gabarit)
python crm.py clients                # ventes, payé, solde dû, commissions par client
```

Pour essayer avec des données fictives, lance `python crm.py --db essai.db demo`.

## Correspondance avec ton gabarit

| Colonne du gabarit | Dans la base |
|---|---|
| Transaction, Type, Client, Statut, Notes, Devise, Méthode | saisis (table `transactions`) |
| Date du premier contact | saisie |
| Date de follow up | table `suivis` : chaque follow-up est une tâche avec historique |
| REV | saisi |
| MONTANT PAYER | **calculé** = somme des paiements (table `paiements`) |
| Différence REV - payé | **calculé** |
| MONTANT DE LA COMMISSIONS | **calculé** = 5 % × REV, sauf si tu entres un montant fixe |
| DU THIS MONTH | **calculé** : montant prévu d'ici la fin du mois moins ce qui est payé (retards inclus) |
| Commission 5% REV | **calculé** |
| Commission 5% REV collecté | **calculé** = 5 % × montant payé |
| État | **calculé** : Payé / Partiel / En retard / À recevoir / Annulée |

Les colonnes calculées ne se saisissent jamais à la main, alors elles ne peuvent pas devenir fausses. `python crm.py export fichier.csv` recrée le tableau au format exact du gabarit pour Notion, Excel ou Google Sheets.

Les montants en CAD et en USD ne sont jamais additionnés ensemble : chaque résumé est séparé par devise.

## Commandes

**Consulter**

| Commande | Résultat |
|---|---|
| `transactions` | toutes les transactions avec les colonnes calculées |
| `clients` | ventes (REV), payé, solde dû, dû ce mois, en retard, commissions, prochain follow-up |
| `du` | ce qui est dû ce mois-ci, retards en premier, avec le total |
| `recevables` | soldes dus classés par ancienneté : à venir, 1-30, 31-60, 61-90, 90+ jours |
| `mensuel` | REV signé, argent encaissé et commissions collectées par mois |
| `recurrent` | revenu et commission récurrents par mois |
| `suivis` | follow-ups à faire, en retard en premier |

**Saisir**

```bash
python crm.py ajouter "Client X" 5000 --nom "Vente X" --type Nouveau --echeance 2026-11-15 --follow-up 2026-10-20
python crm.py ajouter "Client X" 9000 --versements 3 --echeance 2026-11-01   # payable en 3 versements mensuels
python crm.py ajouter "Client X" 500 --recurrent mensuel --nom "Abonnement"  # une transaction par mois
python crm.py ajouter "Client X" 2000 --commission 150                       # commission fixe au lieu de 5 %
python crm.py payer 12 2500 --methode Interac                                # paiement sur la transaction #12
python crm.py suivi "Client X" "Appel de suivi" --date 2026-10-20 --tous-les 30
python crm.py fait 7 --resultat "Paiement promis vendredi"
```

**Automatiser** (chaque jour ou chaque semaine) :

```bash
python crm.py generer    # crée les transactions des récurrences arrivées à échéance
python crm.py relances   # crée un follow-up « relance » pour chaque paiement en retard
python crm.py suivis     # ta liste de la journée
```

Un follow-up créé avec `--tous-les N` se recrée automatiquement N jours après avoir été marqué `fait`.

## Structure

- `clients` : un client par nom
- `transactions` : une ligne du gabarit, avec la date d'échéance et le taux de commission (5 % par défaut)
- `echeances` : échéancier optionnel quand une vente se paie en plusieurs versements
- `paiements` : chaque paiement reçu, avec date, méthode et référence (plusieurs par transaction)
- `recurrences` : mandats récurrents qui génèrent une transaction par période
- `suivis` : follow-ups, appels, relances, avec historique

Les vues `v_transactions`, `v_clients`, `v_du_ce_mois`, `v_recevables`, `v_mensuel`, `v_recurrent` et `v_suivis` s'ouvrent aussi dans n'importe quel outil SQLite, par exemple DB Browser for SQLite.

## À l'import

- Les montants comme `5 000,00 $` ou `$1,200.50` et les dates comme `October 20, 2026`, `12 août 2026` ou `2026/11/01` sont reconnus.
- **MONTANT PAYER** devient un paiement daté du premier contact. Ajoute ensuite les vrais paiements avec `payer`.
- **MONTANT DE LA COMMISSIONS** est gardé seulement s'il diffère de 5 % × REV.
- **État** est recalculé et non importé.
- Sans date d'échéance, une transaction est considérée due à sa date du premier contact. Ajuste avec `--echeance` pour les nouvelles.
