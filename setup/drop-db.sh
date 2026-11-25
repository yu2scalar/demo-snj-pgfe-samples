#!/usr/bin/env bash
# drop-db.sh - the reverse of setup-db.sh: drop the sample's tables, with their data, from the three
# databases, so that setup-db.sh can make them again. The databases themselves are kept.
#
#   1. ScalarDB Native JDBC's teardown in each database (drops the read views and the in-flight indexes;
#      on PostgreSQL the views depend on the tables, so this comes first)
#   2. the Schema Loader drops the tables of schema/import.json and the coordinator table
#
# Settings: setup/db.env, as for setup-db.sh. It asks before it drops anything; --yes does not ask.
# A running ScalarDB Cluster keeps the tables' metadata in its cache: restart it after you make the
# tables again (README.md, step 3).
set -euo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

if [ "${1:-}" != --yes ]; then
  echo "This drops the sample's tables and all their rows from:"
  for db in $DBS; do echo "  db_$db on $(host $db):$(port $db)"; done
  read -r -p "Type yes to go on: " a
  [ "$a" = yes ] || { echo "nothing dropped"; exit 1; }
fi

echo "== 1. ScalarDB Native JDBC teardown"
for db in $DBS; do
  for t in $(tables_of $db); do
    imported $db "$t" || { echo "$t: not in ScalarDB, skipped"; continue; }
    SCALARDB_NATIVE_PASSWORD="$DB_PASSWORD" "$SNJ" teardown "$(snj_url $db)" -U "$DB_USER" --table "$t" | grep -v '^$' || true
  done
done

echo "== 2. drop the tables and the coordinator table"
# The Schema Loader needs each table's keys and columns to drop it. schema/import.json has only the
# names (the tables were imported), so the schema to drop is built from ScalarDB's own metadata.
for db in $DBS; do
  for t in $(tables_of $db); do
    imported $db "$t" || continue
    rows=$(psql_db $db -At -F ' ' -c "SELECT column_name, data_type, COALESCE(key_type, '') FROM scalardb.metadata
      WHERE full_table_name = '$t' ORDER BY ordinal_position")
    echo "$rows" | jq -R -s --arg t "$t" '[split("\n")[] | select(. != "") | split(" ")] as $r | {($t): {
        "transaction": true,
        "partition-key": [$r[] | select(.[2] == "PARTITION") | .[0]],
        "clustering-key": [$r[] | select(.[2] == "CLUSTERING") | .[0]],
        "columns": ([$r[] | {(.[0]): .[1]}] | add)}}' > "$E"
    loader --schema-file "$E" --delete-all
  done
done
echo '{}' > "$E"
loader --schema-file "$E" --delete-all --coordinator
echo "drop-db OK. Next: setup/setup-db.sh, then restart ScalarDB Cluster."
