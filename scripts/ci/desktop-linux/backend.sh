#!/bin/bash

# Test backend on the app runner: a chat relay on the preset servers, plus an SMP server
# on 127.0.0.1 that resolves .testing names through a local resolver, and a CLI peer
# with an address on it that claims the name seeded.testing.
# Usage:
#   scripts/ci/desktop-linux/backend.sh start <backend .tar.gz> <work dir>   writes the names server's address to <work dir>/names-server
#   scripts/ci/desktop-linux/backend.sh stop <work dir>                      stops the servers, prints their logs
# The relay, the SMP server and the resolver keep running between start and stop.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
admin=ci_admin
# the longest profile image data URI the apps make and the core accepts (maxProfileImageSize)
max_image_size=12500
name_label=seeded
resolver_port=8090

# Runs one chat command in a CLI client that stays online for <secs> after it; the output is in $work/out.
chat() {
  local db=$1 secs=$2 cmd=$3
  shift 3
  local status=0
  "$bin/popopx-chat" -d "$work/$db" -e "$cmd" -t "$secs" --execute-log all "$@" < /dev/null > "$work/out" 2>&1 || status=$?
  cat "$work/out" >> "$work/$db-cli.log"
  # commands with images are thousands of characters long
  echo "::group::$db: ${cmd:0:200}"
  cat "$work/out"
  echo "::endgroup::"
  return "$status"
}

expect_out() {
  if ! grep -qE "$1" "$work/out"; then
    echo "error: \"$1\" not in the output"
    return 1
  fi
}

# Prints a profile image data URI: JPEG at quality 85, scaled down by the square root
# of its excess, at most halved per step, until it is at most max_image_size characters. The picture fills the
# whole square, a gradient between two shades of one colour with a large white letter; noise keeps JPEG from
# compressing it much, so the image ends up near the limit.
avatar() {
  local top=$1 bottom=$2 letter=$3 source=$work/avatar-source.png file=$work/avatar.jpg size=512 uri font
  font=$(fc-match -f '%{file}' 'DejaVu Sans:bold')
  convert -size 512x512 gradient:"$top-$bottom" -seed 1 -attenuate 0.5 +noise Gaussian \
    -font "$font" -pointsize 320 -fill white -gravity center -annotate +0+0 "$letter" "$source"
  while :; do
    convert "$source" -resize "${size}x${size}" -quality 85 "$file"
    uri="data:image/jpg;base64,$(base64 -w 0 "$file")"
    [ "${#uri}" -gt "$max_image_size" ] || break
    size=$(awk -v s="$size" -v n="${#uri}" -v m="$max_image_size" 'BEGIN { r = sqrt(n / m); if (r > 2) r = 2; print int(s / r) }')
  done
  echo "avatar \"$letter\" over $top to $bottom: ${size}x${size} px, ${#uri} characters, mean colour $(convert "$file" -resize '1x1!' -format '%[pixel:p{0,0}]' info:)" >&2
  echo "$uri"
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

# An SMP server on 127.0.0.1 whose [NAMES] section asks the local resolver, which answers from names.json.
start_names_server() {
  local cfg=$work/smp/etc logs=$work/smp/var ini deadline
  echo '{}' > "$work/names.json"
  nohup python3 "$here/names-resolver.py" "$resolver_port" "$work/names.json" < /dev/null > "$work/resolver.log" 2>&1 &
  echo $! > "$work/resolver.pid"
  SMP_SERVER_CFG_PATH=$cfg SMP_SERVER_LOG_PATH=$logs "$bin/smp-server" init -y --ip 127.0.0.1 --no-password --disable-web
  ini=$cfg/smp-server.ini
  # only 5223: 443 needs root
  sed -i -e 's/^port = 5223,443$/port = 5223/' \
    -e '/^\[NAMES\]/,/^\[/{s/^enable: off$/enable: on/;s|^# resolver_endpoint: http://127.0.0.1:8000$|resolver_endpoint: http://127.0.0.1:'"$resolver_port"'|}' "$ini"
  if ! grep -qx 'port = 5223' "$ini" ||
    ! sed -n '/^\[NAMES\]/,/^\[/p' "$ini" | grep -qx 'enable: on' ||
    ! sed -n '/^\[NAMES\]/,/^\[/p' "$ini" | grep -qx "resolver_endpoint: http://127.0.0.1:$resolver_port"; then
    echo "error: $ini has a different port or [NAMES] than expected:"
    grep -E '^port|^\[NAMES\]|enable|resolver' "$ini"
    return 1
  fi
  SMP_SERVER_CFG_PATH=$cfg SMP_SERVER_LOG_PATH=$logs nohup "$bin/smp-server" start < /dev/null > "$work/smp-server.log" 2>&1 &
  echo $! > "$work/smp-server.pid"
  deadline=$((SECONDS + 60))
  until (exec 3<> /dev/tcp/127.0.0.1/5223) 2> /dev/null; do
    if ! kill -0 "$(cat "$work/smp-server.pid")" 2> /dev/null || [ "$SECONDS" -ge "$deadline" ]; then
      echo "error: the SMP server is not listening on 5223"
      cat "$work/smp-server.log"
      return 1
    fi
    sleep 1
  done
  names_server="smp://$(cat "$cfg/fingerprint")@127.0.0.1"
  echo "$names_server" > "$work/names-server"
  echo "names server: $names_server"
}

# A CLI client started with -s uses only that server and, once its user exists, gives it every role, names included.
names_client() {
  local db=$1
  shift
  chat "$db" "$@" --user-display-name "$db" -s "$names_server"
}

# ci_contact's address is on the names server; the resolver maps seeded.testing to it, and ci_contact claims the name.
seed_name() {
  local image link
  image=$(avatar "rgb(70,130,240)" "rgb(30,50,170)" N)
  names_client ci_contact 1 "/_profile 1 {\"displayName\":\"ci_contact\",\"fullName\":\"\",\"shortDescr\":\"CI seeded contact\",\"image\":\"$image\"}"
  names_client ci_contact 3 "/ad"
  link=$(awk '/Your new chat address is created!/ {getline; getline; print; exit}' "$work/out")
  case "$link" in
    https://*/a#*) ;;
    *)
      echo "error: no short address for ci_contact in the output"
      return 1
      ;;
  esac
  jq -n --arg n "$name_label" --arg l "$link" '{($n): {popopxContact: [$l]}}' > "$work/names.json"
  names_client ci_contact 5 "/_set domain 1 $name_label.testing"
  # what the app does on the Search key, from a client that knows nothing but the names server; it finds the
  # address only if ci_contact's claim is in the address data
  names_client name_probe 1 "/user"
  names_client name_probe 5 "/_connect plan 1 @$name_label.testing"
  expect_out "contact address: ok to connect"
  echo "@$name_label.testing resolves to ci_contact's address"
}

start() {
  bin=$work/bin
  mkdir -p "$bin"
  tar -C "$bin" -xzf "$1"
  "$bin/popopx-chat" --version

  start_relay
  start_names_server
  seed_name
}

stop() {
  local p
  for p in relay smp-server; do
    if [ -f "$work/$p.pid" ]; then
      stop_process "$p" INT
    fi
  done
  # Python, started in the background by a script, ignores SIGINT
  if [ -f "$work/resolver.pid" ]; then
    stop_process resolver TERM
  fi
  for p in relay smp-server resolver; do
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
    echo "usage: $0 start <backend .tar.gz> <work dir> | stop <work dir>"
    exit 1
    ;;
esac
