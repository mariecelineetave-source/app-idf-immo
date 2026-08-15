# app.idf.immo

Socle central et back-office de l'écosystème **IDF.immo** de Marie-Céline Etave.

Un seul système de prescripteurs, une seule base, un seul tableau de bord —
alimenté par les réseaux `gardiens`, `etudiants`, `associations`, et demain
`nounous`.

---

## ⚠️ Les trois sites publics sont gelés

`gardiens.idf.immo`, `etudiants.idf.immo` et `associations.idf.immo` ne doivent
pas être modifiés. **Le socle s'adapte aux sites, jamais l'inverse.**

C'est le principe qui a dicté toute l'architecture : la table `gardiens` que lit
`mon-espace.html` devient une **vue** portant exactement le même nom et les
mêmes colonnes. Le site continue de demander `gardiens` et de recevoir
`gardiens`. Il ne peut pas s'apercevoir du changement, parce qu'il n'y en a pas
pour lui.

---

## Où en est le projet

| | État |
|---|---|
| Audit des trois sites existants | ✅ fait |
| Architecture et modèle de données | ✅ validés |
| Migration de la base (`base/socle.sql`) | ✅ écrite et testée, **reste à exécuter** |
| Domaine `app.idf.immo` | ⬜ à créer chez Gandi |
| Back-office (les 10 rubriques) | ⬜ à construire |
| Pages « Partager » et « Mon espace » — étudiants, associations | ⬜ à construire |
| Expéditeur d'e-mails (Brevo) | ⬜ **bloquant avant tout lancement** |

---

## Installer le socle

Ouvrir **`base/installer.html`** dans un navigateur, cliquer sur le gros bouton,
puis suivre les sept étapes affichées. Le script se colle dans le SQL Editor du
projet Supabase existant — celui qui sert déjà les gardiens.

Le script est **rejouable** : l'exécuter deux fois ne casse rien.

---

## Ce que la migration installe

**Un seul système de prescripteurs.** La table `prescripteurs` porte une colonne
`categorie` : `gardien`, `etudiant`, `association`, `nounou`, `autre`. Il n'y a
pas — et il n'y aura jamais — une table par réseau. Ajouter un réseau, c'est
ajouter une ligne dans `reseaux`.

| Table | Rôle |
|---|---|
| `reseaux` | Un enregistrement par site source |
| `prescripteurs` | Identité, coordonnées, catégorie, réseau d'origine |
| `conseillers` | Qui réalise la vente — la prime reste due au prescripteur |
| `opportunites` | L'information partagée, avec sa source figée à la création |
| `estimations` | Dont l'expertise en valeur vénale, qui se rémunère sans vente |
| `mandats` | Type, exclusivité, diagnostics — déclenche les 50 € étudiants |
| `ventes` | Compromis, acte, prix, honoraires bruts **et nets** |
| `regles_remuneration` | Une ligne par règle. **Rien n'est codé en dur** |
| `primes` | Montant calculé, rattaché à la règle qui l'a produite |
| `evenements` | Journal lisible par le prescripteur |
| `notes_internes` | Notes privées, jamais visibles d'un prescripteur |

`biens` et `prospects` sont des **vues** dérivées des opportunités, et non des
tables : les recopier obligerait à modifier les sites protégés, ou à maintenir
deux vérités.

---

## Ce qui a été vérifié avant livraison

Le script a été **exécuté pour de vrai** sur une copie complète de la base de
production, montée localement sous PostgreSQL 16 :

- migration appliquée **deux fois de suite**, sans erreur ;
- les quatre requêtes exactes de `mon-espace.html` rejouées après migration :
  fiche, opportunités, primes et journal reviennent à l'identique, mêmes
  colonnes, mêmes types ;
- première connexion d'un nouveau gardien : insertion dans la vue, catégorie et
  réseau remplis automatiquement ;
- isolement : un gardien voit **zéro** opportunité et **zéro** prime d'un autre,
  et ne peut pas partager en son nom ;
- trois réseaux dans un même tableau de bord, chacun avec sa source.

Ce test a révélé une **faille présente dans la base actuelle** : `rapprocher()`
— qui révèle l'identité des prescripteurs — et `purger_expirees()` — qui
**efface** des opportunités — étaient appelables par n'importe quel gardien
connecté. La migration les referme.

> Le piège : `create function` accorde l'exécution à **PUBLIC**. Révoquer le
> droit à `anon` et `authenticated` ne sert à rien tant que PUBLIC l'a encore.

---

## Sécurité

Rien n'est lisible par défaut. Deux verrous successifs : les `grant` disent
quelles **tables** sont joignables par l'API, les politiques RLS disent quelles
**lignes** le sont. Un prescripteur ne voit que ce qui le concerne — ce n'est
pas l'application qui le garantit, c'est la base.

Les clés présentes dans `base/config.js` sont **publiques par conception** : la
clé secrète n'a sa place ni ici, ni dans aucun fichier de ce dépôt.
