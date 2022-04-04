#!/bin/bash
set -eo pipefail
CURRENT_DIR=$(dirname "$0")

if ! [ -f "${CURRENT_DIR}/.rack_name" ]; then
  echo "ERROR: .rack_name file not found"
  exit 1
fi
RACK_NAME=$(cat "${CURRENT_DIR}/.rack_name")

echo "[${RACK_NAME}] => Creating new build..."
RELEASE_ID=$(convox build --id --rack "${RACK_NAME}")

echo "[${RACK_NAME}] => Running bin/pre_release in: $RELEASE_ID"
convox run --release "$RELEASE_ID" command bin/pre_release --rack "${RACK_NAME}"

echo "[${RACK_NAME}] => Promoting Release: $RELEASE_ID"
convox releases promote "$RELEASE_ID" --rack "${RACK_NAME}"
