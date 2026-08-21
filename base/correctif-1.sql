-- =====================================================================
-- app.idf.immo — correctif nº 1 du socle
--
-- À coller dans Supabase : projet → SQL Editor → New query → Run.
-- REJOUABLE : l'exécuter deux fois ne casse rien.
--
-- Ce script répare quatre choses trouvées en rejouant toute la chaîne
-- (partage → qualification → mandat → vente → prime → versement) sur une
-- copie exacte de la base :
--
--   1. Le conseiller ne pouvait PAS créer d'opportunité. La règle
--      n'autorisait que le prescripteur lui-même. Toute la mécanique
--      étudiants / associations / nounous, qui repose sur une saisie
--      manuelle depuis le back-office, était donc impossible.
--
--   2. Une fiche de prescripteur ne pouvait exister QUE si la personne
--      s'était déjà connectée au site. Quelqu'un qui téléphone, ou qui
--      remplit le formulaire sans ouvrir son espace, ne pouvait pas être
--      enregistré du tout.
--
--   3. nounous.idf.immo est en ligne et son espace lit une table
--      « nounous » qui n'existe pas : la page est cassée. Comme pour les
--      gardiens, on lui donne une VUE à son nom plutôt que de toucher au
--      site. Le socle s'adapte au site, jamais l'inverse.
--
--   4. Le réseau nounous était marqué « pas encore ouvert ».
--
-- ⚠️  Les sites publics ne sont pas modifiés par ce script.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Une fiche peut désormais exister avant le compte
--
--    La clé de la fiche pointait obligatoirement vers un compte de
--    connexion. On retire cette obligation : le conseiller crée la fiche
--    quand la personne l'appelle, et le compte s'y rattachera tout seul
--    au premier accès (bloc 3).
-- ---------------------------------------------------------------------
do $$
declare c text;
begin
  -- Le lien vers auth.users, quel que soit le nom hérité du renommage.
  for c in select conname from pg_constraint
           where conrelid = 'public.prescripteurs'::regclass and contype = 'f'
  loop
    execute format('alter table prescripteurs drop constraint %I', c);
  end loop;
end $$;

-- Le lien vers le réseau, lui, doit rester : la boucle ci-dessus l'a emporté
-- avec les autres.
do $$ begin
  alter table prescripteurs add constraint prescripteurs_reseau_fk
    foreign key (reseau_id) references reseaux(id);
exception when duplicate_object then null; end $$;

alter table prescripteurs alter column id set default gen_random_uuid();
alter table prescripteurs alter column prenom drop not null;

-- Les enfants doivent suivre si la clé de la fiche change au rattachement.
do $$
declare t text; c text;
begin
  foreach t in array array['opportunites','primes'] loop
    for c in select conname from pg_constraint
             where conrelid = ('public.'||t)::regclass and contype = 'f'
               and confrelid = 'public.prescripteurs'::regclass
    loop
      execute format('alter table %I drop constraint %I', t, c);
    end loop;
    execute format(
      'alter table %I add constraint %I foreign key (prescripteur_id)
       references prescripteurs(id) on update cascade on delete restrict',
      t, t || '_prescripteur_fk');
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 2. Le conseiller peut créer des fiches et des opportunités
--
--    Les règles existantes ne sont pas retirées : le prescripteur peut
--    toujours créer la sienne. On AJOUTE le droit du conseiller.
-- ---------------------------------------------------------------------
drop policy if exists admin_cree_une_fiche on prescripteurs;
create policy admin_cree_une_fiche on prescripteurs
  for insert with check (est_admin());

drop policy if exists admin_saisit_une_opportunite on opportunites;
create policy admin_saisit_une_opportunite on opportunites
  for insert with check (est_admin());

-- ---------------------------------------------------------------------
-- 3. Le rattachement automatique
--
--    Quand quelqu'un se connecte pour la première fois, on regarde si une
--    fiche existe déjà à son adresse. Si oui, on la lui donne — avec ses
--    opportunités et ses primes, qui suivent grâce au bloc 1. Sinon, on
--    en crée une.
--
--    C'est cette fonction que les déclencheurs des vues appellent : les
--    sites gelés en profitent SANS qu'une ligne de leur code ne change.
-- ---------------------------------------------------------------------
create or replace function fiche_de_ce_compte(
  p_email text, p_prenom text, p_categorie categorie_prescripteur, p_reseau text)
returns prescripteurs
language plpgsql security definer set search_path = public as $$
declare f prescripteurs; r uuid; m text;
begin
  m := lower(trim(coalesce(p_email, '')));

  -- Déjà rattachée ?
  select * into f from prescripteurs where id = auth.uid();
  if found then return f; end if;

  select id into r from reseaux where code = p_reseau;

  -- Une fiche créée d'avance porte-t-elle cette adresse ? On la rattache.
  if m <> '' then
    update prescripteurs p set id = auth.uid()
     where p.id = (select id from prescripteurs
                   where lower(email) = m order by cree_le limit 1)
       and p.id <> auth.uid()
    returning * into f;
    if found then return f; end if;
  end if;

  insert into prescripteurs (id, email, prenom, categorie, reseau_id)
  values (auth.uid(), p_email, coalesce(nullif(p_prenom, ''), split_part(m, '@', 1)),
          p_categorie, r)
  returning * into f;
  return f;
end $$;

grant execute on function fiche_de_ce_compte(text, text, categorie_prescripteur, text)
  to authenticated;
revoke execute on function fiche_de_ce_compte(text, text, categorie_prescripteur, text)
  from public, anon;

-- ---------------------------------------------------------------------
-- 4. Une vue par réseau, portant le nom que le site attend
--
--    gardiens.idf.immo lit « gardiens », nounous.idf.immo lit « nounous ».
--    Chaque site continue de demander son nom et de recevoir son nom.
-- ---------------------------------------------------------------------
create or replace function vue_prescripteur_insertion()
returns trigger language plpgsql as $$
declare f prescripteurs;
begin
  f := fiche_de_ce_compte(new.email, new.prenom,
                          TG_ARGV[0]::categorie_prescripteur, TG_ARGV[1]);
  new.id := f.id;
  new.prenom := f.prenom;
  return new;
end $$;

create or replace function vue_prescripteur_modification()
returns trigger language plpgsql as $$
begin
  update prescripteurs set
    prenom = new.prenom, nom = new.nom, email = new.email,
    telephone = new.telephone, residence = new.residence,
    commune = new.commune, iban = new.iban
  where id = old.id;
  return new;
end $$;

do $$
declare v record;
begin
  for v in
    select * from (values
      ('gardiens',     'gardien',     'gardiens'),
      ('nounous',      'nounou',      'nounous'),
      ('etudiants',    'etudiant',    'etudiants'),
      ('associations', 'association', 'associations')
    ) as t(vue, categorie, reseau)
  loop
    execute format($f$
      create or replace view %I with (security_invoker = true) as
        select id, prenom, nom, email, telephone, residence, commune, iban, cree_le
        from prescripteurs where categorie = %L $f$, v.vue, v.categorie);

    execute format('drop trigger if exists trg_%s_insertion on %I', v.vue, v.vue);
    execute format($f$
      create trigger trg_%s_insertion instead of insert on %I
      for each row execute function vue_prescripteur_insertion(%L, %L) $f$,
      v.vue, v.vue, v.categorie, v.reseau);

    execute format('drop trigger if exists trg_%s_modification on %I', v.vue, v.vue);
    execute format($f$
      create trigger trg_%s_modification instead of update on %I
      for each row execute function vue_prescripteur_modification() $f$, v.vue, v.vue);

    execute format('grant select, insert, update on %I to authenticated', v.vue);
  end loop;
end $$;

-- Les anciens déclencheurs de la vue « gardiens », remplacés par les génériques.
drop trigger if exists trg_gardiens_insertion   on gardiens;
drop trigger if exists trg_gardiens_modification on gardiens;
do $$ begin
  execute 'create trigger trg_gardiens_insertion instead of insert on gardiens
           for each row execute function vue_prescripteur_insertion(''gardien'', ''gardiens'')';
  execute 'create trigger trg_gardiens_modification instead of update on gardiens
           for each row execute function vue_prescripteur_modification()';
end $$;
drop function if exists gardiens_insertion();
drop function if exists gardiens_modification();

-- ---------------------------------------------------------------------
-- 5. Le réseau nounous est ouvert
--
--    Le site est en ligne depuis ce matin. La catégorie « professionnel »
--    est préparée pour pros.idf.immo ; le réseau lui-même s'ajoutera en
--    une ligne le jour où le domaine existera.
-- ---------------------------------------------------------------------
update reseaux set actif = true where code = 'nounous';

-- La catégorie « professionnel » a migré dans base/correctif-2a-enum.sql :
-- PostgreSQL refuse qu'une valeur d'énumération soit utilisée dans la
-- transaction qui l'ajoute, elle doit donc s'exécuter seule.

-- ---------------------------------------------------------------------
-- 6. Après l'exécution
--
--   a) Vérifier que chaque site voit toujours sa table :
--        select * from gardiens;
--        select * from nounous;
--
--   b) Vérifier que le conseiller peut créer une fiche. Connectée comme
--      administratrice, ceci doit fonctionner :
--        insert into prescripteurs (email, prenom, categorie)
--        values ('essai@exemple.fr', 'Essai', 'etudiant');
--        delete from prescripteurs where email = 'essai@exemple.fr';
--
--   c) Le réseau nounous doit être actif :
--        select code, actif from reseaux order by code;
-- ---------------------------------------------------------------------
