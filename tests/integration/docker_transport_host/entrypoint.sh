#!/bin/sh
set -eu

if [ -z "${TEST_PUBLIC_KEY:-}" ]; then
  echo "TEST_PUBLIC_KEY is required" >&2
  exit 1
fi

mkdir -p /run/sshd /home/muxlytest/.ssh
printf '%s\n' "$TEST_PUBLIC_KEY" > /home/muxlytest/.ssh/authorized_keys
chown -R muxlytest:muxlytest /home/muxlytest/.ssh
chmod 700 /home/muxlytest/.ssh
chmod 600 /home/muxlytest/.ssh/authorized_keys

ssh-keygen -A >/dev/null 2>&1

if [ -x /workspace/zig-out/bin/muxly ]; then
  ln -sf /workspace/zig-out/bin/muxly /usr/local/bin/muxly
fi

if [ -x /workspace/zig-out/bin/muxlyd ]; then
  ln -sf /workspace/zig-out/bin/muxlyd /usr/local/bin/muxlyd
fi

exec /usr/sbin/sshd -D -e
