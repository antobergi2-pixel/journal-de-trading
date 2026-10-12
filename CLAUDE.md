# Suivi des paiements et commissions

Ce dépôt contient la base de données de l'utilisateur pour suivre ses ventes, les plans de paiement de ses clients, ses commissions et ses follow-ups. Tout est dans `crm/` ; le mode d'emploi complet est dans `crm/README.md`.

L'utilisateur remplit la base au fur et à mesure **en conversation** : « j'ai signé une vente avec X », « X m'a payé 500 $ », « rappelle-moi d'appeler Y jeudi ». Le travail consiste à traduire ces messages en commandes `crm.py`, à montrer le résultat, puis à sauvegarder.

## Règles métier confirmées par l'utilisateur

- **Statut** = l'étape de la vente, saisie librement (ex. prospect, soumission, signé). **État** = l'état du paiement, toujours calculé ; ne jamais le saisir.
- Les ventes se paient par **plan de paiement mensuel**. DU THIS MONTH = versement du mois + versements en retard.
- La commission est **reçue par l'utilisateur**. Elle est de **5 % par défaut, modifiable vente par vente** (`--taux` ou la commande `taux`).
- Devise par défaut : CAD. On n'additionne jamais CAD et USD.
- Les colonnes calculées (payé, différence, dû ce mois, commissions, État) ne se saisissent jamais.

## Façon de travailler

1. Toujours passer par `python crm.py ...` depuis `crm/`, jamais par du SQL écrit à la main dans la base, sauf pour une correction qu'aucune commande ne couvre. Dans ce cas, lancer ensuite `python crm.py init`, qui réécrit `donnees.sql` à partir de la base.
2. S'il manque une information pour une vente (REV, mensualité ou nombre de versements, date du 1er versement, taux s'il n'est pas 5 %), la demander au lieu de l'inventer.
3. Après chaque saisie, montrer le résultat utile (`fiche "Client"`, `du`, `suivis`...).
4. **Sauvegarder** : `crm/donnees.sql` est la seule copie durable des données, car `crm.db` n'est pas versionné et l'environnement est effacé après la session. Committer `crm/donnees.sql` et pousser après chaque série de saisies.
5. **Confidentialité** : avant de pousser des données réelles, vérifier que le dépôt est **privé**. S'il est public, ne pas pousser `donnees.sql` : prévenir l'utilisateur et attendre qu'il rende le dépôt privé.

## Routine utile

En début de session, ou quand l'utilisateur demande « quoi faire aujourd'hui » : `generer`, puis `relances`, puis `suivis` et `du`.
