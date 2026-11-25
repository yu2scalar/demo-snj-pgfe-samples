-- Sample data for db_customer. setup/setup-db.sh runs it before the import, only when the table is
-- not imported into ScalarDB yet (after the import, write only through SNJ or ScalarDB).
-- customer_id 901 and 902 are left for local/try.sh.
INSERT INTO customer.customers (customer_id, name, credit_limit, credit_total) VALUES
  (1, 'alice', 100000, 0),
  (2, 'bob',    50000, 0),
  (3, 'carol',  10000, 0)
ON CONFLICT DO NOTHING;
