-- Sample data for db_inventory. setup/setup-db.sh runs it before the import, only when the table is
-- not imported into ScalarDB yet (after the import, write only through SNJ or ScalarDB).
-- item_id 901 is left for local/try.sh.
INSERT INTO inventory.items (item_id, name, price, stock) VALUES
  (1, 'pen',       100, 100),
  (2, 'notebook',  300,  50),
  (3, 'eraser',     80, 200),
  (4, 'ruler',     150,  30),
  (5, 'stapler',   900,  10)
ON CONFLICT DO NOTHING;
