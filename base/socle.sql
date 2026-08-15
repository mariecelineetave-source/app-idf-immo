-- =====================================================================
-- app.idf.immo — le socle central de l'écosystème IDF.immo
--
-- À coller dans Supabase : projet → SQL Editor → New query → Run.
-- Le script est REJOUABLE : l'exécuter deux fois ne casse rien.
--
-- Il s'applique au projet Supabase qui sert déjà gardiens.idf.immo. Il ne
-- crée pas une seconde base : il généralise celle qui existe.
--
-- ⚠️  RÈGLE ABSOLUE RESPECTÉE ICI
--     gardiens.idf.immo, etudiants.idf.immo et associations.idf.immo sont
--     gelés. Aucune ligne de ces sites n'est modifiée par ce script.
--     La table « gardiens » que lit mon-espace.html devient une VUE portant
--     exactement le même nom et exactement les mêmes colonnes : le site
--     continue de demander « gardiens » et de recevoir « gardiens ».
--     Il ne peut pas s'apercevoir du changement, parce qu'il n'y en a pas
--     pour lui. C'est le socle qui s'adapte au site, jamais l'inverse.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1. Les catégories de prescripteurs
--    Un seul système, une colonne pour distinguer les réseaux. Ajouter un
--    réseau n'ajoutera jamais de table.
-- ---------------------------------------------------------------------
do $$ begin
  create type categorie_prescripteur as enum (
    'gardien', 'etudiant', 'association', 'nounou', 'autre'
  );
exception when duplicate_object then null; end $$;

-- Un état de plus : l'expertise en valeur vénale ouvre droit à une
-- rémunération côté associations, même sans vente.
do $$ begin
  alter type statut_opportunite add value if not exists 'expertise_remise';
exception when undefined_object then null; end $$;

-- ---------------------------------------------------------------------
-- 2. Les réseaux
--    Une ligne par site source. C'est ici, et nulle part dans le code,
--    qu'un futur réseau s'ajoute.
-- ---------------------------------------------------------------------
create table if not exists reseaux (
  id       uuid primary key default gen_random_uuid(),
  code     text unique not null,            -- gardiens, etudiants, associations, nounous
  nom      text not null,
  domaine  text not null,
  categorie categorie_prescripteur not null,
  actif    boolean not null default true,
  cree_le  timestamptz not null default now()
);

insert into reseaux (code, nom, domaine, categorie, actif) values
  ('gardiens',     'Gardiens IDF.immo',     'gardiens.idf.immo',     'gardien',     true),
  ('etudiants',    'Étudiants IDF.immo',    'etudiants.idf.immo',    'etudiant',    true),
  ('associations', 'Associations IDF.immo', 'associations.idf.immo', 'association', true),
  ('nounous',      'Nounous IDF.immo',      'nounous.idf.immo',      'nounou',      false)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- 3. La table des gardiens devient la table générique des prescripteurs
--
--    Renommage, puis vue de compatibilité. Les règles d'accès, les index,
--    les clés étrangères et les déclencheurs suivent automatiquement le
--    renommage : rien n'est perdu.
-- ---------------------------------------------------------------------
do $$ begin
  if exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
             where n.nspname = 'public' and c.relname = 'gardiens' and c.relkind = 'r') then
    alter table public.gardiens rename to prescripteurs;
  end if;
end $$;

-- Si la base est vierge (nouveau projet), on la crée directement générique.
create table if not exists prescripteurs (
  id          uuid primary key references auth.users(id) on delete cascade,
  prenom      text not null,
  nom         text,
  email       text not null,
  telephone   text,
  residence   text,
  commune     text,
  iban        text,
  cree_le     timestamptz not null default now()
);

alter table prescripteurs add column if not exists categorie categorie_prescripteur;
alter table prescripteurs add column if not exists reseau_id uuid references reseaux(id);
-- Propre aux associations : la structure, pas la personne qui la représente.
alter table prescripteurs add column if not exists organisation text;
alter table prescripteurs add column if not exists role_dans_organisation text;
alter table prescripteurs add column if not exists notes text;

-- Les fiches déjà présentes sont, par construction, des gardiens.
update prescripteurs set categorie = 'gardien' where categorie is null;
update prescripteurs p set reseau_id = r.id
  from reseaux r where r.code = 'gardiens' and p.reseau_id is null;

alter table prescripteurs alter column categorie set default 'gardien';
alter table prescripteurs alter column categorie set not null;

create index if not exists prescripteurs_categorie on prescripteurs (categorie, cree_le desc);
create index if not exists prescripteurs_reseau    on prescripteurs (reseau_id);

-- ---------------------------------------------------------------------
-- 4. LA VUE DE COMPATIBILITÉ — le cœur du dispositif
--
--    mon-espace.html de gardiens.idf.immo lit une table « gardiens » avec
--    neuf colonnes précises, et y insère sa fiche au premier passage.
--    Il continuera de le faire, sans qu'une ligne du site ne change.
--
--    security_invoker : la vue applique les règles d'accès du prescripteur
--    connecté, et non celles de son propriétaire. Sans cette option, une
--    vue contournerait la sécurité par ligne — l'erreur classique.
-- ---------------------------------------------------------------------
create or replace view gardiens with (security_invoker = true) as
  select id, prenom, nom, email, telephone, residence, commune, iban, cree_le
  from prescripteurs
  where categorie = 'gardien';

-- Une insertion dans la vue doit remplir la catégorie et le réseau, que le
-- site ne connaît pas et n'a pas à connaître.
create or replace function gardiens_insertion()
returns trigger language plpgsql as $$
declare r uuid;
begin
  select id into r from reseaux where code = 'gardiens';
  insert into prescripteurs (id, prenom, nom, email, telephone, residence,
                             commune, iban, categorie, reseau_id)
  values (new.id, new.prenom, new.nom, new.email, new.telephone,
          new.residence, new.commune, new.iban, 'gardien', r);
  return new;
end $$;

drop trigger if exists trg_gardiens_insertion on gardiens;
create trigger trg_gardiens_insertion instead of insert on gardiens
for each row execute function gardiens_insertion();

create or replace function gardiens_modification()
returns trigger language plpgsql as $$
begin
  update prescripteurs set
    prenom = new.prenom, nom = new.nom, email = new.email,
    telephone = new.telephone, residence = new.residence,
    commune = new.commune, iban = new.iban
  where id = old.id;
  return new;
end $$;

drop trigger if exists trg_gardiens_modification on gardiens;
create trigger trg_gardiens_modification instead of update on gardiens
for each row execute function gardiens_modification();

-- ---------------------------------------------------------------------
-- 5. Les conseillers qui réalisent la vente
--    Distincts du prescripteur : la prime reste due même si la vente est
--    conclue par un autre conseiller du réseau.
-- ---------------------------------------------------------------------
create table if not exists conseillers (
  id      uuid primary key default gen_random_uuid(),
  nom     text not null,
  email   text,
  reseau_mandant text,                       -- BSK, etc.
  actif   boolean not null default true,
  cree_le timestamptz not null default now()
);

insert into conseillers (nom, email)
select 'Marie-Céline Etave', 'contact@idf.immo'
where not exists (select 1 from conseillers where email = 'contact@idf.immo');

-- ---------------------------------------------------------------------
-- 6. Les opportunités deviennent multi-réseaux
--
--    La table garde son nom et toutes ses colonnes : mon-espace.html fait
--    un select("*") dessus et n'utilise aucune des colonnes renommées.
--    On ajoute l'origine, figée à la création, comme demandé.
-- ---------------------------------------------------------------------
do $$ begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'opportunites'
               and column_name = 'gardien_id') then
    alter table opportunites rename column gardien_id to prescripteur_id;
  end if;
end $$;

alter table opportunites add column if not exists reseau_id uuid references reseaux(id);
alter table opportunites add column if not exists categorie categorie_prescripteur;
alter table opportunites add column if not exists conseiller_id uuid references conseillers(id);
alter table opportunites add column if not exists saisie_par text
  check (saisie_par in ('formulaire','manuelle','import'));

update opportunites o set reseau_id = r.id
  from reseaux r where r.code = 'gardiens' and o.reseau_id is null;
update opportunites set categorie = 'gardien' where categorie is null;
update opportunites set saisie_par = 'formulaire' where saisie_par is null;

-- L'origine se déduit du prescripteur si elle n'est pas fournie, et ne
-- bouge plus ensuite : une opportunité partagée par un étudiant restera
-- une opportunité étudiante, même si la personne change de réseau un jour.
create or replace function figer_origine()
returns trigger language plpgsql as $$
begin
  if new.reseau_id is null or new.categorie is null then
    select coalesce(new.reseau_id, p.reseau_id), coalesce(new.categorie, p.categorie)
      into new.reseau_id, new.categorie
      from prescripteurs p where p.id = new.prescripteur_id;
  end if;
  if new.saisie_par is null then new.saisie_par := 'formulaire'; end if;
  return new;
end $$;

drop trigger if exists trg_origine on opportunites;
create trigger trg_origine before insert on opportunites
for each row execute function figer_origine();

create index if not exists opportunites_reseau on opportunites (reseau_id, partagee_le desc);

-- ---------------------------------------------------------------------
-- 7. Biens et prospects : des vues, pas des tables
--
--    Les coordonnées du propriétaire et l'adresse du bien vivent déjà dans
--    « opportunites », et mon-espace.html les y lit. Les recopier dans des
--    tables séparées obligerait à modifier le site, ou à maintenir deux
--    vérités. On les expose donc en lecture, sans rien déplacer.
-- ---------------------------------------------------------------------
create or replace view biens with (security_invoker = true) as
  select
    cle_bien,
    min(adresse_saisie)  as adresse,
    min(ban_id)          as ban_id,
    min(code_postal)     as code_postal,
    min(commune)         as commune,
    min(departement)     as departement,
    min(batiment)        as batiment,
    min(escalier)        as escalier,
    min(etage)           as etage,
    min(type_bien)       as type_bien,
    count(*)             as nb_opportunites,
    min(partagee_le)     as premiere_partage_le,
    max(partagee_le)     as derniere_partage_le
  from opportunites
  group by cle_bien;

create or replace view prospects with (security_invoker = true) as
  select
    o.id            as opportunite_id,
    o.reference,
    o.proprietaire_nom   as nom,
    o.proprietaire_tel   as telephone,
    o.accord_atteste     as accord_recueilli,
    o.citation_autorisee,
    o.numero_transmis,
    o.cle_bien,
    o.commune,
    o.statut,
    o.partagee_le
  from opportunites o
  where o.proprietaire_nom is not null or o.proprietaire_tel is not null;

-- ---------------------------------------------------------------------
-- 8. Estimations, mandats, ventes
--    Les trois événements qui peuvent déclencher une rémunération.
-- ---------------------------------------------------------------------
create table if not exists estimations (
  id              uuid primary key default gen_random_uuid(),
  opportunite_id  uuid references opportunites(id) on delete set null,
  cle_bien        text,
  type            text not null default 'avis_valeur'
                  check (type in ('avis_valeur','expertise_valeur_venale')),
  valeur_euros    numeric(12,2),
  remise_le       date,
  reglee_le       date,                      -- l'expertise se paie même sans vente
  honoraires_nets numeric(10,2),
  conseiller_id   uuid references conseillers(id),
  cree_le         timestamptz not null default now()
);
create index if not exists estimations_opportunite on estimations (opportunite_id);

create table if not exists mandats (
  id               uuid primary key default gen_random_uuid(),
  opportunite_id   uuid references opportunites(id) on delete set null,
  cle_bien         text,
  type             text not null default 'vente' check (type in ('vente','recherche')),
  exclusif         boolean not null default false,
  diagnostics_faits boolean not null default false,
  signe_le         date,
  echeance_le      date,
  conseiller_id    uuid references conseillers(id),
  cree_le          timestamptz not null default now()
);
create index if not exists mandats_opportunite on mandats (opportunite_id);

create table if not exists ventes (
  id               uuid primary key default gen_random_uuid(),
  opportunite_id   uuid references opportunites(id) on delete set null,
  mandat_id        uuid references mandats(id) on delete set null,
  cle_bien         text,
  compromis_le     date,
  acte_le          date,                     -- c'est cette date qui fait foi
  prix_euros       numeric(12,2),
  honoraires_bruts numeric(10,2),
  -- L'assiette des associations : honoraires HORS TAXES effectivement perçus,
  -- après TVA et après la quote-part du réseau mandant. Jamais le brut facturé.
  honoraires_nets  numeric(10,2),
  conseiller_id    uuid references conseillers(id),
  cree_le          timestamptz not null default now()
);
create index if not exists ventes_opportunite on ventes (opportunite_id);
create index if not exists ventes_acte on ventes (acte_le desc);

-- ---------------------------------------------------------------------
-- 9. Les règles de rémunération
--
--    Rien n'est codé en dur. Les 1 000 € des gardiens, les 50 € et 800 € des
--    étudiants, les 10 % des associations sont des LIGNES de cette table.
--    Une campagne, un changement de montant, un nouveau réseau : une ligne.
-- ---------------------------------------------------------------------
create table if not exists regles_remuneration (
  id            uuid primary key default gen_random_uuid(),
  reseau_id     uuid not null references reseaux(id),
  libelle       text not null,
  declencheur   text not null
                check (declencheur in ('mandat_exclusif','acte_authentique','expertise_reglee')),
  mode          text not null check (mode in ('forfait','pourcentage')),
  montant_euros integer,                     -- si forfait
  taux_pourcent numeric(5,2),                -- si pourcentage
  assiette      text check (assiette in ('honoraires_nets','honoraires_bruts')),
  plafond_annuel_euros integer,              -- null = aucun plafond
  valide_du     date not null default current_date,
  valide_au     date,
  actif         boolean not null default true,
  cree_le       timestamptz not null default now(),

  constraint forfait_ou_taux check (
    (mode = 'forfait'     and montant_euros is not null and taux_pourcent is null) or
    (mode = 'pourcentage' and taux_pourcent is not null and assiette is not null)
  )
);

-- Paramétrage initial, repris des trois sites. Montants et taux restent
-- soumis à la validation de Marie-Céline et à la relecture juridique.
insert into regles_remuneration (reseau_id, libelle, declencheur, mode, montant_euros, taux_pourcent, assiette)
select r.id, v.libelle, v.declencheur, v.mode, v.montant, v.taux, v.assiette
from (values
  ('gardiens',     'Vente réalisée — 1 000 € nets',                   'acte_authentique', 'forfait',     1000, null,        null),
  ('etudiants',    'Mandat exclusif signé, diagnostics réalisés',     'mandat_exclusif',  'forfait',       50, null,        null),
  ('etudiants',    'Vente réalisée',                                  'acte_authentique', 'forfait',      800, null,        null),
  ('associations', 'Vente ou acquisition — 10 % des honoraires nets', 'acte_authentique', 'pourcentage', null, 10.00, 'honoraires_nets'),
  ('associations', 'Expertise en valeur vénale réglée — 10 % nets',   'expertise_reglee', 'pourcentage', null, 10.00, 'honoraires_nets')
) as v(reseau, libelle, declencheur, mode, montant, taux, assiette)
join reseaux r on r.code = v.reseau
where not exists (
  select 1 from regles_remuneration x
  where x.reseau_id = r.id and x.libelle = v.libelle
);

-- ---------------------------------------------------------------------
-- 10. Les primes
--
--     montant_euros reste un entier : mon-espace.html l'affiche tel quel et
--     doit continuer d'écrire « 1 000 € ». Les rémunérations en pourcentage
--     rangent leur centime exact à côté, sans toucher à la colonne existante.
-- ---------------------------------------------------------------------
do $$ begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'primes'
               and column_name = 'gardien_id') then
    alter table primes rename column gardien_id to prescripteur_id;
  end if;
end $$;

alter table primes add column if not exists regle_id uuid references regles_remuneration(id);
alter table primes add column if not exists vente_id uuid references ventes(id) on delete set null;
alter table primes add column if not exists mandat_id uuid references mandats(id) on delete set null;
alter table primes add column if not exists estimation_id uuid references estimations(id) on delete set null;
alter table primes add column if not exists montant_exact numeric(10,2);
alter table primes add column if not exists reseau_id uuid references reseaux(id);

update primes p set reseau_id = r.id
  from reseaux r where r.code = 'gardiens' and p.reseau_id is null;

-- Une opportunité pouvait ne porter qu'une prime : ce n'est plus vrai
-- (un étudiant touche au mandat PUIS à la vente).
alter table primes drop constraint if exists primes_opportunite_id_key;
create index if not exists primes_opportunite on primes (opportunite_id);
create index if not exists primes_prescripteur on primes (prescripteur_id, cree_le desc);

-- ---------------------------------------------------------------------
-- 11. Les fonctions, remises à jour après les renommages
-- ---------------------------------------------------------------------
create or replace function cumul_annuel(g uuid, annee integer default extract(year from now())::int)
returns integer language sql stable as $$
  select coalesce(sum(montant_euros), 0)::int
  from primes
  where prescripteur_id = g and statut = 'versee'
    and extract(year from versee_le) = annee;
$$;

-- Le filet anti-prime-oubliée, désormais tous réseaux confondus.
-- Elle renvoie deux colonnes de plus qu'avant : PostgreSQL refuse de
-- remplacer une fonction dont le type de retour change, il faut la retirer.
drop function if exists rapprocher(text);
create or replace function rapprocher(cle text)
returns table (
  reference       text,
  partagee_le     timestamptz,
  statut          statut_opportunite,
  expiree         boolean,
  prescripteur_id uuid,
  prescripteur    text,
  categorie       categorie_prescripteur,
  reseau          text
)
language sql stable security definer set search_path = public as $$
  select o.reference, o.partagee_le, o.statut,
         (o.expire_le < now()) as expiree,
         p.id,
         coalesce(nullif(trim(p.prenom || ' ' || coalesce(p.nom, '')), ''), p.email),
         o.categorie,
         r.nom
  from opportunites o
  join prescripteurs p on p.id = o.prescripteur_id
  left join reseaux r on r.id = o.reseau_id
  where o.cle_bien = cle
  order by o.partagee_le asc;
$$;
revoke execute on function rapprocher(text) from anon, authenticated;

-- ---------------------------------------------------------------------
-- 12. Les règles d'accès
--     Rien n'est lisible par défaut. Chaque autorisation est explicite.
-- ---------------------------------------------------------------------
alter table reseaux             enable row level security;
alter table conseillers         enable row level security;
alter table estimations         enable row level security;
alter table mandats             enable row level security;
alter table ventes              enable row level security;
alter table regles_remuneration enable row level security;

-- Les règles héritées de la table « gardiens » portent maintenant sur
-- « prescripteurs » : on les réécrit sous leur nouveau nom.
drop policy if exists gardien_lit_sa_fiche      on prescripteurs;
drop policy if exists gardien_cree_sa_fiche     on prescripteurs;
drop policy if exists gardien_modifie_sa_fiche  on prescripteurs;

drop policy if exists prescripteur_lit_sa_fiche on prescripteurs;
create policy prescripteur_lit_sa_fiche on prescripteurs
  for select using (id = auth.uid() or est_admin());

drop policy if exists prescripteur_cree_sa_fiche on prescripteurs;
create policy prescripteur_cree_sa_fiche on prescripteurs
  for insert with check (id = auth.uid());

drop policy if exists prescripteur_modifie_sa_fiche on prescripteurs;
create policy prescripteur_modifie_sa_fiche on prescripteurs
  for update using (id = auth.uid() or est_admin())
             with check (id = auth.uid() or est_admin());

-- Opportunités : la règle change de nom de colonne, pas de principe.
drop policy if exists gardien_lit_ses_opportunites on opportunites;
drop policy if exists gardien_partage              on opportunites;

drop policy if exists prescripteur_lit_ses_opportunites on opportunites;
create policy prescripteur_lit_ses_opportunites on opportunites
  for select using (prescripteur_id = auth.uid() or est_admin());

drop policy if exists prescripteur_partage on opportunites;
create policy prescripteur_partage on opportunites
  for insert with check (prescripteur_id = auth.uid());

drop policy if exists lecture_journal on evenements;
create policy lecture_journal on evenements
  for select using (
    est_admin() or exists (
      select 1 from opportunites o
      where o.id = evenements.opportunite_id and o.prescripteur_id = auth.uid()
    )
  );

drop policy if exists gardien_lit_ses_primes on primes;
drop policy if exists prescripteur_lit_ses_primes on primes;
create policy prescripteur_lit_ses_primes on primes
  for select using (prescripteur_id = auth.uid() or est_admin());

-- Le catalogue des réseaux est public en lecture : les pages de partage en
-- ont besoin pour savoir de quel réseau elles parlent. Il ne contient rien
-- de confidentiel.
drop policy if exists reseaux_lisibles on reseaux;
create policy reseaux_lisibles on reseaux for select using (true);

-- Tout le reste appartient au conseiller, et à lui seul.
do $$
declare t text;
begin
  foreach t in array array['conseillers','estimations','mandats','ventes','regles_remuneration'] loop
    execute format('drop policy if exists %I_admin on %I', t, t);
    execute format('create policy %I_admin on %I for all using (est_admin()) with check (est_admin())', t, t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 13. Les accès au niveau des tables
--     « Automatically expose new tables » est décoché : sans ce bloc, rien
--     n'est joignable par l'API. Deux verrous : ici QUELLES TABLES, au
--     bloc 12 QUELLES LIGNES.
-- ---------------------------------------------------------------------
grant usage on schema public to anon, authenticated;

-- Ce que le prescripteur touche depuis son espace personnel.
grant select, insert, update on prescripteurs to authenticated;
grant select, insert, update on gardiens      to authenticated;  -- la vue
grant select, insert          on opportunites  to authenticated;
grant select                  on evenements    to authenticated;
grant select                  on primes        to authenticated;
grant select                  on reseaux       to authenticated, anon;

-- Ce que le conseiller touche depuis app.idf.immo. Le rôle est le même :
-- c'est est_admin() qui ouvre, jamais un privilège de table.
grant update, delete on opportunites        to authenticated;
grant insert         on evenements          to authenticated;
grant all            on notes_internes      to authenticated;
grant all            on primes              to authenticated;
grant all            on conseillers         to authenticated;
grant all            on estimations         to authenticated;
grant all            on mandats             to authenticated;
grant all            on ventes              to authenticated;
grant all            on regles_remuneration to authenticated;
grant select         on administrateurs     to authenticated;
grant select         on biens, prospects    to authenticated;

grant usage on sequence evenements_id_seq     to authenticated;
grant usage on sequence notes_internes_id_seq to authenticated;
grant usage on sequence numero_opportunite    to authenticated;

-- ⚠️  Deux fonctions doivent rester hors de portée des prescripteurs :
--     rapprocher() révèle l'identité de qui a partagé un bien, et
--     purger_expirees() EFFACE des opportunités. Toutes deux sont
--     « security definer » : elles s'exécutent avec les pleins pouvoirs.
--
--     PostgreSQL accorde l'exécution à PUBLIC dès la création d'une fonction.
--     Retirer le droit à « anon » et « authenticated » ne sert donc à rien
--     tant que PUBLIC l'a encore : c'est par là que le droit revient. Il faut
--     révoquer PUBLIC d'abord, puis rendre explicitement ce qui est voulu.
revoke execute on function rapprocher(text)      from public, anon, authenticated;
revoke execute on function purger_expirees()     from public, anon, authenticated;
revoke execute on function anteriorite(text)     from public;
revoke execute on function est_admin()           from public;
revoke execute on function cumul_annuel(uuid, integer) from public;

grant execute on function est_admin()                 to authenticated;
grant execute on function anteriorite(text)           to authenticated;
grant execute on function cumul_annuel(uuid, integer) to authenticated;

-- ---------------------------------------------------------------------
-- 14. Après l'exécution
--
--   a) Vérifier que gardiens.idf.immo n'a rien vu passer. Cette requête doit
--      renvoyer autant de lignes qu'avant, avec les mêmes colonnes :
--
--        select * from gardiens;
--
--   b) Vérifier que le verrou tient. Connectée en tant que prescripteur de
--      test, cette requête doit renvoyer zéro ligne :
--
--        select * from opportunites where prescripteur_id <> auth.uid();
--
--   c) Vérifier le paramétrage des primes :
--
--        select r.nom, g.libelle, g.mode, g.montant_euros, g.taux_pourcent
--        from regles_remuneration g join reseaux r on r.id = g.reseau_id
--        order by r.nom;
--
--   d) « permission denied for table … » signifie qu'une autorisation manque
--      au bloc 13, et non que les règles du bloc 12 sont mal écrites. Les
--      deux verrous se diagnostiquent séparément.
-- ---------------------------------------------------------------------
