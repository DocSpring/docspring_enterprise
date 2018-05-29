#!/bin/bash
set -e

echo "=> Creating new build..."
RELEASE_ID=$(convox build --id)

echo "=> Running ./scripts/pre-release in: $RELEASE_ID"
convox run --release "$RELEASE_ID" worker ./scripts/pre-release

echo "=> Promoting Release: $RELEASE_ID"
convox releases promote "$RELEASE_ID" --wait
