-- db_customer: the customer namespace.
--   psql -h <host> -p <port> -U <user> -d db_customer -v ON_ERROR_STOP=1 -f schema/customer.sql
-- Objects that already exist are skipped, so it can be run again.
-- TEXT in a key or an index is VARCHAR(10485760), the type ScalarDB uses on PostgreSQL.
CREATE SCHEMA IF NOT EXISTS customer;

CREATE TABLE IF NOT EXISTS customer.customers (
  customer_id  INT NOT NULL,
  name         VARCHAR(10485760),
  credit_limit BIGINT,
  credit_total BIGINT,
  PRIMARY KEY (customer_id)
);
CREATE INDEX IF NOT EXISTS index_customer_customers_name ON customer.customers (name);
