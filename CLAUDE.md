# app.idf.immo — consignes pour les sessions automatisées

Socle central et back-office de l'écosystème **IDF.immo** de Marie-Céline Etave.
Gère les **prescripteurs** de tous les réseaux, leurs **opportunités**, et les
**primes** qui en découlent.

## ⚠️ RÈGLE ABSOLUE — LES TROIS SITES PUBLICS SONT GELÉS

`gardiens.idf.immo`, `etudiants.idf.immo` et `associations.idf.immo` sont des
**façades protégées**. Leur contenu, leurs textes, leur structure, leur design,
leur SEO et leur parcours sont validés et **ne doivent pas être modifiés**.

**Le socle s'adapte aux sites. Jamais l'inverse.** Devant le choix entre
« modifier un site pour faciliter l'intégration » et « adapter le socle pour
préserver le site », c'est toujours la seconde option.

La seule exception accordée à ce jour, explicitement, le 15 août 2026 :
**ajouter** un bouton d'accès vers les nouvelles pages (« Partager une
opportunité », « Mon espace ») sur les trois sites. Strictement additif : rien
de supprimé, rien de reformulé, rien de déplacé, aucun style touché.

Toute autre modification exige une demande distincte et explicite de
Marie-Céline.

### Procédure de non-régression, obligatoire

Avant toute intervention touchant un dépôt protégé :

```
git -C <dépôt> ls-files -s | sort > empreinte-avant
```

Après : rejouer la commande et comparer. Puis vérifier que le diff ne contient
**aucune ligne supprimée** :

```
git diff -U0 | grep -c '^-[^-]'    # doit valoir 0
```

Au moindre écart inattendu : arrêt, retour en arrière, et on prévient.

## Le vocabulaire — règle absolue

Le mot **« signalement » ne doit apparaître nulle part** : ni dans les
interfaces, ni dans les noms de tables, de colonnes, de statuts ou de
variables. Partout : **opportunité**.

Statuts, repris de gardiens.idf.immo pour que rien ne diverge entre ce que voit
le prescripteur et ce que voit Marie-Céline : Reçue, Qualifiée, Contact en
cours, Projet immobilier, Vente réalisée, Prime versée — et les fins sans
prime, toujours accompagnées d'un motif.

## Architecture

```
idf.immo                    libre — futur site institutionnel
├── app.idf.immo            CE DÉPÔT — back-office, Marie-Céline seule
├── gardiens.idf.immo       GELÉ · en ligne
├── etudiants.idf.immo      GELÉ · en ligne
├── associations.idf.immo   GELÉ · en ligne
├── nounous.idf.immo        GELÉ · en ligne depuis le 21 août
└── pros.idf.immo           GELÉ · en ligne depuis le 21 août
```

Hors famille `idf.immo`, et hors socle : `antony.immo`, `paris7e.immo` et
`cse.immo` s'adressent à des clients, pas à des prescripteurs. Ne pas les
brancher sans demande explicite.

- **Un seul projet Supabase**, celui qui servait déjà les gardiens. Pas de
  seconde base : une migration est précisément le moment où un site protégé
  casse.
- **Un seul système de prescripteurs.** Jamais une table par réseau : la table
  `prescripteurs` porte une colonne `categorie`
  (`gardien`, `etudiant`, `association`, `nounou`, `autre`).
- **Ajouter un réseau = ajouter une ligne** dans `reseaux`, jamais du code.
- Site statique, HTML/CSS/JS écrits à la main, GitHub Pages. Aucune
  compilation, aucune dépendance à installer — comme les trois autres sites.

## La vue de compatibilité — à ne jamais casser

`mon-espace.html` de gardiens.idf.immo lit une table `gardiens` avec neuf
colonnes précises et y insère sa fiche au premier passage. Après migration,
`gardiens` est une **vue** sur `prescripteurs`, avec `security_invoker = true`
et deux déclencheurs `instead of` pour l'insertion et la modification.

**Toute évolution de `prescripteurs` doit préserver ces neuf colonnes** :
`id, prenom, nom, email, telephone, residence, commune, iban, cree_le`.

De même, `primes.montant_euros` doit **rester un entier** : le site l'affiche
avec `toLocaleString` et écrirait « 1000.00 » si la colonne devenait `numeric`.
Les rémunérations en pourcentage rangent leur centime exact dans
`montant_exact`, à côté.

## Une vue par réseau — à ne jamais casser

Chaque site de la famille lit une table portant **son propre nom** :
`gardiens.idf.immo` lit `gardiens`, `nounous.idf.immo` lit `nounous`. Ces noms
sont des **vues** sur `prescripteurs`, filtrées par catégorie, avec
`security_invoker = true` et deux déclencheurs `instead of`.

**Quand un nouveau réseau ouvre, il faut lui créer sa vue** (bloc 4 de
`base/correctif-1.sql`) — sinon son espace personnel est cassé dès le premier
jour. C'est ce qui est arrivé à nounous.idf.immo, mis en ligne avant que sa vue
n'existe. La vue de `pros.idf.immo` est créée par `base/correctif-2.sql` ; ses
colonnes diffèrent des autres — un commerçant a une **enseigne** et un
**métier** là où un gardien a sa résidence.

⚠️ **`nounous.idf.immo` ne pointe pas sur ce projet.** Son `base/config.js`
désigne `bhyshzolavkgcdtdfrkj.supabase.co`, une seconde base créée le 20 août :
les fiches et les opportunités des nounous n'arrivent donc pas dans ce
back-office, et la vue `nounous` du socle ne reçoit rien. À rapatrier (changer
son `config.js`, puis migrer le peu de données déjà saisies) avant d'ouvrir le
réseau pour de bon.

Les neuf colonnes attendues par les sites :
`id, prenom, nom, email, telephone, residence, commune, iban, cree_le`.

## Une fiche peut exister avant le compte

Un prescripteur qui téléphone, ou qui remplit le formulaire sans ouvrir son
espace, doit pouvoir être enregistré. La fiche est donc créée par le conseiller
avec une clé libre, et `fiche_de_ce_compte()` la **rattache automatiquement** au
compte le jour où la personne se connecte — avec ses opportunités et ses primes,
qui suivent par `on update cascade`.

Ce rattachement est appelé depuis les déclencheurs des vues : **les sites gelés
en profitent sans qu'une ligne de leur code ne change.**

## Les règles de rémunération ne sont jamais codées en dur

Elles vivent dans `regles_remuneration`, une ligne par règle, avec déclencheur,
mode (forfait ou pourcentage), montant ou taux, assiette et période de
validité. Paramétrage initial :

| Réseau | Déclencheur | Calcul |
|---|---|---|
| Gardiens | Acte authentique | 1 000 € nets, sans plafond de nombre |
| Étudiants | Mandat exclusif, diagnostics réalisés | 50 € |
| Étudiants | Acte authentique | 800 € |
| Associations | Acte authentique (vente ou recherche) | 10 % des honoraires **nets** |
| Associations | Expertise en valeur vénale réglée | 10 % des honoraires nets, **sans vente** |

**Les honoraires « nets » sont les honoraires HT réellement perçus**, après TVA
et après la quote-part du réseau mandant (BSK). Jamais le brut facturé au
client : l'écart est d'environ un quart, et l'erreur a déjà été commise une
fois sur associations.idf.immo. La convention de partenariat dit la même chose
à son article 5.2 : **le site, la convention et le socle doivent toujours
concorder.**

Ces montants restent **soumis à validation juridique**. En particulier,
l'article de la convention d'indicateur d'affaires fondant le caractère
occasionnel sur un plafond de 3 ventes par an doit être réécrit, ce plafond
ayant été supprimé côté gardiens.

## Structure du dépôt

- `base/socle.sql` — la migration initiale. **Rejouable**, testée sur une copie
  complète de la base avant livraison.
- `base/correctif-1.sql` — le correctif nº 1 : saisie par le conseiller, fiche
  avant compte, vue `nounous`, ouverture du réseau nounous.
- `base/installer.html` — page de copie du script, pour installer depuis un
  iPad sans avoir à sélectionner 400 lignes au doigt.
- `base/config.js` — URL du projet et clé publiable. Aucun secret : la
  protection est dans la base (RLS), pas dans la page.

## Tester le SQL avant de le livrer

PostgreSQL 16 est installé dans l'environnement. **Toute modification de
`socle.sql` doit être exécutée pour de vrai avant d'être poussée** : on monte
un serveur local, on rejoue le schéma de production de gardiens, on insère des
données réalistes, puis on applique la migration deux fois et on rejoue les
requêtes exactes du site. C'est ce test qui a trouvé, la première fois, que
`rapprocher()` et `purger_expirees()` étaient appelables par n'importe quel
prescripteur.

> Piège PostgreSQL à retenir : `create function` accorde l'exécution à
> **PUBLIC**. Révoquer le droit à `anon` et `authenticated` ne sert à rien tant
> que PUBLIC l'a encore. Toujours `revoke ... from public` d'abord.

## Sécurité

- Rien n'est lisible par défaut : « Automatically expose new tables » est
  décoché côté Supabase. Deux verrous successifs — les `grant` disent quelles
  **tables** sont joignables, les politiques RLS disent quelles **lignes**.
- Un prescripteur ne voit que ses propres opportunités et ses propres primes.
  Ce n'est pas l'application qui le garantit, c'est la base.
- Les vues portent `security_invoker = true`. Sans cette option, une vue
  contourne la sécurité par ligne — l'erreur classique.
- `rapprocher()` et `purger_expirees()` restent hors de portée des
  prescripteurs : la première révèle des identités, la seconde efface.

## ⚠️ Préalable au lancement

L'**expéditeur d'e-mails (Brevo)** n'est toujours pas installé sur le projet
Supabase. Sans lui, aucun lien de connexion ne part : ni pour les prescripteurs,
ni pour Marie-Céline sur app.idf.immo. À rappeler dès qu'il est question de
diffusion, d'affiche, de QR code ou de lancement.

## Divers

- Tout en français. Commits clairs en français.
- Le proxy réseau bloque le fetch HTTP direct (curl/WebFetch) vers l'extérieur :
  utiliser WebSearch uniquement ; un échec curl ne signifie PAS que le site est
  en panne.
- Push : `git push -u origin <branche>` ; en cas d'erreur réseau, retenter
  jusqu'à 4 fois (2, 4, 8, 16 s).
- Ne jamais contacter qui que ce soit ; ne jamais mettre de données
  personnelles dans le dépôt, qui est public.
