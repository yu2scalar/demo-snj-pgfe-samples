-- db_ordering: the ordering namespace.
--   psql -h <host> -p <port> -U <user> -d db_ordering -v ON_ERROR_STOP=1 -f schema/ordering.sql
-- Objects that already exist are skipped, so it can be run again.
-- TEXT in a key or an index is VARCHAR(10485760), the type ScalarDB uses on PostgreSQL.
CREATE SCHEMA IF NOT EXISTS ordering;

CREATE TABLE IF NOT EXISTS ordering.orders (
  order_id     VARCHAR(10485760) NOT NULL,
  customer_id  INT,
  created_at   BIGINT,
  status       TEXT,
  total_amount BIGINT,
  PRIMARY KEY (order_id)
);
CREATE INDEX IF NOT EXISTS index_ordering_orders_customer_id ON ordering.orders (customer_id);
CREATE INDEX IF NOT EXISTS index_ordering_orders_created_at ON ordering.orders (created_at);

CREATE TABLE IF NOT EXISTS ordering.statements (
  order_id   VARCHAR(10485760) NOT NULL,
  line_no    INT NOT NULL,
  item_id    INT,
  qty        INT,
  unit_price BIGINT,
  PRIMARY KEY (order_id, line_no)
);
CREATE INDEX IF NOT EXISTS index_ordering_statements_item_id ON ordering.statements (item_id);
