# demo-snj-pgfe-samples

A Spring Boot sample that uses two ways to run ScalarDB transactions from SQL, each where it fits:

- **A transaction in one database → ScalarDB Native JDBC (SNJ).** It runs as a local transaction of
  that database, with the database's own SQL. The tables are ScalarDB tables. The SNJ driver keeps
  its transactions consistent with ScalarDB's transactions on the same rows.
- **A transaction across databases → the PostgreSQL Frontend (PGFE) of ScalarDB Cluster.** It runs
  as one ScalarDB transaction (Consensus Commit) over all the databases, with PostgreSQL's SQL.

The data is split over three PostgreSQL databases, one per namespace:

| Database | Tables |
|---|---|
| `db_customer` | `customer.customers` |
| `db_inventory` | `inventory.items` |
| `db_ordering` | `ordering.orders`, `ordering.statements` (and ScalarDB's coordinator table) |

| Operation | Databases | Runs through | Transaction |
|---|---|---|---|
| CRUD of each table (`/customer-customers`, `/inventory-items`, `/ordering-orders`, `/ordering-statements`) | one | SNJ, that database's DataSource | `customerTx`, `inventoryTx`, `orderingTx` |
| Add stock, for a delivery (`POST /inventory-items/{id}/add-stock?qty=`) | `db_inventory` | SNJ | `inventoryTx` |
| Place an order (`POST /orders`): reduce stock, charge the customer, write the order and its lines | all three | PGFE | `pgfeTx` |
| Cancel an order (`POST /orders/{id}/cancel`), read orders (`GET /orders/{id}`, `GET /customers/{id}/orders`) | all three | PGFE | `pgfeTx` |

Both kinds of transaction write the same rows. For example, adding stock (SNJ) and placing an order
(PGFE) can update the same item at the same time, and neither update is lost
([Try it on one machine](#try-it-on-one-machine) checks this).

```mermaid
flowchart LR
  app["Spring Boot (this sample)"]
  cluster["ScalarDB Cluster<br/>PostgreSQL Frontend"]
  subgraph dbs["PostgreSQL"]
    c["db_customer"]
    i["db_inventory"]
    o["db_ordering"]
  end
  app -- "SNJ: customerTx" --> c
  app -- "SNJ: inventoryTx" --> i
  app -- "SNJ: orderingTx" --> o
  app -- "PGFE: pgfeTx" --> cluster
  cluster --> c
  cluster --> i
  cluster --> o
```

## How the code shows the choice

- `config/DataSourceConfig.java` makes four DataSources: three for SNJ
  (`jdbc:scalardb-native:postgresql://…`, one per database) and one for PGFE
  (`jdbc:postgresql://<cluster>:5439/…`). Each DataSource gets a `TransactionRunner`:
  `customerTx`, `inventoryTx`, `orderingTx` and `pgfeTx`. Each DataSource also gets its own instances
  of the repositories (`customersSnj` … and `customersPgfe` …).
- A service picks its runner and repositories with `@Qualifier`:
  - `InventoryItemsService` uses `inventoryTx` and `itemsSnj`.
  - `OrderService` uses `pgfeTx` and the `*Pgfe` repositories.
- The repositories and their SQL are the same for both. Through SNJ, the SQL goes to PostgreSQL
  unchanged. Through PGFE, ScalarDB runs it.
- `TransactionRunner` retries a transaction that failed with a conflict (SQLSTATE 40001), a deadlock
  or a lock timeout (`retry.*` in `application.properties`).
  - PGFE often reports ScalarDB's conflicts at `COMMIT`. A refused commit is rolled back, so it is
    retried too.
  - Any other failure of the commit is reported as 9200 (the outcome is unknown) and is not retried.
    This includes SQLSTATE 40003.
- Everything runs in READ COMMITTED: the sample's connections and ScalarDB's transactions in the
  Cluster. SNJ requires the same isolation level on both sides.

## What you need

- JDK 25 (the Gradle toolchain), `psql`, `curl`, `unzip` and `jq`
- Three PostgreSQL databases, `db_customer`, `db_inventory` and `db_ordering`:
  - each created with collation C (the PostgreSQL Frontend requires it);
  - owned by one user;
  - on one server or on three.
- **ScalarDB Cluster** 3.20 with the PostgreSQL Frontend on (`scalar.db.postgres.enabled=true`) and
  its license. Setting up the Cluster is not part of this sample. You add the three databases to it in
  step 3.

To try everything on one machine with docker, see [Try it on one machine](#try-it-on-one-machine).

## 1. Create the databases

On each PostgreSQL server, as a superuser:

```sql
CREATE DATABASE db_customer  OWNER <user> LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0;
CREATE DATABASE db_inventory OWNER <user> LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0;
CREATE DATABASE db_ordering  OWNER <user> LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0;
```

## 2. Make the tables and set them up

```sh
cp setup/db.env.example setup/db.env && chmod 600 setup/db.env   # then fill in hosts, ports, user, password
setup/setup-db.sh
```

`setup-db.sh` makes the tables (`schema/<db>.sql`), puts in some sample data, imports the tables into
ScalarDB with the Schema Loader, and runs SNJ's setup in each database. It ends with `setup-db OK`.
**It connects only to the three databases. ScalarDB Cluster is not needed for this step.** You can run
it again at any time.

The sample data: customers 1 to 3 (`alice`, `bob`, `carol`) and items 1 to 5 (`pen`, `notebook`,
`eraser`, `ruler`, `stapler`), with no orders. It goes in only the first time, before the tables are
imported. `SEED=0 setup/setup-db.sh` leaves it out.

To start again from empty tables, run `setup/drop-db.sh`. It drops the tables and their rows, and the
databases are kept. Then run `setup-db.sh` again, and restart ScalarDB Cluster, which keeps the old
tables' metadata in its cache.

What each step does, the settings, the output and how to do it by hand: [setup/README.md](setup/README.md).

After this, write to these tables only through SNJ or ScalarDB. Plain `psql` would bypass both, so
use it only to read.

## 3. Add the databases to ScalarDB Cluster, and restart it

The Cluster has to know the three databases. This takes two additions to the Cluster node's
properties:

- **storages:** the three databases, as storages of ScalarDB's multi-storage.
- **namespaces:** each namespace mapped to its database.

The Cluster also needs three more settings for this sample (C to E below). All the lines are in
[`cluster/multi-storage.properties.example`](cluster/multi-storage.properties.example).

### A. Storages

```properties
scalar.db.storage=multi-storage
scalar.db.multi_storage.storages=customer,inventory,ordering

scalar.db.multi_storage.storages.customer.storage=jdbc
scalar.db.multi_storage.storages.customer.contact_points=jdbc:postgresql://<customer-db-host>:5432/db_customer
scalar.db.multi_storage.storages.customer.username=<user>
scalar.db.multi_storage.storages.customer.password=${env:DB_PASSWORD_CUSTOMER}
# ... the same four lines for inventory and ordering
```

`${env:DB_PASSWORD_CUSTOMER}` reads an environment variable of the Cluster node. With Helm, put the
three passwords in a Kubernetes Secret, with the keys `DB_PASSWORD_CUSTOMER`, `DB_PASSWORD_INVENTORY`
and `DB_PASSWORD_ORDERING`. Then name the Secret in `scalardbCluster.secretName`. The chart passes
each key of the Secret to the node as an environment variable.

### B. Namespaces

```properties
scalar.db.multi_storage.namespace_mapping=customer:customer,inventory:inventory,ordering:ordering,coordinator:ordering
scalar.db.multi_storage.default_storage=ordering
```

`coordinator:ordering` puts ScalarDB's coordinator table in `db_ordering`. Step 2 made it there with the
same mapping.

### C. Isolation level

The settings when `scalar.db.consensus_commit.isolation_level` is `READ_COMMITTED` (this sample) are
as follows:

```properties
scalar.db.transaction_manager=consensus-commit
scalar.db.consensus_commit.isolation_level=READ_COMMITTED
scalar.db.multi_storage.storages.customer.jdbc.isolation_level=REPEATABLE_READ
scalar.db.multi_storage.storages.inventory.jdbc.isolation_level=REPEATABLE_READ
scalar.db.multi_storage.storages.ordering.jdbc.isolation_level=REPEATABLE_READ
```

- `scalar.db.consensus_commit.isolation_level` is the isolation level of ScalarDB's transactions. SNJ
  requires it to match the level of the driver's connections (READ COMMITTED in this sample). It
  applies to the whole Cluster, so it applies to other applications on the same Cluster too.
- `jdbc.isolation_level` is the isolation level of ScalarDB's own connections to each database. Its
  value depends on the isolation level above, and on the database. For other isolation levels, see
  [Isolation levels](https://github.com/scalar-labs/scalardb-native-jdbc/blob/main/docs/transactions.md#isolation-levels)
  in SNJ's documentation.
- It is set for each storage, so that it does not change the Cluster's other storages.

### D. Cross-partition scans

```properties
scalar.db.multi_storage.storages.customer.cross_partition_scan.enabled=true
scalar.db.multi_storage.storages.customer.cross_partition_scan.filtering.enabled=true
scalar.db.multi_storage.storages.customer.cross_partition_scan.ordering.enabled=true
# ... the same three lines for inventory and ordering
```

The sample reads orders by customer and order lines by order through the PostgreSQL Frontend. These
reads do not give the whole primary key. Without these lines, they fail with
`DB-CORE-10008: Cross-partition scan filtering is not enabled`.

### E. Where to put the lines, and restart

- **With Helm:** put the lines in `scalardbCluster.scalardbClusterNodeProperties` in the custom
  values, and run `helm upgrade` with the changed values.
- **Without Helm:** put them in the node's `scalardb-cluster-node.properties`, and restart the node.

A running Cluster does not pick up new storages, so the restart is needed.

How to add the lines depends on the Cluster's current settings:

- **If the Cluster already uses multi-storage:**
  - add `customer,inventory,ordering` to its `scalar.db.multi_storage.storages`;
  - add the three mappings (not `coordinator`) to its `namespace_mapping`;
  - keep its own `default_storage` and its coordinator.
- **If the Cluster uses one storage (`scalar.db.storage=jdbc`):**
  - switch it to multi-storage;
  - keep the existing database as one more storage;
  - map its namespaces and the coordinator to it, and make it the `default_storage`.

The Cluster also needs the PostgreSQL Frontend on (`scalar.db.postgres.enabled=true`), as for any use
of it.

### Check

After the restart, connect to the PostgreSQL Frontend and read one table in each database:

```sh
psql -h <cluster-host> -p 5439 -U <user> -d ordering -c "SELECT count(*) FROM customer.customers"
psql -h <cluster-host> -p 5439 -U <user> -d ordering -c "SELECT count(*) FROM inventory.items"
psql -h <cluster-host> -p 5439 -U <user> -d ordering -c "SELECT count(*) FROM ordering.orders"
```

Each prints a count (0 at first). The user and password are those of the Cluster: any, if the
Cluster has no authentication.

## 4. Run the sample

```sh
cp src/main/resources/application-local.properties.example src/main/resources/application-local.properties
chmod 600 src/main/resources/application-local.properties   # then fill in the four URLs, users and passwords
./gradlew bootRun
```

At start-up, the sample connects through each DataSource and logs what each one reached. The API
listens on port 8080; Swagger UI is at `http://localhost:8080/swagger-ui.html`.

```sh
B=http://localhost:8080
# one database (SNJ)
curl -s $B/customer-customers/1          # alice, from the sample data
curl -s $B/inventory-items/1             # pen
curl -s -X POST "$B/inventory-items/1/add-stock?qty=5"
# across the databases (PGFE)
curl -s -X POST $B/orders -H 'Content-Type: application/json' \
  -d '{"customer_id":1,"items":[{"item_id":1,"qty":3}]}'
curl -s $B/customers/1/orders
curl -s -X POST $B/orders/<order_id>/cancel
```

`local/try.sh [base-url]` runs a set of these calls and checks the results. It then sends add-stock
and orders for the same item at the same time and checks that the stock and the credit add up. It
ends with `try OK`.

Errors use the same codes as the other samples:

| Code | Meaning | HTTP status |
|---|---|---|
| 9100 | condition not met | 400 |
| 9200 | commit outcome unknown | 500 |
| 9300 | database or transaction failure, after the retries | 500 |
| 9400 | bad request | 400 |
| 9700 | not found | 404 |
| 9800 | credit limit exceeded | 409 |
| 9801 | out of stock | 409 |
| 9802 | order not cancellable | 409 |

## Try it on one machine

`local/local.sh` runs steps 1 to 3 against docker containers on one machine:

- three PostgreSQL 16 containers;
- one ScalarDB Cluster node in standalone mode, with the PostgreSQL Frontend.

It also writes `application-local.properties` for them. You need docker and a ScalarDB Cluster
license:

```sh
export CLUSTER_LICENSE_KEY='<license key>'
export LICENSE_CHECK_CERT_PEM='<license check certificate>'
local/local.sh up                 # containers snjpgfe-*, PostgreSQL Frontend on localhost:15439
./gradlew bootRun                 # in another terminal
local/try.sh                      # ends with "try OK"
local/local.sh down               # removes the containers
```

`local/local.sh` makes the database password at random and keeps it in `local/.local.env`
(mode 600, not in git). It passes the license to the container as environment variables and does not
write it to any file.

## Notes

- When the same row is updated from both sides at once, the PGFE transactions are usually the ones
  that are retried. SNJ takes the database's row lock and waits. PGFE (Consensus Commit) checks for
  conflicts when it commits, and the one that loses is retried. When an SNJ statement meets a row
  that a ScalarDB transaction is writing, it fails with "a row the statement locks is being written by
  a ScalarDB transaction; roll the transaction back and retry it", and `TransactionRunner` retries it.
  With many requests on one row, some fail after `retry.max-attempts` (3).
- Tables that ScalarDB does not manage can also sit in these databases. SNJ passes statements on them
  through unchanged, inside the same local transaction. The sample does not use any.
- Adding a table to ScalarDB later while applications run:
  1. run `SNJ_NO_WAIT=0 setup/setup-db.sh`, so that SNJ's setup waits before it returns;
  2. let ScalarDB transactions write the new table only after the time the setup prints (60 s later).

  See SNJ's documentation, "Adding a table to ScalarDB while applications run".
- Tested with ScalarDB Cluster 3.20.1 (standalone, in docker), ScalarDB Native JDBC 3.20.0, the
  Schema Loader 3.20.0 and PostgreSQL 16.
