#!/usr/bin/env bash
# setup-db-oracle.sh - setup-db.sh for Oracle: the same three steps, in one Oracle database where the
# three namespaces are three schemas.
#
#   1. the schemas and tables: schema/oracle/tables.sql (sqlplus), and the sample data
#      schema/oracle/seed.sql, only while no table is imported into ScalarDB yet
#   2. import the tables into ScalarDB, and the coordinator table (ScalarDB Schema Loader)
#   3. ScalarDB Native JDBC's setup in the database (scalardb-native-tools setup, then check)
#
# Settings: setup/oracle/db-oracle.env (from db-oracle.env.example). Needs sqlplus (Instant Client),
# java (17 or later), curl, unzip and jq. The Schema Loader and scalardb-native-tools 3.20.0 are
# downloaded into .tools/ the first time. Every step can be run again.
# SEED=0: no sample data. SNJ_NO_WAIT=0: let SNJ's setup wait before it returns (see setup-db.sh).
# ORA_SQLPLUS_HOST / ORA_SQLPLUS_PORT: where sqlplus connects, if not ORA_HOST / ORA_PORT (e.g. inside a
# container: localhost 1521).
set -euo pipefail
HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
ENVF=${DB_ENV:-$HERE/db-oracle.env}
[ -f "$ENVF" ] || { echo "no $ENVF (copy setup/oracle/db-oracle.env.example)" >&2; exit 1; }
. "$ENVF"
: "${ORA_HOST:?}" "${ORA_PORT:?}" "${ORA_SERVICE:?}" "${ORA_USER:?}" "${ORA_PASSWORD:?}"
SQLPLUS=${SQLPLUS:-sqlplus}
SQ_HOST=${ORA_SQLPLUS_HOST:-$ORA_HOST}; SQ_PORT=${ORA_SQLPLUS_PORT:-$ORA_PORT}

# sqlplus on the database: the connection comes on stdin, so the password is not on a command line
sql() { { printf 'WHENEVER SQLERROR EXIT FAILURE\nCONNECT %s/"%s"@//%s:%s/%s\n' \
            "$ORA_USER" "$ORA_PASSWORD" "$SQ_HOST" "$SQ_PORT" "$ORA_SERVICE"; cat; echo; echo EXIT; } \
          | $SQLPLUS -s -L /nolog; }
# whether any of the sample's tables is imported into ScalarDB (ScalarDB's metadata in "scalardb")
any_imported() {
  local n
  n=$(printf '%s\n' "SET HEADING OFF FEEDBACK OFF PAGESIZE 0" \
    "DECLARE n NUMBER := 0; BEGIN" \
    "  EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM \"scalardb\".\"metadata\" WHERE \"full_table_name\" IN (''customer.customers'', ''inventory.items'', ''ordering.orders'', ''ordering.statements'')' INTO n;" \
    "  DBMS_OUTPUT.PUT_LINE('n=' || n);" \
    "EXCEPTION WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('n=0'); END;" "/" \
    | sed '1i SET SERVEROUTPUT ON' | sql | sed -n 's/^n=//p')
  [ "${n:-0}" != 0 ]
}

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
JDBC_URL="jdbc:oracle:thin:@//$ORA_HOST:$ORA_PORT/$ORA_SERVICE"
SNJ_URL="jdbc:scalardb-native:oracle:thin:@//$ORA_HOST:$ORA_PORT/$ORA_SERVICE"

# The Schema Loader's settings (mode 600, the password) and a scratch file, deleted at exit.
# One storage is enough here: the three namespaces are in one database. Oracle refuses REPEATABLE READ,
# so the storage's connections use SERIALIZABLE (cluster/multi-storage-oracle.properties.example).
P=$(mktemp); chmod 600 "$P"; E=$(mktemp)
trap 'rm -f "$P" "$E"' EXIT
{ echo "scalar.db.transaction_manager=consensus-commit"
  echo "scalar.db.consensus_commit.isolation_level=READ_COMMITTED"
  echo "scalar.db.storage=jdbc"
  echo "scalar.db.contact_points=$JDBC_URL"
  echo "scalar.db.username=$ORA_USER"
  echo "scalar.db.password=${ORA_PASSWORD//"\\"/"\\\\"}"
  echo "scalar.db.jdbc.isolation_level=SERIALIZABLE"; } > "$P"
loader() { java -jar "$SL_JAR" --config "$P" "$@" 2>&1 | grep -E 'succeeded|already|ERROR|Exception' | grep -v -i password || true; }

echo "== 1. schemas and tables"
sql < "$ROOT/schema/oracle/tables.sql" | grep -v '^\s*$' || true
echo "schema/oracle/tables.sql"
if [ "${SEED:-1}" = 0 ]; then
  echo "sample data: skipped (SEED=0)"
elif any_imported; then
  echo "sample data skipped (the tables are already imported into ScalarDB)"
else
  sql < "$ROOT/schema/oracle/seed.sql" | grep -v '^\s*$' || true
  echo "sample data, schema/oracle/seed.sql"
fi

echo "== 2. import into ScalarDB, coordinator"
for t in $(jq -r 'keys[]' "$ROOT/schema/import.json"); do
  jq --arg t "$t" '{($t): .[$t]}' "$ROOT/schema/import.json" > "$E"
  loader --schema-file "$E" --import
done
echo '{}' > "$E"
loader --schema-file "$E" --coordinator

echo "== 3. ScalarDB Native JDBC setup"
NOWAIT=--no-wait; [ "${SNJ_NO_WAIT:-1}" = 0 ] && NOWAIT=
SCALARDB_NATIVE_PASSWORD="$ORA_PASSWORD" "$SNJ" setup "$SNJ_URL" -U "$ORA_USER" ${NOWAIT} | grep -v '^$' || true
SCALARDB_NATIVE_PASSWORD="$ORA_PASSWORD" "$SNJ" check "$SNJ_URL" -U "$ORA_USER"
echo "setup-db-oracle OK. Next: add the database to ScalarDB Cluster (cluster/multi-storage-oracle.properties.example) and restart it."
