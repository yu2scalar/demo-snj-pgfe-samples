#!/usr/bin/env bash
# local.sh up|down|status - try the sample on one machine with docker: three PostgreSQL containers
# (db_customer, db_inventory, db_ordering) and one ScalarDB Cluster node with the PostgreSQL Frontend.
# For a real Cluster, follow README.md instead; this script runs the same steps against containers.
#
#   up      start the containers, run setup/setup-db.sh, start the Cluster node, and write
#           src/main/resources/application-local.properties for them
#   status  the containers
#   down    remove the containers and the network (the data goes too)
#
# Needs docker, psql, java, curl, unzip, and in the environment:
#   CLUSTER_LICENSE_KEY, LICENSE_CHECK_CERT_PEM   your ScalarDB Cluster license (key and certificate)
# Optional: CLUSTER_IMAGE (ghcr.io/scalar-labs/scalardb-cluster-node-byol-premium:3.20.1),
#   PG_IMAGE (postgres:16), host ports PG_PORT_BASE (15441: customer, +1 inventory, +2 ordering), PGFE_PORT (15439).
# The database password is made at random and kept in local/.local.env (mode 600, not in git).
set -euo pipefail
HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
P=snjpgfe; NET=$P-net
CLUSTER_IMAGE=${CLUSTER_IMAGE:-ghcr.io/scalar-labs/scalardb-cluster-node-byol-premium:3.20.1}
PG_IMAGE=${PG_IMAGE:-postgres:16}
PG_PORT_BASE=${PG_PORT_BASE:-15441}; PGFE_PORT=${PGFE_PORT:-15439}
DBS="customer inventory ordering"
ENVF=$HERE/.local.env

wait_pg() { local i; for i in $(seq 60); do docker exec "$1" pg_isready -U postgres -q 2>/dev/null && return 0; sleep 1; done; return 1; }

up() {
  : "${CLUSTER_LICENSE_KEY:?set your ScalarDB Cluster license key}" "${LICENSE_CHECK_CERT_PEM:?set the license check certificate}"
  if [ ! -f "$ENVF" ]; then
    (umask 077; printf 'export PG_SUPER_PASSWORD=%s\nexport DB_PASSWORD=%s\n' "$(openssl rand -hex 12)" "$(openssl rand -hex 12)" > "$ENVF")
  fi
  . "$ENVF"; export DB_PASSWORD
  docker network inspect $NET >/dev/null 2>&1 || docker network create $NET >/dev/null
  local port=$PG_PORT_BASE db
  for db in $DBS; do
    docker run -d --name $P-pg-$db --network $NET -p $port:5432 -e POSTGRES_PASSWORD="$PG_SUPER_PASSWORD" "$PG_IMAGE" >/dev/null
    port=$((port + 1))
  done
  for db in $DBS; do
    wait_pg $P-pg-$db; sleep 2; wait_pg $P-pg-$db   # the image restarts the server once after initializing
    printf "CREATE ROLE app LOGIN PASSWORD '%s';\nCREATE DATABASE db_%s OWNER app LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0;\n" \
      "$DB_PASSWORD" "$db" | docker exec -i $P-pg-$db psql -q -v ON_ERROR_STOP=1 -U postgres
    echo "$P-pg-$db: db_$db"
  done

  local dbenv; dbenv=$(mktemp); chmod 600 "$dbenv"
  { port=$PG_PORT_BASE
    for db in $DBS; do echo "export ${db^^}_DB_HOST=localhost"; echo "export ${db^^}_DB_PORT=$port"; port=$((port + 1)); done
    echo "export DB_USER=app"; printf 'export DB_PASSWORD=%q\n' "$DB_PASSWORD"; } > "$dbenv"
  DB_ENV=$dbenv "$ROOT/setup/setup-db.sh"; rm -f "$dbenv"

  # The Cluster node: cluster/multi-storage.properties.example with the containers' names, plus the
  # standalone mode, the PostgreSQL Frontend and the license (from the environment, not written here).
  local props=$HERE/.cluster-node.properties
  { echo "scalar.db.cluster.node.standalone_mode.enabled=true"
    echo "scalar.db.cluster.node.licensing.license_key=\${env:CLUSTER_LICENSE_KEY}"
    echo "scalar.db.cluster.node.licensing.license_check_cert_pem=\${env:LICENSE_CHECK_CERT_PEM}"
    echo "scalar.db.postgres.enabled=true"
    echo "scalar.db.postgres.port=5439"
    echo "scalar.db.postgres.ssl.require=false"
    sed -e '/^#/d' -e '/^$/d' \
        -e "s|<\([a-z]*\)-db-host>:5432|$P-pg-\1:5432|" -e 's|<user>|app|' \
        -e 's|\${env:DB_PASSWORD_[A-Z]*}|${env:DB_PASSWORD}|' "$ROOT/cluster/multi-storage.properties.example"; } > "$props"
  docker run -d --name $P-cluster --network $NET -p $PGFE_PORT:5439 \
    -e CLUSTER_LICENSE_KEY -e LICENSE_CHECK_CERT_PEM -e DB_PASSWORD \
    -v "$props":/scalardb-cluster/node/scalardb-cluster-node.properties:ro "$CLUSTER_IMAGE" >/dev/null
  local i
  for i in $(seq 120); do
    docker logs $P-cluster 2>&1 | grep -q 'PostgreSQL frontend listening' && break
    [ "$(docker inspect -f '{{.State.Running}}' $P-cluster)" = true ] || { docker logs --tail 30 $P-cluster >&2; echo "the Cluster node stopped" >&2; exit 1; }
    sleep 1
  done
  echo "$P-cluster: PostgreSQL Frontend on localhost:$PGFE_PORT"

  local app=$ROOT/src/main/resources/application-local.properties
  (umask 077
   { port=$PG_PORT_BASE
     for db in $DBS; do
       echo "app.datasource.$db.jdbc-url=jdbc:scalardb-native:postgresql://localhost:$port/db_$db"
       echo "app.datasource.$db.username=app"; echo "app.datasource.$db.password=$DB_PASSWORD"; port=$((port + 1))
     done
     echo "app.datasource.pgfe.jdbc-url=jdbc:postgresql://localhost:$PGFE_PORT/ordering"
     echo "app.datasource.pgfe.username=app"; echo "app.datasource.pgfe.password=unused"; } > "$app")
  echo "local up OK: wrote $app. Next: ./gradlew bootRun"
}

status() { docker ps -a --filter "name=^$P-" --format '{{.Names}}  {{.Status}}  {{.Ports}}'; }

down() {
  docker rm -f $P-cluster $P-pg-customer $P-pg-inventory $P-pg-ordering >/dev/null 2>&1 || true
  docker network rm $NET >/dev/null 2>&1 || true
  rm -f "$ENVF" "$HERE/.cluster-node.properties"
  echo "local down OK (src/main/resources/application-local.properties is kept)"
}

case "${1:-}" in
  up) up ;; status) status ;; down) down ;;
  *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
