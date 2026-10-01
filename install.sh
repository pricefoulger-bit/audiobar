#!/bin/bash
# Build AudioBar, install it to ~/Applications, and open it.
# Usage: ./install.sh <peer-host> [secret]
#   On macbook-air:    ./install.sh mac-mini
#   On mac-mini: ./install.sh macbook-air <secret printed by the first command>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PEER_HOST="${1:-}"
SECRET="${2:-}"

if [[ -n "${PEER_HOST}" && ! "${PEER_HOST}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
  echo "Peer host must look like mac-mini or macbook-air." >&2
  exit 1
fi
if [[ -n "${SECRET}" && ! "${SECRET}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
  echo "Secret must be letters, numbers, and . _ : - only." >&2
  exit 1
fi

"${ROOT}/build.sh"

DEST="${HOME}/Applications"
mkdir -p "${DEST}"

if pgrep -x AudioBar >/dev/null 2>&1; then
  killall AudioBar || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ! pgrep -x AudioBar >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
fi

rm -rf "${DEST}/AudioBar.app"
ditto "${ROOT}/build/AudioBar.app" "${DEST}/AudioBar.app"

SUPPORT="${HOME}/Library/Application Support/AudioBar"
mkdir -p "${SUPPORT}"
CONFIG="${SUPPORT}/config.json"
SECRET_FILE="${SUPPORT}/secret"

if [[ -z "${PEER_HOST}" ]]; then
  echo "Installed ${DEST}/AudioBar.app without changing the peer config."
  echo "Usage: ./install.sh <peer-host> [secret]"
  echo "  On macbook-air:     ./install.sh mac-mini"
  echo "  On mac-mini:  ./install.sh macbook-air <secret>"
else
  if [[ -z "${SECRET}" && -f "${CONFIG}" ]]; then
    SECRET="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("secret",""))' "${CONFIG}" || true)"
  fi
  if [[ -z "${SECRET}" ]]; then
    SECRET="$(openssl rand -hex 24)"
  fi
  python3 - "${CONFIG}" "${PEER_HOST}" "${SECRET}" <<'PY'
import json, sys
path, host, secret = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "w", encoding="utf-8") as handle:
    json.dump({"peerHost": host, "secret": secret}, handle)
    handle.write("\n")
PY
  printf '%s\n' "${SECRET}" > "${SECRET_FILE}"
  chmod 600 "${CONFIG}" "${SECRET_FILE}"
  THIS_HOST="$(hostname -s 2>/dev/null || echo "<this-mac>")"
  echo "AudioBar peer: ${PEER_HOST}"
  echo "AudioBar secret: ${SECRET}"
  echo "On the other Mac, run:"
  echo "  ./install.sh ${THIS_HOST} ${SECRET}"
fi

open "${DEST}/AudioBar.app"
echo "Installed and opened ${DEST}/AudioBar.app"
