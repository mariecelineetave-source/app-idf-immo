-- =====================================================================
-- correctif-2 — pros.idf.immo rejoint la famille
--
-- À coller dans Supabase après correctif-1.sql :
--   projet → SQL Editor → New query → Run. Rejouable.
--
-- Le socle avait tout prévu : la catégorie « professionnel » a été créée
-- par le correctif-1, en attendant que le domaine existe. Il existe depuis
-- le 21 août 2026. Ce correctif ne fait donc que trois choses :
--
--   1. il ouvre le réseau « pros » — le back-office lisant la table des
--      réseaux, pros.idf.immo y apparaît sans qu'une ligne de code change ;
--   2. il ajoute à la fiche ce qu'un professionnel a de particulier :
--      son enseigne et son métier, là où un gardien a sa résidence ;
--   3. il crée la vue « pros », que l'espace personnel du site interroge
--      sous ce nom, avec les mêmes déclencheurs que les autres réseaux.
--
-- Aucune fiche existante n'est touchée.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Le socle doit être à jour
-- ---------------------------------------------------------------------
do $$ begin
  if not exists (
    select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
    where t.typname = 'categorie_prescripteur' and e.enumlabel = 'professionnel'
  ) then
    raise exception
      'Passer d''abord socle.sql puis correctif-1.sql : la catégorie « professionnel » n''existe pas encore.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. Le réseau est ouvert
-- ---------------------------------------------------------------------
insert into reseaux (code, nom, domaine, categorie, actif) values
  ('pros', 'Pros IDF.immo', 'pros.idf.immo', 'professionnel', true)
on conflict (code) do update
  set nom = excluded.nom, domaine = excluded.domaine,
      categorie = excluded.categorie, actif = true;

-- ---------------------------------------------------------------------
-- 2. Ce qu'un professionnel a de particulier
--
--    Un gardien a une résidence, une association a une organisation, un
--    commerçant a une enseigne et un métier. Colonnes facultatives : elles
--    restent vides pour les autres réseaux.
-- ---------------------------------------------------------------------
alter table prescripteurs add column if not exists enseigne text;
alter table prescripteurs add column if not exists metier   text;

-- ---------------------------------------------------------------------
-- 3. La vue « pros »
--
--    mon-espace.html de pros.idf.immo lit une table « pros » et y insère
--    sa fiche au premier passage, exactement comme gardiens.idf.immo lit
--    « gardiens ». Même dispositif, colonnes adaptées.
-- ---------------------------------------------------------------------
create or replace function vue_pro_modification()
returns trigger language plpgsql as $$
begin
  update prescripteurs set
    prenom    = new.prenom,
    nom       = new.nom,
    email     = new.email,
    telephone = new.telephone,
    enseigne  = new.enseigne,
    metier    = new.metier,
    commune   = new.commune,
    iban      = new.iban
  where id = old.id;
  return new;
end $$;

create or replace view pros with (security_invoker = true) as
  select id, prenom, nom, email, telephone, enseigne, metier, commune, iban, cree_le
  from prescripteurs
  where categorie = 'professionnel';

drop trigger if exists trg_pros_insertion on pros;
create trigger trg_pros_insertion instead of insert on pros
for each row execute function vue_prescripteur_insertion('professionnel', 'pros');

drop trigger if exists trg_pros_modification on pros;
create trigger trg_pros_modification instead of update on pros
for each row execute function vue_pro_modification();

grant select, insert, update on pros to authenticated;

-- ---------------------------------------------------------------------
-- 4. Après l'exécution
--
--   a) Le réseau doit apparaître, actif :
--        select code, nom, domaine, actif from reseaux order by nom;
--
--   b) La vue doit répondre (vide au début, c'est normal) :
--        select * from pros;
--
--   c) Rien ne doit avoir bougé ailleurs :
--        select categorie, count(*) from prescripteurs group by categorie;
--
--   d) Le back-office app.idf.immo propose désormais « Pros IDF.immo »
--      dans le choix du réseau, à la saisie d'un prescripteur comme au
--      filtrage des opportunités. Rien à y modifier.
-- ---------------------------------------------------------------------
