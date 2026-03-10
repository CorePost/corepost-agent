#!/bin/sh
set -eu

# Stub agent: intended only as a placeholder so the installer can enable a unit.
# The real implementation will replace this script.

interval="${COREPOST_AGENT_HEARTBEAT_SECONDS:-60}"

while true; do
  echo "[corepost-agent] stub alive (interval=${interval}s)"
  sleep "$interval"
done

