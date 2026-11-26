-- Oracle: the sample data (the same rows as schema/seed/*.sql). setup/oracle/setup-db-oracle.sh runs it
-- only before the tables are imported into ScalarDB. Rows that already exist are skipped.
SET SERVEROUTPUT ON
DECLARE
  PROCEDURE ins(p_sql VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_sql;
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN NULL;
  END;
BEGIN
  ins('INSERT INTO "customer"."customers" ("customer_id", "name", "credit_limit", "credit_total") VALUES (1, ''alice'', 100000, 0)');
  ins('INSERT INTO "customer"."customers" ("customer_id", "name", "credit_limit", "credit_total") VALUES (2, ''bob'', 50000, 0)');
  ins('INSERT INTO "customer"."customers" ("customer_id", "name", "credit_limit", "credit_total") VALUES (3, ''carol'', 10000, 0)');
  ins('INSERT INTO "inventory"."items" ("item_id", "name", "price", "stock") VALUES (1, ''pen'', 100, 100)');
  ins('INSERT INTO "inventory"."items" ("item_id", "name", "price", "stock") VALUES (2, ''notebook'', 300, 50)');
  ins('INSERT INTO "inventory"."items" ("item_id", "name", "price", "stock") VALUES (3, ''eraser'', 80, 200)');
  ins('INSERT INTO "inventory"."items" ("item_id", "name", "price", "stock") VALUES (4, ''ruler'', 150, 30)');
  ins('INSERT INTO "inventory"."items" ("item_id", "name", "price", "stock") VALUES (5, ''stapler'', 900, 10)');
  COMMIT;
END;
/
