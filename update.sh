#!/bin/bash
set -e

echo "=> Creating new build..."
RELEASE_ID=$(convox build --id)

echo "=> Running bin/pre_release in: $RELEASE_ID"
convox run --release "$RELEASE_ID" worker bin/pre_release

echo "=> Promoting Release: $RELEASE_ID"
convox releases promote "$RELEASE_ID"
