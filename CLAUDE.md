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

## Le site (outil principal)

L'utilisateur remplit lui-même ses données sur le site : https://claude.ai/artifact/4wvZNQfJnyVpusE1YakU1N
- Code source : `site/index.html`. Pour le modifier, éditer ce fichier et le republier avec l'outil Artifact en passant cette URL comme `url`.
- Les données vivent dans la base de l'artifact : collections `clients`, `ventes`, `paiements`, `suivis`. Elles se lisent et s'écrivent avec l'outil `ArtifactData` (même URL). La forme des documents est décrite en tête du script de `site/index.html`.
- Fiche client voulue par l'utilisateur : nom, statut, travail, horaires, pain, goals, courriel, téléphone, salaire annuel, argent de côté (montants en CAD, `null` si inconnus), notes, et ses **rendez-vous à venir**. Les RDV sont des `suivis` de type `rencontre`, avec `datePrevue` et `heure` (HH:MM, facultative).
- Les règles d'accès (lecture et écriture au niveau `admin`) rendent les données invisibles à toute personne qui n'est pas propriétaire ou éditeur, même si le lien est partagé.
- Les montants calculés (payé, différence, dû ce mois, commissions, État) ne sont jamais stockés : le site les calcule à partir des ventes, des plans et des paiements.
- La copie de sécurité se fait depuis l'onglet Sauvegarde du site (fichier .json téléchargé). L'outil en ligne de commande de `crm/` reste disponible, mais il a sa propre base, distincte de celle du site.

## Version Cloudflare

L'utilisateur veut héberger le site sur Cloudflare (il travaille seul). Tout est dans `cloudflare/` (voir son README) :
- `site/index.html` reste la source unique. `cloudflare/construire.sh` l'emballe avec `<meta name="hebergement" content="cloudflare">`, ce qui fait passer la page sur l'API `/api` (base D1) au lieu de la base claude.ai.
- **En ligne** : https://suivi-commissions.pages.dev (protégé par Cloudflare Access, équipe Zero Trust de l'utilisateur ; connexion par code envoyé à son courriel). Le jeton ne peut pas lister les comptes : il faut fournir CLOUDFLARE_ACCOUNT_ID (variable d'environnement, ou le demander à l'utilisateur ; ne pas le committer).
- Mise en ligne : `cloudflare/deployer.sh`, avec CLOUDFLARE_API_TOKEN et EMAIL_AUTORISE dans l'environnement (CLOUDFLARE_ACCOUNT_ID facultatif). Le réseau de l'environnement doit autoriser `api.cloudflare.com`.
- Ne jamais committer l'adresse courriel ni les identifiants Cloudflare : le dépôt est public. Le script les écrit seulement dans `cloudflare/.deploiement/`, qui est ignoré par Git.
- Après toute modification de `site/index.html` : republier l'artifact claude.ai ET relancer `deployer.sh`.
- Le site Cloudflare est aussi l'**application téléphone** de l'utilisateur (application web installable : `cloudflare/pwa/`, ajoutée à l'écran d'accueil). Si la page ou les fichiers mis en cache changent de façon importante, incrémenter `CACHE` dans `pwa/sw.js`.

## Factures Letmetalk (onglet Factures du site)

L'utilisateur est vendeur pour Letmetalk et se fait payer sur facture :
- **Une facture par mois**, sur les **montants collectés pendant le mois** (paiements reçus), vente par vente : client, date de close (`dateVente`), montant collecté, % de commission, commission. Les ventes annulées sont exclues.
- À envoyer à **payable@letmetalk.ai** au plus tard **5 jours après la fin du mois** ; paiement par dépôt direct **le 15 du mois suivant**.
- Facture adressée à : Letmetalk, 2 boul. Curé-Labelle, #300, Sainte-Thérèse, Canada.
- Collections : `factures` (id `lmt-AAAA-MM`, numéro `LMT-AAAA-MM`, lignes figées à la création, statut `a_envoyer` → `envoyee` → `payee`) et `parametres/facturation` (nom, adresse, courriel, téléphone, inscription TPS/TVQ et numéros, destinataire).
- Ne jamais enregistrer le NAS ni le spécimen de chèque dans le site : ils vont directement à Letmetalk.
- PDF généré dans la page (jsPDF 2.5.1 et jspdf-autotable 3.8.2, depuis cdnjs) ; le courriel est préparé à copier, car la page ne peut pas envoyer de courriel elle-même.
