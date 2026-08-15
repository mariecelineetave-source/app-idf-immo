/* =====================================================================
   app.idf.immo — coordonnées de la base

   Ces deux valeurs sont PUBLIQUES par conception : elles voyagent dans le
   navigateur de chaque visiteur, et Supabase les qualifie lui-même de
   « safe to use in a browser ». Les voir ne donne accès à rien.

   Ce qui protège réellement les données, ce sont les règles installées par
   base/socle.sql : la base refuse de servir à un prescripteur autre chose que
   ses propres opportunités, et n'ouvre le back-office qu'aux comptes inscrits
   dans la table « administrateurs ». Quelle que soit la requête adressée.

   C'est le même projet Supabase que gardiens.idf.immo : un seul socle, un
   seul back-office, tous réseaux confondus.

   La clé « secrète » (sb_secret_…), elle, n'a jamais sa place dans ce dépôt
   ni dans aucun fichier du site.
   ===================================================================== */

window.CONFIG_BASE = {
  url: "https://uiciolavnalimrjlpesx.supabase.co",
  cle: "sb_publishable_rCVYAzc9PyppEfijDMdHzg_C--mKXj1"
};
