#!/usr/bin/env bash
# setup-db.sh - make the sample's tables in the three databases and set them up for ScalarDB and
# ScalarDB Native JDBC. Run it before adding the databases to ScalarDB Cluster (README.md, step 2).
#
#   1. the tables: schema/<db>.sql in each database (plain PostgreSQL DDL, psql)
#      and the sample data: schema/seed/<db>.sql, only into a table not imported into ScalarDB yet
#   2. import them into ScalarDB, and the coordinator table in db_ordering (ScalarDB Schema Loader, with
#      the same storages and namespace mapping as cluster/multi-storage.properties.example)
#   3. ScalarDB Native JDBC's setup in each database (scalardb-native-tools setup, then check)
#
# Settings: setup/db.env (from setup/db.env.example). Needs psql, java (17 or later), curl, unzip and jq.
# The Schema Loader and scalardb-native-tools 3.20.0 are downloaded into .tools/ the first time.
# Every step can be run again: existing tables are kept, and a table already imported is reported
# (DB-CORE-10052: the table already exists) and left as it is. The sample data goes in only the first
# time; to start again, run setup/drop-db.sh.
# SEED=0: no sample data.
# SNJ_NO_WAIT=0: let SNJ's setup wait 60 s before it returns - use it when applications that use the driver
# already run on these databases (SNJ's docs: "Adding a table to ScalarDB while applications run").
set -euo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

echo "== 1. tables"
for db in $DBS; do
  psql_db $db -f "$ROOT/schema/$db.sql"
  echo "db_$db: schema/$db.sql"
done
if [ "${SEED:-1}" = 0 ]; then
  echo "sample data: skipped (SEED=0)"
else
  for db in $DBS; do
    seed=$ROOT/schema/seed/$db.sql
    [ -f "$seed" ] || continue
    done_already=
    for t in $(tables_of $db); do imported $db "$t" && done_already=$t; done
    if [ -n "$done_already" ]; then
      echo "db_$db: sample data skipped ($done_already is already imported into ScalarDB)"
    else
      psql_db $db -f "$seed"
      echo "db_$db: sample data, schema/seed/$db.sql"
    fi
  done
fi

echo "== 2. import into ScalarDB, coordinator"
# one table at a time, so that a table already imported does not stop the others
for t in $(jq -r 'keys[]' "$ROOT/schema/import.json"); do
  jq --arg t "$t" '{($t): .[$t]}' "$ROOT/schema/import.json" > "$E"
  loader --schema-file "$E" --import
done
echo '{}' > "$E"
loader --schema-file "$E" --coordinator

echo "== 3. ScalarDB Native JDBC setup"
NOWAIT=--no-wait; [ "${SNJ_NO_WAIT:-1}" = 0 ] && NOWAIT=
for db in $DBS; do
  SCALARDB_NATIVE_PASSWORD="$DB_PASSWORD" "$SNJ" setup "$(snj_url $db)" -U "$DB_USER" ${NOWAIT} | grep -v '^$' || true
  SCALARDB_NATIVE_PASSWORD="$DB_PASSWORD" "$SNJ" check "$(snj_url $db)" -U "$DB_USER"
done
echo "setup-db OK. Next: add the databases to ScalarDB Cluster and restart it (README.md, step 3)."
