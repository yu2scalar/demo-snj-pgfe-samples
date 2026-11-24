#!/usr/bin/env bash
# try.sh [base-url] - call the sample's API once through each kind of transaction, then run the
# single-database add-stock (ScalarDB Native JDBC) and the cross-database order (PostgreSQL Frontend)
# on the same item at the same time, and check that no update was lost.
#   base-url: http://localhost:8080 by default. Uses customers 901, 902 and item 901 (made or reset here).
#   Needs curl and jq. Ends with "try OK" or "try NG: ...".
set -uo pipefail
B=${1:-http://localhost:8080}; N=${N:-100}; P=${P:-8}
H='Content-Type: application/json'
ng() { echo "try NG: $*" >&2; exit 1; }
call() { local m=$1 u=$2 d=${3:-}; curl -s -X "$m" -H "$H" ${d:+-d "$d"} "$B$u"; }
ok() { jq -e '.success == true' >/dev/null <<< "$1" || ng "$2: $1"; }

echo "== single database, ScalarDB Native JDBC"
r=$(call POST /customer-customers/upsert '{"customer_id":901,"name":"try-a","credit_limit":100000,"credit_total":0}'); ok "$r" "upsert customer (db_customer)"
r=$(call POST /inventory-items/upsert '{"item_id":901,"name":"try-item","price":100,"stock":10}'); ok "$r" "upsert item (db_inventory)"
r=$(call POST '/inventory-items/901/add-stock?qty=5'); ok "$r" "add-stock (db_inventory)"
[ "$(jq .data.stock <<< "$r")" = 15 ] || ng "stock after add-stock: $r"
echo "add-stock: stock 10 -> 15"

echo "== across the databases, PostgreSQL Frontend"
r=$(call POST /orders '{"customer_id":901,"items":[{"item_id":901,"qty":3}]}'); ok "$r" "place order"
O=$(jq -r .data.order_id <<< "$r")
echo "order $O: total $(jq .data.total_amount <<< "$r")"
[ "$(call GET /inventory-items/901 | jq .data.stock)" = 12 ] || ng "stock after the order"
[ "$(call GET /customer-customers/901 | jq .data.credit_total)" = 300 ] || ng "credit after the order"
r=$(call GET /orders/$O); ok "$r" "get order"
r=$(call POST /orders/$O/cancel); ok "$r" "cancel"
[ "$(call POST /orders/$O/cancel | jq .error_code)" = 9802 ] || ng "a second cancel must be 9802"
[ "$(call GET /inventory-items/901 | jq .data.stock)" = 15 ] || ng "stock after the cancel"
[ "$(call GET /customer-customers/901 | jq .data.credit_total)" = 0 ] || ng "credit after the cancel"
[ "$(call POST /orders '{"customer_id":901,"items":[{"item_id":901,"qty":999}]}' | jq .error_code)" = 9801 ] || ng "out of stock must be 9801"
echo "order, read, cancel, cancel again (9802), out of stock (9801): stock and credit read back through ScalarDB Native JDBC"

echo "== both at once on item 901: $N add-stock (+10) and $N orders (-1), $P in parallel"
r=$(call POST /customer-customers/upsert '{"customer_id":902,"name":"try-b","credit_limit":1000000000,"credit_total":0}'); ok "$r" "upsert customer 902"
r=$(call PUT /inventory-items '{"item_id":901,"name":"try-item","price":100,"stock":1000}'); ok "$r" "reset stock"
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
export B H D
for i in $(seq "$N"); do echo "add $i"; echo "order $i"; done | xargs -P "$P" -L 1 bash -c '
  if [ "$0" = add ]; then curl -s -X POST "$B/inventory-items/901/add-stock?qty=10"
  else curl -s -X POST -H "$H" -d "{\"customer_id\":902,\"items\":[{\"item_id\":901,\"qty\":1}]}" "$B/orders"; fi > "$D/$0-$1"'
adds=$(cat "$D"/add-* | jq -s 'map(select(.success == true)) | length')
orders=$(cat "$D"/order-* | jq -s 'map(select(.success == true)) | length')
stock=$(call GET /inventory-items/901 | jq .data.stock); credit=$(call GET /customer-customers/902 | jq .data.credit_total)
want=$((1000 + 10 * adds - orders))
echo "add-stock succeeded $adds, orders succeeded $orders (the others failed after their retries: $(cat "$D"/* | jq -r 'select(.success == false) | .error_code' | sort | uniq -c | tr -s ' \n' ' '))"
echo "stock: expected $want, read $stock; credit of 902: expected $((100 * orders)), read $credit"
[ "$stock" = "$want" ] && [ "$credit" = $((100 * orders)) ] || ng "an update was lost"
echo "try OK"
