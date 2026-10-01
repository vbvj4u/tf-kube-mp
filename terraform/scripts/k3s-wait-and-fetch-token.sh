#!/usr/bin/env bash
set -euo pipefail

eval "$(jq -r '@sh "NAME=\(.name)"')"

TIMEOUT=300
ELAPSED=0
until multipass exec "$NAME" -- test -f /tmp/k3s-ready; do
  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    echo "Timed out after ${TIMEOUT}s waiting for $NAME to report k3s-ready" >&2
    exit 1
  fi
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

TOKEN=$(multipass exec "$NAME" -- sudo cat /var/lib/rancher/k3s/server/node-token)
jq -n --arg token "$TOKEN" '{token: $token}'
