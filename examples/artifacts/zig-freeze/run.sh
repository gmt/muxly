#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
socket_path="${MUXLY_SOCKET:-/tmp/muxly-example-zig-freeze.sock}"
export MUXLY_SOCKET="$socket_path"
export LD_LIBRARY_PATH="$repo_root/zig-out/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

cd "$repo_root"

zig build example-deps

started_daemon=0
daemon_pid=""
stderr_log=""

cleanup() {
  if [[ -n "$daemon_pid" ]] && kill -0 "$daemon_pid" >/dev/null 2>&1; then
    kill "$daemon_pid" >/dev/null 2>&1 || true
    wait "$daemon_pid" >/dev/null 2>&1 || true
  fi
  if [[ "$started_daemon" -eq 1 ]]; then
    rm -f "$socket_path"
  fi
  if [[ -n "$stderr_log" ]]; then
    rm -f "$stderr_log"
  fi
}

trap cleanup EXIT

if ! "$repo_root/zig-out/bin/muxly" ping >/dev/null 2>&1; then
  rm -f "$socket_path"
  stderr_log="$(mktemp -t muxlyd-zig-freeze-stderr-XXXXXX.log)"
  "$repo_root/zig-out/bin/muxlyd" > /dev/null 2>"$stderr_log" &
  daemon_pid="$!"
  started_daemon=1

  deadline=$((SECONDS + 5))
  while true; do
    if [[ -S "$socket_path" ]] && "$repo_root/zig-out/bin/muxly" ping >/dev/null 2>&1; then
      break
    fi
    if ! kill -0 "$daemon_pid" >/dev/null 2>&1; then
      echo "muxlyd exited early" >&2
      cat "$stderr_log" >&2
      exit 1
    fi
    if (( SECONDS >= deadline )); then
      echo "muxlyd did not answer ping on $socket_path" >&2
      cat "$stderr_log" >&2
      exit 1
    fi
    sleep 0.05
  done
fi

zig run "examples/artifacts/zig-freeze/run.zig" \
  -lc \
  -I"zig-out/include" \
  -L"zig-out/lib" \
  -lmuxly \
  -- \
  "examples/artifacts/freeze-demo/surface_chatter.py"
