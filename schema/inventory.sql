-- db_inventory: the inventory namespace.
--   psql -h <host> -p <port> -U <user> -d db_inventory -v ON_ERROR_STOP=1 -f schema/inventory.sql
-- Objects that already exist are skipped, so it can be run again.
-- TEXT in a key or an index is VARCHAR(10485760), the type ScalarDB uses on PostgreSQL.
CREATE SCHEMA IF NOT EXISTS inventory;

CREATE TABLE IF NOT EXISTS inventory.items (
  item_id INT NOT NULL,
  name    VARCHAR(10485760),
  price   BIGINT,
  stock   INT,
  PRIMARY KEY (item_id)
);
CREATE INDEX IF NOT EXISTS index_inventory_items_name ON inventory.items (name);
