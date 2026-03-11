#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
socket_path="${MUXLY_SOCKET:-/tmp/muxly-example-c-freeze.sock}"
stderr_log=""
daemon_pid=""

cleanup() {
  tmux kill-session -t muxly-example-c-freeze-text >/dev/null 2>&1 || true
  tmux kill-session -t muxly-example-c-freeze-surface >/dev/null 2>&1 || true
  if [[ -n "$daemon_pid" ]]; then
    kill "$daemon_pid" >/dev/null 2>&1 || true
    wait "$daemon_pid" >/dev/null 2>&1 || true
    rm -f "$socket_path"
  fi
  if [[ -n "$stderr_log" ]]; then
    rm -f "$stderr_log"
  fi
}

trap cleanup EXIT

daemon_is_alive() {
  MUXLY_SOCKET="$socket_path" "$repo_root/zig-out/bin/muxly" ping >/dev/null 2>&1
}

ensure_daemon() {
  if daemon_is_alive; then
    return
  fi

  rm -f "$socket_path"
  stderr_log="$(mktemp -t muxlyd-c-freeze-stderr.XXXXXX.log)"
  MUXLY_SOCKET="$socket_path" "$repo_root/zig-out/bin/muxlyd" > /dev/null 2>"$stderr_log" &
  daemon_pid="$!"

  local deadline=$((SECONDS + 5))
  while (( SECONDS < deadline )); do
    if [[ -S "$socket_path" ]] && daemon_is_alive; then
      return
    fi
    if ! kill -0 "$daemon_pid" >/dev/null 2>&1; then
      echo "muxlyd exited early" >&2
      cat "$stderr_log" >&2 || true
      exit 1
    fi
    sleep 0.05
  done

  echo "muxlyd did not answer ping on $socket_path" >&2
  cat "$stderr_log" >&2 || true
  exit 1
}

cd "$repo_root"
zig build example-deps
make -C examples/artifacts/c-freeze all
ensure_daemon

export MUXLY_SOCKET="$socket_path"
export LD_LIBRARY_PATH="$repo_root/zig-out/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$repo_root/examples/artifacts/c-freeze/freeze_client" \
  "$repo_root/examples/artifacts/freeze-demo/surface_chatter.py"
