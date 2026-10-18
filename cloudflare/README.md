# Suivi des commissions sur Cloudflare

Le même site que sur claude.ai (`site/index.html`), hébergé sur Cloudflare :

- **Cloudflare Pages** sert la page et l'API (`functions/api/[[path]].js`).
- **D1** garde les données dans une table de documents JSON (`schema.sql`). C'est le même modèle que la base de claude.ai, donc une sauvegarde .json se restaure d'un site à l'autre.
- **Cloudflare Access** (Zero Trust, forfait gratuit) bloque le site et l'API pour tout le monde sauf ton adresse courriel. L'API vérifie elle-même le jeton Access : même si Access était mal configuré, elle ne répond à personne d'autre.

## Mise en ligne

Une seule fois, dans Cloudflare :
1. Crée un compte gratuit sur cloudflare.com.
2. Ouvre **Zero Trust** dans le tableau de bord, choisis un nom d'équipe et le forfait **Free**.
3. Crée un jeton API (**My Profile → API Tokens → Create Token → Custom token**) avec ces permissions sur ton compte :
   - D1 : Edit
   - Cloudflare Pages : Edit
   - Access: Apps and Policies : Edit
   - Access: Organizations, Identity Providers, and Groups : Read

Puis :
```bash
export CLOUDFLARE_API_TOKEN=...  EMAIL_AUTORISE=ton@courriel.com   # CLOUDFLARE_ACCOUNT_ID facultatif
./cloudflare/deployer.sh
```
Le script crée la base D1, le projet Pages et la protection Access, puis met le site en ligne. Tu peux le relancer à chaque modification du site : il réutilise ce qui existe et ne touche jamais aux données.

## Installer l'application sur le téléphone

Le site Cloudflare est une application web installable : icône sur l'écran d'accueil, ouverture en plein écran, démarrage rapide.

- **iPhone (Safari) :** ouvre l'adresse du site, connecte-toi avec le code reçu par courriel, puis touche **Partager → Sur l'écran d'accueil → Ajouter**.
- **Android (Chrome) :** ouvre l'adresse, connecte-toi, puis **⋮ → Installer l'application**.

Les fichiers de l'application sont dans `pwa/` : manifeste, service worker et icônes. Les icônes se régénèrent avec `python3 pwa/icones.py`. Le service worker garde la page en mémoire, mais jamais les données, qui viennent toujours de D1.

## Agenda Google

Dans l'application : **Agenda Google** (accueil ou onglet Suivis), puis colle l'**adresse secrète au format iCal** de ton agenda (calendar.google.com → ⚙ Paramètres → ton agenda → « Adresse secrète au format iCal »). Ta semaine Google s'affiche alors à l'accueil avec tes RDV clients. L'analyse de l'agenda est dans `functions/agenda.js`.

## Voir ses RDV dans Google Agenda

Dans l'application : **Agenda → Synchroniser → Créer mon adresse**, puis ajoute l'adresse dans Google Agenda (**Autres agendas → + → À partir de l'URL**) ou sur iPhone (**Réglages → Calendrier → Comptes → Ajouter un compte → Autre → Ajouter un calendrier avec abonnement**). Le flux est servi par `functions/flux/[jeton].js`, hors de Cloudflare Access, protégé par son jeton secret.

## Ne rien perdre

- **D1 Time Travel** garde automatiquement l'historique de la base. Tu peux la remettre dans l'état d'une minute précise des 30 derniers jours, ou des 7 derniers jours sur le forfait gratuit : `npx wrangler d1 time-travel restore suivi-commissions --timestamp=...`.
- Chaque semaine, télécharge aussi une sauvegarde .json depuis l'onglet **Sauvegarde** du site et range-la dans ton Drive. Le site te le rappelle.

## Passer de claude.ai à Cloudflare

Sur le site claude.ai : **Sauvegarde → Télécharger la sauvegarde**. Sur le site Cloudflare : **Sauvegarde → Restaurer**. Tout est transféré, rien à retaper.

## Tester sur sa machine

```bash
./cloudflare/construire.sh
cd cloudflare && echo 'DEV_LOCAL = "1"' > .dev.vars
npx wrangler d1 execute suivi-commissions --local --file schema.sql
npx wrangler pages dev        # http://localhost:8788
```
`DEV_LOCAL` ne lève la vérification Access que pour une adresse localhost.
