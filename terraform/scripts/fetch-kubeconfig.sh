#!/usr/bin/env bash
set -euo pipefail

eval "$(jq -r '@sh "NAME=\(.name) SERVER_IP=\(.server_ip)"')"

RAW=$(multipass transfer "${NAME}:/etc/rancher/k3s/k3s.yaml" -)
REWRITTEN=$(echo "$RAW" | sed "s/127.0.0.1/${SERVER_IP}/")

jq -n --arg content "$REWRITTEN" '{content: $content}'
