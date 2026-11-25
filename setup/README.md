# setup: make the tables and set them up

`setup-db.sh` prepares the three databases for this sample. Run it once, before you add the
databases to ScalarDB Cluster ([README step 3](../README.md#3-add-the-databases-to-scalardb-cluster-and-restart-it)).

**It does not use ScalarDB Cluster.** The script connects only to the three PostgreSQL databases. The
Cluster does not have to be running, and it does not have to know the databases yet.

## What it does

| Step | Tool | What it makes |
|---|---|---|
| 1. Create the tables, and put in the sample data | `psql` | the tables of [`schema/<db>.sql`](../schema), with plain PostgreSQL DDL; the rows of [`schema/seed/<db>.sql`](../schema/seed) |
| 2. Import them into ScalarDB, and make the coordinator table | ScalarDB Schema Loader | `scalardb.metadata` in each database, with that database's tables; `coordinator.state` in `db_ordering` |
| 3. Set them up for ScalarDB Native JDBC (SNJ), and check | `scalardb-native-tools` | an in-flight index and a read view `rc_<table>` per table |

The tables are ScalarDB tables. After step 3, write to them only through SNJ or ScalarDB. Plain `psql`
would bypass both, so use it only to read.

[`drop-db.sh`](#starting-again-drop-dbsh) does the reverse: it drops the tables and their rows.

## What you need

- `psql`, `java` (17 or later), `curl`, `unzip` and `jq`.
- The three databases, `db_customer`, `db_inventory` and `db_ordering`:
  - each created with collation C;
  - owned by the user that the script connects as.

  See [README step 1](../README.md#1-create-the-databases).
- Internet access, the first time. The script downloads the Schema Loader and `scalardb-native-tools`
  3.20.0 into `.tools/` at the root of the repository.

## Settings: setup/db.env

```sh
cp setup/db.env.example setup/db.env && chmod 600 setup/db.env
```

| Variable | Meaning |
|---|---|
| `CUSTOMER_DB_HOST`, `CUSTOMER_DB_PORT` | the server of `db_customer` (port 5432 if not set) |
| `INVENTORY_DB_HOST`, `INVENTORY_DB_PORT` | the server of `db_inventory` |
| `ORDERING_DB_HOST`, `ORDERING_DB_PORT` | the server of `db_ordering` |
| `DB_USER`, `DB_PASSWORD` | the user that owns the three databases (the same user on each) |

The three databases can be on one server or on three. `setup/db.env` is not in git. To use another
file, run `DB_ENV=<file> setup/setup-db.sh`.

## Run it

```sh
setup/setup-db.sh
```

It ends with:

```text
setup-db OK. Next: add the databases to ScalarDB Cluster and restart it (README.md, step 3).
```

## Each step

### 1. Create the tables, and put in the sample data

The script runs `schema/customer.sql` in `db_customer`, and does the same for the other two. The DDL
uses `CREATE ... IF NOT EXISTS`, so a table that exists is kept as it is.

Then it puts in the sample data, with plain `psql`, before the tables are imported into ScalarDB:

| Database | Rows |
|---|---|
| `db_customer` | customers 1 `alice` (credit limit 100000), 2 `bob` (50000), 3 `carol` (10000) |
| `db_inventory` | items 1 `pen` (price 100, stock 100), 2 `notebook` (300, 50), 3 `eraser` (80, 200), 4 `ruler` (150, 30), 5 `stapler` (900, 10) |

- There are no orders. Place them through the API.
- The data goes into a database only when its tables are not imported into ScalarDB yet. On a second
  run, the script prints `sample data skipped (... is already imported into ScalarDB)`, because a
  `psql` insert into an imported table would bypass SNJ and ScalarDB.
- `SEED=0 setup/setup-db.sh` leaves the data out.
- IDs 901 and 902 are left for [`local/try.sh`](../local/try.sh).

### 2. Import into ScalarDB, and make the coordinator table

The Schema Loader turns the tables into ScalarDB tables. It adds ScalarDB's transaction metadata columns
to them and records them in `scalardb.metadata`. The tables to import are listed in
[`schema/import.json`](../schema/import.json). It then makes ScalarDB's coordinator table.

The script gives the Schema Loader these settings. It writes them to a temporary file (mode 600) and
deletes the file at the end. `<...>` comes from `setup/db.env`.

```properties
scalar.db.transaction_manager=consensus-commit
scalar.db.consensus_commit.isolation_level=READ_COMMITTED
scalar.db.storage=multi-storage
scalar.db.multi_storage.storages=customer,inventory,ordering
scalar.db.multi_storage.storages.customer.storage=jdbc
scalar.db.multi_storage.storages.customer.contact_points=jdbc:postgresql://<CUSTOMER_DB_HOST>:<CUSTOMER_DB_PORT>/db_customer
scalar.db.multi_storage.storages.customer.username=<DB_USER>
scalar.db.multi_storage.storages.customer.password=<DB_PASSWORD>
scalar.db.multi_storage.storages.customer.jdbc.isolation_level=REPEATABLE_READ
# ... the same five lines for inventory and ordering ...
scalar.db.multi_storage.namespace_mapping=customer:customer,inventory:inventory,ordering:ordering,coordinator:ordering
scalar.db.multi_storage.default_storage=ordering
```

These are the same storages and namespace mapping that you add to the Cluster in
[README step 3](../README.md#3-add-the-databases-to-scalardb-cluster-and-restart-it). That way:

- Each database gets its own `scalardb.metadata`, with only its own tables. SNJ reads this table in its
  own database.
- The coordinator table goes where `namespace_mapping` sends `coordinator`: `db_ordering`. SNJ does not
  use the coordinator table. Only ScalarDB's transactions (the Cluster) do.

`jdbc.isolation_level` is the isolation level of ScalarDB's own connections to the database. SNJ needs
`REPEATABLE_READ` there to import a table on PostgreSQL. See README step 3 for how this value depends
on the isolation level.

### 3. Set up for ScalarDB Native JDBC

For each database, the script runs `scalardb-native-tools setup` and then `scalardb-native-tools check`.
For each table, the setup makes:

- an **in-flight index** (`<table>_inflight`). The driver uses it to find the rows that ScalarDB
  transactions are writing.
- a **read view** (`rc_<table>`), which shows each row as last committed.

The output for one table:

```text
customer.customers: created in-flight index customers_inflight, backfill skipped (--backfill runs it), created read view rc_customers, analyzed customers
New ScalarDB table: customer.customers.
ScalarDB transactions may write customer.customers from <date> <time>, or after every application using the driver on this database has restarted.
customer.customers: set up, no rows stuck
```

- `backfill skipped`: the sample data was written before the import, so its ScalarDB metadata columns
  are empty. SNJ and ScalarDB read such rows as committed, so this is fine here. The sample's rows were
  read and updated through both SNJ (add-stock) and the PostgreSQL Frontend (orders, cancel) in
  testing.
- The time on the third line is 60 seconds after the setup. It matters only when applications that use
  the driver already run on the database. See [SNJ_NO_WAIT=0](#adding-a-table-while-applications-run).
- `set up, no rows stuck` is the result of `check`. You get one line per table.

## Running it again

You can run the script again at any time. What exists is kept. A second run prints:

```text
== 2. import into ScalarDB, coordinator
java.lang.IllegalArgumentException: DB-CORE-10052: The table already exists. Table: customer.customers
...
[main] WARN com.scalar.db.schemaloader.SchemaOperator - The coordinator tables already exist
== 3. ScalarDB Native JDBC setup
customer.customers: backfill skipped (--backfill runs it), replaced read view rc_customers, analyzed customers
customer.customers: set up, no rows stuck
...
setup-db OK. ...
```

`DB-CORE-10052` here only means that the table was imported before. The script imports one table at a
time, so that one already imported does not stop the others. The sample data is skipped on a second
run.

## Starting again: drop-db.sh

```sh
setup/drop-db.sh          # asks first; setup/drop-db.sh --yes does not ask
setup/setup-db.sh
```

`drop-db.sh` uses the same `setup/db.env`. **It drops the sample's tables with all their rows**, and
keeps the databases:

1. `scalardb-native-tools teardown` for each table: drops the read view and the in-flight index. On
   PostgreSQL the view depends on the table, so this comes first.
2. The Schema Loader drops the tables and the coordinator table. The schema it needs is built from
   `scalardb.metadata`.

It prints `drop-db OK`. A table that is not in ScalarDB is skipped, so it can be run again.

A running ScalarDB Cluster keeps the tables' metadata in its cache. After `setup-db.sh` makes the
tables again, restart the Cluster. With Helm, restart the node's deployment, for example
`kubectl rollout restart deployment/scalardb-cluster-node` (the name depends on the Helm release).

## Adding a table while applications run

`setup-db.sh` passes `--no-wait` to the setup, which then returns at once. That is right for new
databases that no application uses yet.

When applications that use the driver already run on the database, as when you add a table later:

1. run `SNJ_NO_WAIT=0 setup/setup-db.sh`. The setup then waits 60 seconds before it returns.
2. let ScalarDB transactions write the new table only after that.

The driver keeps a cache of the ScalarDB tables for 60 seconds. See SNJ's documentation,
[Adding a table to ScalarDB while applications run](https://github.com/scalar-labs/scalardb-native-jdbc/blob/main/docs/setting-up-tables.md#adding-a-table-to-scalardb-while-applications-run).

## Checking the result

To list the tables in each database:

```sh
psql -h <host> -p <port> -U <user> -d db_ordering -c \
  "SELECT table_schema, table_name, table_type FROM information_schema.tables
   WHERE table_schema NOT IN ('pg_catalog', 'information_schema') ORDER BY 1, 2"
```

| Database | Tables and views |
|---|---|
| `db_customer` | `customer.customers`, `customer.rc_customers` (view), `scalardb.metadata` |
| `db_inventory` | `inventory.items`, `inventory.rc_items` (view), `scalardb.metadata` |
| `db_ordering` | `ordering.orders`, `ordering.statements`, `ordering.rc_orders` (view), `ordering.rc_statements` (view), `scalardb.metadata`, `coordinator.state` |

## Doing it by hand

These commands do the same as the script. Run them from the root of the repository, with the tools in
`.tools/`. Download the tools from these release pages:

- the Schema Loader: [ScalarDB v3.20.0](https://github.com/scalar-labs/scalardb/releases/tag/v3.20.0)
- `scalardb-native-tools`: [ScalarDB Native JDBC v3.20.0](https://github.com/scalar-labs/scalardb-native-jdbc/releases/tag/v3.20.0)

```sh
# 1. the tables (and the same for inventory and ordering), and the sample data (customer and inventory)
psql -h <host> -p <port> -U <user> -d db_customer -f schema/customer.sql
psql -h <host> -p <port> -U <user> -d db_customer -f schema/seed/customer.sql

# 2. write the settings of step 2 above to schema-loader.properties (chmod 600, it holds the password)
echo '{}' > /tmp/empty.json
java -jar .tools/scalardb-schema-loader-3.20.0.jar --config schema-loader.properties \
  --schema-file schema/import.json --import
java -jar .tools/scalardb-schema-loader-3.20.0.jar --config schema-loader.properties \
  --schema-file /tmp/empty.json --coordinator

# 3. SNJ's setup and check (and the same for db_inventory and db_ordering)
export SCALARDB_NATIVE_PASSWORD='<password>'
.tools/scalardb-native-tools-3.20.0/bin/scalardb-native-tools setup \
  jdbc:scalardb-native:postgresql://<host>:<port>/db_customer -U <user> --no-wait
.tools/scalardb-native-tools-3.20.0/bin/scalardb-native-tools check \
  jdbc:scalardb-native:postgresql://<host>:<port>/db_customer -U <user>
```

Notes on doing it by hand:

- `--import` with all of `schema/import.json` stops at the first table that is already imported. On a
  second run, import one table at a time, as the script does.
- Delete `schema-loader.properties` when you are done.

## Troubleshooting

- **`password authentication failed`:** step 1 fails at `psql`, before ScalarDB is used. Check
  `DB_USER` and `DB_PASSWORD` in `setup/db.env`.
- **`jq: command not found`:** install `jq`. Step 2 uses it to import one table at a time.
- **Collation:** the script does not check it. The PostgreSQL Frontend requires collation C, so check
  it before you go on:

  ```sh
  psql -h <host> -p <port> -U <user> -d db_customer -c \
    "SELECT datname, datcollate FROM pg_database WHERE datname LIKE 'db_%'"
  ```

  If it is not `C`, make the database again as in [README step 1](../README.md#1-create-the-databases).
