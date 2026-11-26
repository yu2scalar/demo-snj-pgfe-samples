-- Oracle: the sample's three schemas and four tables (Oracle 19c or later).
--   sqlplus <dba-user>/<password>@//<host>:1521/<service> @schema/oracle/tables.sql
-- In Oracle a schema is a user: customer, inventory and ordering are schema-only accounts (no
-- password, no login), and a DBA-level user creates and uses the tables.
--
-- The names are quoted and lower-case ("customer"."customers"), as on PostgreSQL, so that the same SQL
-- works through ScalarDB Native JDBC (Oracle) and the PostgreSQL Frontend: the application quotes every
-- name. Unquoted, Oracle would make them upper-case, and ScalarDB would import them so.
--
-- The types are what ScalarDB creates on Oracle: TEXT in a key or an index is VARCHAR2(128), other TEXT
-- is VARCHAR2(4000), INT is NUMBER(10) and BIGINT NUMBER(18) (the Schema Loader imports NUMBER of
-- precision 18 at most). Objects that already exist are skipped, so it can be run again.
-- Assumes the tablespace USERS.
SET SERVEROUTPUT ON
DECLARE
  PROCEDURE run(p_sql VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_sql;
  EXCEPTION
    WHEN OTHERS THEN
      -- ORA-01920: user name conflicts; ORA-00955: name already used; ORA-01408: already indexed
      IF SQLCODE IN (-1920, -955, -1408) THEN
        DBMS_OUTPUT.PUT_LINE('skipped (exists): ' || SUBSTR(p_sql, 1, 60));
      ELSE
        RAISE;
      END IF;
  END;
BEGIN
  run('CREATE USER "customer" NO AUTHENTICATION DEFAULT TABLESPACE USERS QUOTA UNLIMITED ON USERS');
  run('CREATE USER "inventory" NO AUTHENTICATION DEFAULT TABLESPACE USERS QUOTA UNLIMITED ON USERS');
  run('CREATE USER "ordering" NO AUTHENTICATION DEFAULT TABLESPACE USERS QUOTA UNLIMITED ON USERS');

  run('CREATE TABLE "customer"."customers" (
         "customer_id"  NUMBER(10) NOT NULL,
         "name"         VARCHAR2(128),
         "credit_limit" NUMBER(18),
         "credit_total" NUMBER(18),
         PRIMARY KEY ("customer_id"))');
  run('CREATE INDEX "customer"."index_customer_customers_name" ON "customer"."customers" ("name")');

  run('CREATE TABLE "inventory"."items" (
         "item_id" NUMBER(10) NOT NULL,
         "name"    VARCHAR2(128),
         "price"   NUMBER(18),
         "stock"   NUMBER(10),
         PRIMARY KEY ("item_id"))');
  run('CREATE INDEX "inventory"."index_inventory_items_name" ON "inventory"."items" ("name")');

  run('CREATE TABLE "ordering"."orders" (
         "order_id"     VARCHAR2(128) NOT NULL,
         "customer_id"  NUMBER(10),
         "created_at"   NUMBER(18),
         "status"       VARCHAR2(4000),
         "total_amount" NUMBER(18),
         PRIMARY KEY ("order_id"))');
  run('CREATE INDEX "ordering"."index_ordering_orders_customer_id" ON "ordering"."orders" ("customer_id")');
  run('CREATE INDEX "ordering"."index_ordering_orders_created_at" ON "ordering"."orders" ("created_at")');

  run('CREATE TABLE "ordering"."statements" (
         "order_id"   VARCHAR2(128) NOT NULL,
         "line_no"    NUMBER(10) NOT NULL,
         "item_id"    NUMBER(10),
         "qty"        NUMBER(10),
         "unit_price" NUMBER(18),
         PRIMARY KEY ("order_id", "line_no"))');
  run('CREATE INDEX "ordering"."index_ordering_statements_item_id" ON "ordering"."statements" ("item_id")');
END;
/
