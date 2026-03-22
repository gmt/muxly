#!/bin/sh
set -eu

LISTEN_PORT="${LISTEN_PORT:-8080}"
UPSTREAM_HOST="${UPSTREAM_HOST:-host.docker.internal}"
UPSTREAM_PORT="${UPSTREAM_PORT:?UPSTREAM_PORT is required}"
DELAY_MS="${DELAY_MS:-0}"
LOSS_PCT="${LOSS_PCT:-0}"

if [ "$DELAY_MS" != "0" ] || [ "$LOSS_PCT" != "0" ]; then
  tc qdisc add dev eth0 root netem delay "${DELAY_MS}ms" loss "${LOSS_PCT}%"
fi

exec socat "TCP-LISTEN:${LISTEN_PORT},fork,reuseaddr" "TCP:${UPSTREAM_HOST}:${UPSTREAM_PORT}"
