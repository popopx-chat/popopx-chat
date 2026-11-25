#!/bin/bash

# Test backend on the app runner: a chat relay on the preset servers, plus a local SMP server
# with a name resolver, names claimed by contacts that accept connections.
# Usage:
#   scripts/ci/ios-sim/backend.sh start <backend zip> <work dir>   writes the names server's address to <work dir>/names-server
#                                                                  and what was seeded to <work dir>/seed.md
#   scripts/ci/ios-sim/backend.sh stop <work dir>                  stops everything it started, prints the logs
# Everything it starts keeps running between start and stop.

set -euo pipefail

admin=ci_admin
names_resolver_port=18080

# Runs one chat command in a CLI client that stays online for <secs> after it; the output is in $work/out.
chat() {
  local db=$1 secs=$2 cmd=$3
  shift 3
  local status=0
  "$bin/popopx-chat" -d "$work/$db" -e "$cmd" -t "$secs" --execute-log all "$@" < /dev/null > "$work/out" 2>&1 || status=$?
  cat "$work/out" >> "$work/$db-cli.log"
  echo "::group::$db: $(cut -c1-200 <<< "$cmd")"
  cat "$work/out"
  echo "::endgroup::"
  return "$status"
}

admin() {
  chat "$admin" "$1" "$2" --user-display-name "$admin"
}

# A command that resolves a POPOPX name: given -s, the client uses that server alone, with every role, names included.
# -s also saves it among the user's servers, and later runs would put queues on it that the relay can't reach
# (it routes to unknown servers through a preset proxy), so it is then kept for names only.
named() {
  local db=$1 user=$2 secs=$3 cmd=$4
  local status=0
  chat "$db" "$secs" "$cmd" --user-display-name "$user" -s "$names_server" || status=$?
  db_query "$db" "UPDATE protocol_servers SET role_storage = 0, role_proxy = 0, role_names = 1 WHERE host = 'localhost'"
  return "$status"
}

expect_out() {
  if ! grep -qE "$1" "$work/out"; then
    echo "error: \"$1\" not in the output"
    return 1
  fi
}

db_query() {
  sqlite3 "$work/$1_chat.db" "$2"
}

start_relay() {
  nohup "$bin/popopx-chat" -d "$work/relay" --relay --headless --user-display-name ci_relay < /dev/null > "$work/relay.log" 2>&1 &
  echo $! > "$work/relay.pid"
  local deadline=$((SECONDS + 120))
  until grep -qE '^https://[^ ]+/r#' "$work/relay.log"; do
    if ! kill -0 "$(cat "$work/relay.pid")" 2> /dev/null || [ "$SECONDS" -ge "$deadline" ]; then
      echo "error: the relay did not create its address"
      cat "$work/relay.log"
      return 1
    fi
    sleep 1
  done
  relay_link=$(grep -m 1 -oE '^https://[^ ]+/r#[^ ]+' "$work/relay.log")
  echo "relay address: $relay_link"
}

# Waits for the process to exit, which completes its output, and kills it after 30 s.
stop_process() {
  local pid deadline
  pid=$(cat "$work/$1.pid")
  kill "-$2" "$pid" 2> /dev/null || true
  deadline=$((SECONDS + 30))
  while kill -0 "$pid" 2> /dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      kill -KILL "$pid" 2> /dev/null || true
    fi
    sleep 1
  done
}

# A local SMP server whose [NAMES] section points at names-resolver.py, which answers from names.json.
start_names() {
  echo "{}" > "$work/names.json"
  nohup python3 "$(dirname "$0")/names-resolver.py" "$names_resolver_port" "$work/names.json" < /dev/null > "$work/names-resolver.log" 2>&1 &
  echo $! > "$work/names-resolver.pid"
  export SMP_SERVER_CFG_PATH=$work/smp-server/etc SMP_SERVER_LOG_PATH=$work/smp-server/log
  "$bin/smp-server" init -y --disable-store-log --no-password --fqdn localhost --disable-web > "$work/out" 2>&1 || {
    cat "$work/out"
    return 1
  }
  cat "$work/out"
  names_server=$(grep -m 1 -oE 'smp://[^ ]+@localhost' "$work/out")
  sed -i '' \
    -e 's/^enable: off$/enable: on/' \
    -e "s|^# resolver_endpoint: http://127.0.0.1:8000\$|resolver_endpoint: http://127.0.0.1:$names_resolver_port|" \
    -e 's/^port = 5223,443$/port = 5223/' \
    "$SMP_SERVER_CFG_PATH/smp-server.ini"
  grep -E '^(enable: on|resolver_endpoint|port = )' "$SMP_SERVER_CFG_PATH/smp-server.ini"
  nohup "$bin/smp-server" start < /dev/null > "$work/smp-server.log" 2>&1 &
  echo $! > "$work/smp-server.pid"
  local deadline=$((SECONDS + 60))
  until nc -z 127.0.0.1 5223 2> /dev/null; do
    if ! kill -0 "$(cat "$work/smp-server.pid")" 2> /dev/null || [ "$SECONDS" -ge "$deadline" ]; then
      echo "error: the names server did not start"
      cat "$work/smp-server.log" "$work/names-resolver.log"
      return 1
    fi
    sleep 1
  done
  echo "$names_server" > "$work/names-server"
  echo "names server: $names_server"
}

register_name() {
  local name=$1 contact=$2 channel=$3
  jq --arg n "$name" --arg ct "$contact" --arg ch "$channel" \
    '.[$n] = {popopxContact: ([$ct] | map(select(. != ""))), popopxChannel: ([$ch] | map(select(. != "")))}' \
    "$work/names.json" > "$work/names.json.new"
  mv "$work/names.json.new" "$work/names.json"
}

# The short address that /ad printed.
new_address() {
  local address
  address=$(awk '/Your new chat address is created!/ {getline; getline; print; exit}' "$work/out")
  case "$address" in
    https://*/a#*) echo "$address" ;;
    *)
      echo "error: no short address in the output" >&2
      return 1
      ;;
  esac
}

# A contact that claims a name and accepts every connection; it keeps running, so the app can connect to it.
start_contact() {
  local db=$1 display_name=$2 name=$3
  chat "$db" 1 "/ad" --user-display-name "$display_name"
  local address
  address=$(new_address)
  chat "$db" 1 "/auto_accept on" --user-display-name "$display_name"
  expect_out "^auto_accept on"
  register_name "$name" "$address" ""
  named "$db" "$display_name" 5 "/_set domain 1 $name"
  expect_out "^new contact address set$"
  # --headless is for relays only; a command with a long -t keeps the client online, accepting contacts, for 6 hours
  nohup "$bin/popopx-chat" -d "$work/$db" -e "/auto_accept on" -t 21600 --user-display-name "$display_name" < /dev/null > "$work/$db.log" 2>&1 &
  echo $! > "$work/$db.pid"
}

seed_contacts() {
  start_contact ci_alice cialice cialice.testing
  start_contact ci_robert Robert cibobby.testing
}

# What the app will resolve, from a client that knows none of the names' owners.
probe_names() {
  local target pattern
  # -s gives its server the names role only for users that exist when the client starts
  chat probe 1 "/user" --user-display-name ci_probe
  for target in "@cialice.testing|contact address: ok to connect" "@cibobby.testing|contact address: ok to connect"; do
    pattern=${target#*|}
    target=${target%%|*}
    named probe ci_probe 5 "/_connect plan 1 $target"
    expect_out "$pattern"
  done
  named probe ci_probe 5 "/_connect plan 1 cinone.testing" || true
  echo "names resolve: cialice, cibobby; cinone is not registered"
}

write_seed() {
  {
    echo "# Test backend"
    echo
    echo "## POPOPX names"
    echo
    echo "Names server, to add in the app for resolving names: \`$names_server\`"
    echo
    echo "| Name | Resolves to |"
    echo "|---|---|"
    echo "| cialice.testing | the contact cialice, online and accepting connections |"
    echo "| cibobby.testing | the contact Robert (display name without the name), online and accepting connections |"
    echo "| any other, e.g. cinone.testing | not registered |"
    echo
  } > "$work/seed.md"
}

start() {
  bin=$work/bin
  mkdir -p "$bin"
  unzip -o -q "$1" -d "$bin"
  "$bin/popopx-chat" --version
  "$bin/smp-server" --version

  start_names
  start_relay
  seed_contacts
  probe_names
  write_seed
}

stop() {
  local p processes="relay ci_alice ci_robert smp-server"
  for p in $processes; do
    if [ -f "$work/$p.pid" ]; then
      stop_process "$p" INT
    fi
  done
  # Python, started in the background by a script, ignores SIGINT
  if [ -f "$work/names-resolver.pid" ]; then
    stop_process names-resolver TERM
  fi
  for p in $processes names-resolver; do
    echo "::group::$p log"
    cat "$work/$p.log" 2> /dev/null || true
    echo "::endgroup::"
  done
}

case "${1:-}" in
  start)
    work=$3
    mkdir -p "$work"
    start "$2"
    ;;
  stop)
    work=$2
    stop
    ;;
  *)
    echo "usage: $0 start <backend zip> <work dir> | stop <work dir>"
    exit 1
    ;;
esac
