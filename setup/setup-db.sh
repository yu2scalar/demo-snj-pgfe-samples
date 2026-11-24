#!/usr/bin/env bash
# setup-db.sh - make the sample's tables in the three databases and set them up for ScalarDB and
# ScalarDB Native JDBC. Run it once, before adding the databases to ScalarDB Cluster (README.md, step 2).
#
#   1. the tables: schema/<db>.sql in each database (plain PostgreSQL DDL, psql)
#   2. import them into ScalarDB, and the coordinator table in db_ordering (ScalarDB Schema Loader, with
#      the same storages and namespace mapping as cluster/multi-storage.properties.example)
#   3. ScalarDB Native JDBC's setup in each database (scalardb-native-tools setup, then check)
#
# Settings: setup/db.env (from setup/db.env.example). Needs psql, java (17 or later), curl, unzip and jq.
# The Schema Loader and scalardb-native-tools 3.20.0 are downloaded into .tools/ the first time.
# Every step can be run again: existing tables are kept, and a table already imported is reported
# (DB-CORE-10052: the table already exists) and left as it is.
# SNJ_NO_WAIT=0: let SNJ's setup wait 60 s before it returns - use it when applications that use the driver
# already run on these databases (SNJ's docs: "Adding a table to ScalarDB while applications run").
set -euo pipefail
HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
ENVF=${DB_ENV:-$HERE/db.env}
[ -f "$ENVF" ] || { echo "no $ENVF (copy setup/db.env.example)" >&2; exit 1; }
. "$ENVF"
: "${DB_USER:?}" "${DB_PASSWORD:?}" "${CUSTOMER_DB_HOST:?}" "${INVENTORY_DB_HOST:?}" "${ORDERING_DB_HOST:?}"
DBS="customer inventory ordering"
host() { local v="${1^^}_DB_HOST"; echo "${!v}"; }
port() { local v="${1^^}_DB_PORT"; echo "${!v:-5432}"; }

TOOLS=$ROOT/.tools
SL_JAR=$TOOLS/scalardb-schema-loader-3.20.0.jar
SNJ=$TOOLS/scalardb-native-tools-3.20.0/bin/scalardb-native-tools
mkdir -p "$TOOLS"
[ -f "$SL_JAR" ] || curl -fsSL -o "$SL_JAR" \
  https://github.com/scalar-labs/scalardb/releases/download/v3.20.0/scalardb-schema-loader-3.20.0.jar
if [ ! -x "$SNJ" ]; then
  curl -fsSL -o "$TOOLS/snj-tools.zip" \
    https://github.com/scalar-labs/scalardb-native-jdbc/releases/download/v3.20.0/scalardb-native-tools-3.20.0.zip
  unzip -q -o "$TOOLS/snj-tools.zip" -d "$TOOLS" && rm -f "$TOOLS/snj-tools.zip"
fi

echo "== 1. tables"
for db in $DBS; do
  PGPASSWORD="$DB_PASSWORD" PGOPTIONS="-c client_min_messages=warning" psql -q -v ON_ERROR_STOP=1 -h "$(host $db)" -p "$(port $db)" -U "$DB_USER" \
    -d "db_$db" -f "$ROOT/schema/$db.sql"
  echo "db_$db: schema/$db.sql"
done

echo "== 2. import into ScalarDB, coordinator"
P=$(mktemp); chmod 600 "$P"; E=$(mktemp)
trap 'rm -f "$P" "$E"' EXIT
{ echo "scalar.db.transaction_manager=consensus-commit"
  echo "scalar.db.consensus_commit.isolation_level=READ_COMMITTED"
  echo "scalar.db.storage=multi-storage"
  echo "scalar.db.multi_storage.storages=customer,inventory,ordering"
  for db in $DBS; do
    echo "scalar.db.multi_storage.storages.$db.storage=jdbc"
    echo "scalar.db.multi_storage.storages.$db.contact_points=jdbc:postgresql://$(host $db):$(port $db)/db_$db"
    echo "scalar.db.multi_storage.storages.$db.username=$DB_USER"
    # a .properties file reads '\' as an escape
    echo "scalar.db.multi_storage.storages.$db.password=${DB_PASSWORD//"\\"/"\\\\"}"
    echo "scalar.db.multi_storage.storages.$db.jdbc.isolation_level=REPEATABLE_READ"
  done
  echo "scalar.db.multi_storage.namespace_mapping=customer:customer,inventory:inventory,ordering:ordering,coordinator:ordering"
  echo "scalar.db.multi_storage.default_storage=ordering"; } > "$P"
loader() { java -jar "$SL_JAR" --config "$P" "$@" 2>&1 | grep -E 'succeeded|already|ERROR|Exception' | grep -v -i password || true; }
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
  url="jdbc:scalardb-native:postgresql://$(host $db):$(port $db)/db_$db"
  SCALARDB_NATIVE_PASSWORD="$DB_PASSWORD" "$SNJ" setup "$url" -U "$DB_USER" ${NOWAIT} | grep -v '^$' || true
  SCALARDB_NATIVE_PASSWORD="$DB_PASSWORD" "$SNJ" check "$url" -U "$DB_USER"
done
echo "setup-db OK. Next: add the databases to ScalarDB Cluster and restart it (README.md, step 3)."
