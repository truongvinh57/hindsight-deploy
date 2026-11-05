#!/usr/bin/env bash
# Mint fresh bearer keys / secrets and print the lines to paste into .env
set -euo pipefail
rand() { openssl rand -hex "${1:-24}"; }
echo "# paste into .env"
echo "POSTGRES_PASSWORD=$(rand 24)"
echo "HERMES_API_KEY=hk_$(rand 24)"
echo "CHERRY_STUDIO_API_KEY=cs_$(rand 24)"
echo "HINDSIGHT_CP_ACCESS_KEY=$(rand 16)"
echo "WEBHOOK_SECRET=whsec_$(rand 20)"
