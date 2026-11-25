# common.sh - shared by setup-db.sh and drop-db.sh (sourced, not run).
# Reads setup/db.env (or DB_ENV), downloads the tools into .tools/, and writes the Schema Loader's
# settings: the same storages and namespace mapping as cluster/multi-storage.properties.example.

HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
ENVF=${DB_ENV:-$HERE/db.env}
[ -f "$ENVF" ] || { echo "no $ENVF (copy setup/db.env.example)" >&2; exit 1; }
. "$ENVF"
: "${DB_USER:?}" "${DB_PASSWORD:?}" "${CUSTOMER_DB_HOST:?}" "${INVENTORY_DB_HOST:?}" "${ORDERING_DB_HOST:?}"
DBS="customer inventory ordering"
host() { local v="${1^^}_DB_HOST"; echo "${!v}"; }
port() { local v="${1^^}_DB_PORT"; echo "${!v:-5432}"; }
# psql on db_<name>, quiet; arguments are passed on
psql_db() { local db=$1; shift
  PGPASSWORD="$DB_PASSWORD" PGOPTIONS="-c client_min_messages=warning" psql -q -v ON_ERROR_STOP=1 \
    -h "$(host "$db")" -p "$(port "$db")" -U "$DB_USER" -d "db_$db" "$@"; }
snj_url() { echo "jdbc:scalardb-native:postgresql://$(host "$1"):$(port "$1")/db_$1"; }
# the tables of schema/import.json in the namespace <name>
tables_of() { jq -r --arg ns "$1" 'keys[] | select(startswith($ns + "."))' "$ROOT/schema/import.json"; }
# whether the table <namespace.table> is imported into ScalarDB in db_<name>
imported() {
  [ "$(psql_db "$1" -At -c "SELECT to_regclass('scalardb.metadata') IS NOT NULL")" = t ] &&
  [ "$(psql_db "$1" -At -c "SELECT count(*) FROM scalardb.metadata WHERE full_table_name = '$2'")" != 0 ]
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

# The Schema Loader's settings, in a temporary file (mode 600, it holds the password) deleted at exit.
# $P = the settings, $E = a scratch schema file.
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
