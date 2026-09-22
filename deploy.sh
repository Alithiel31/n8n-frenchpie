#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IDENTITY_FILE="$SCRIPT_DIR/.infisical-identity.env"
ENV_FILE="$SCRIPT_DIR/.env"

if [ ! -f "$IDENTITY_FILE" ]; then
  echo "Fichier $IDENTITY_FILE introuvable." >&2
  echo "Copie .infisical-identity.env.example vers .infisical-identity.env et renseigne le Client ID/Secret de la Machine Identity 'n8n-deploy'." >&2
  exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
  echo "Fichier $ENV_FILE introuvable." >&2
  echo "Copie .env.example vers .env et renseigne les valeurs (IP Tailscale, domaine et projet Infisical)." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$IDENTITY_FILE"
# shellcheck disable=SC1090
source "$ENV_FILE"

INFISICAL_ENVIRONMENT="prod"

echo "Authentification aupres d'Infisical..."
INFISICAL_TOKEN=$(infisical login \
  --method=universal-auth \
  --client-id="$INFISICAL_UNIVERSAL_AUTH_CLIENT_ID" \
  --client-secret="$INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET" \
  --domain="$INFISICAL_DOMAIN" \
  --silent --plain)

echo "Deploiement (secrets injectes depuis Infisical, environnement: $INFISICAL_ENVIRONMENT)..."
cd "$SCRIPT_DIR"
infisical run \
  --token="$INFISICAL_TOKEN" \
  --domain="$INFISICAL_DOMAIN" \
  --projectId="$INFISICAL_PROJECT_ID" \
  --env="$INFISICAL_ENVIRONMENT" \
  -- docker compose up -d

echo "Termine."
