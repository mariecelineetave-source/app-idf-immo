-- =====================================================================
-- correctif-2a — la catégorie « professionnel »
--
-- À exécuter SEUL, avant correctif-2.sql : PostgreSQL refuse qu'une valeur
-- d'énumération serve dans la transaction même qui l'ajoute. Une commande,
-- une transaction, et le correctif-2 peut ensuite s'en servir.
-- =====================================================================

alter type categorie_prescripteur add value if not exists 'professionnel';
