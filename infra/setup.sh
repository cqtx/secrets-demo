#!/usr/bin/env bash
# One-time Azure setup for the SecretsDemo app.
# Run after `az login` and `gh auth login` (gh is used to look up the repo's
# immutable owner/repo IDs for the OIDC trust). Edit the variables below first.
# Safe to re-run: every step checks whether its resource already exists
# before creating it, so a failed run can just be re-run from the top.
#
# This assumes the app itself will be deployed to Azure App Service. If it's
# actually going to run on-prem (or on any non-Azure host), skip the whole
# "App Service" section below -- it's marked. You'd still want the Key Vault
# and, usually, the GitHub identity; the on-prem app just needs its own way
# to authenticate to the vault instead of a managed identity. See the
# README's "Apps that aren't hosted in Azure at all" section for the options.
set -euo pipefail

# ---- edit these ------------------------------------------------------------
GITHUB_REPO="cqtx/secrets-demo"   # owner/repo
LOCATION="eastus"
RG="rg-secretsdemo"
PLAN_NAME="plan-secretsdemo"
ENTRA_APP_NAME="github-oidc-secretsdemo"
# ---------------------------------------------------------------------------

# Goal: gather identifiers we'll need throughout the script -- whose Azure
# account this is, and which tenant/subscription it's in.
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
ME=$(az ad signed-in-user show --query id -o tsv)

# Goal: pick names that are globally unique (required for Key Vault and Web
# App) but stay the same on every re-run, instead of a new random name each
# time -- derived once from the subscription id.
SUFFIX=$(echo -n "$SUBSCRIPTION_ID" | tr -d '-' | cut -c1-8)
KV_NAME="kv-secretsdemo-$SUFFIX"       # 3-24 chars, globally unique
WEBAPP_NAME="app-secretsdemo-$SUFFIX"  # App Service only -- drop this if deploying elsewhere

# Goal: a reusable helper so granting a role is safe to run more than once --
# creates the role assignment only if an identical one doesn't already exist.
ensure_role_assignment() {
  local assignee_id="$1" principal_type="$2" role="$3" scope="$4"
  local existing
  existing=$(az role assignment list --assignee-object-id "$assignee_id" --role "$role" \
    --scope "$scope" --query "[0].id" -o tsv 2>/dev/null || true)
  if [[ -n "$existing" ]]; then
    echo "    role assignment ($role) already present, skipping"
  else
    az role assignment create --assignee-object-id "$assignee_id" --assignee-principal-type "$principal_type" \
      --role "$role" --scope "$scope" -o none
  fi
}

# Goal: create a container to hold every resource this script makes, so they
# can all be deleted together later with a single `az group delete`.
echo "==> Resource group"
az group create -n "$RG" -l "$LOCATION" -o none

# Goal: stand up the vault that will hold DemoSecret, and make sure this
# script (running as you) has permission to write a secret into it.
echo "==> Key Vault (RBAC mode) + a demo secret"
# az keyvault create errors instead of no-op'ing if the vault already exists,
# unlike most other `az ... create` commands here.
if az keyvault show -n "$KV_NAME" &>/dev/null; then
  echo "    vault already exists"
else
  az keyvault create -n "$KV_NAME" -g "$RG" -l "$LOCATION" --enable-rbac-authorization true -o none
fi
KV_ID=$(az keyvault show -n "$KV_NAME" --query id -o tsv)
KV_URI=$(az keyvault show -n "$KV_NAME" --query properties.vaultUri -o tsv)
# You need data-plane rights to write the secret yourself.
ROLE_JUST_CREATED=0
if [[ -z $(az role assignment list --assignee "$ME" --role "Key Vault Secrets Officer" --scope "$KV_ID" --query "[0].id" -o tsv 2>/dev/null) ]]; then
  az role assignment create --assignee "$ME" --role "Key Vault Secrets Officer" --scope "$KV_ID" -o none
  ROLE_JUST_CREATED=1
fi
if [[ "$ROLE_JUST_CREATED" == "1" ]]; then
  echo "    waiting for role assignment to propagate..."
  sleep 30
fi
az keyvault secret set --vault-name "$KV_NAME" -n DemoSecret --value "hello-from-key-vault" -o none

# --- App Service only: skip this entire section if the app runs on-prem or ---
# --- anywhere else that isn't Azure App Service. Managed identity (what     ---
# --- this section grants) only exists for things Azure itself is running.  ---
# Goal: stand up the web app that will read DemoSecret at runtime, using its
# own managed identity -- an identity with no password or secret to leak.
echo "==> App Service (Linux, .NET 10) with a system-assigned managed identity"
# Azure periodically caps Free/Shared App Service capacity in high-demand
# regions (eastus, westus2, ...) independent of the Key Vault's region, which
# doesn't matter here. Try a short list until one has room.
if az appservice plan show -n "$PLAN_NAME" -g "$RG" &>/dev/null; then
  APP_LOCATION=$(az appservice plan show -n "$PLAN_NAME" -g "$RG" --query location -o tsv)
  echo "    plan already exists in $APP_LOCATION"
else
  APP_LOCATION=""
  for loc in centralus northcentralus southcentralus canadacentral westus uksouth; do
    echo "    trying region: $loc"
    if az appservice plan create -n "$PLAN_NAME" -g "$RG" -l "$loc" --is-linux --sku F1 -o none 2>/tmp/plan_err.log; then
      APP_LOCATION="$loc"
      echo "    succeeded in $loc"
      break
    fi
    grep -qi "quota\|capacity" /tmp/plan_err.log && continue
    cat /tmp/plan_err.log >&2   # a different kind of error; stop and show it
    exit 1
  done
  rm -f /tmp/plan_err.log
  if [[ -z "$APP_LOCATION" ]]; then
    echo "All candidate regions are out of Free-tier capacity. Try again later, pick another region," >&2
    echo "or request a quota increase: portal.azure.com > Subscriptions > your sub > Usage + quotas." >&2
    exit 1
  fi
fi
if ! az webapp show -n "$WEBAPP_NAME" -g "$RG" &>/dev/null; then
  az webapp create -n "$WEBAPP_NAME" -g "$RG" -p "$PLAN_NAME" --runtime "DOTNETCORE:10.0" -o none
fi
WEBAPP_PRINCIPAL=$(az webapp identity assign -n "$WEBAPP_NAME" -g "$RG" --query principalId -o tsv)
ensure_role_assignment "$WEBAPP_PRINCIPAL" ServicePrincipal "Key Vault Secrets User" "$KV_ID"
az webapp config appsettings set -n "$WEBAPP_NAME" -g "$RG" --settings "KeyVault__Uri=$KV_URI" -o none
# --- end of the App Service-only section ---

# Goal: create the identity GitHub Actions will log in as, and tell Azure
# exactly which repo and branch it's allowed to log in from.
echo "==> Entra app registration that GitHub Actions will sign in as (via OIDC, no secret)"
CLIENT_ID=$(az ad app list --display-name "$ENTRA_APP_NAME" --query "[0].appId" -o tsv)
if [[ -z "$CLIENT_ID" ]]; then
  CLIENT_ID=$(az ad app create --display-name "$ENTRA_APP_NAME" --query appId -o tsv)
fi
SP_ID=$(az ad sp list --filter "appId eq '$CLIENT_ID'" --query "[0].id" -o tsv)
if [[ -z "$SP_ID" ]]; then
  SP_ID=$(az ad sp create --id "$CLIENT_ID" --query id -o tsv)
fi

# The federated credential says: "trust tokens issued by GitHub for THIS repo's main branch".
# Repos created after 2026-07-15 get "immutable" subject claims by default:
# repo:<owner>@<owner_id>/<repo>@<repo_id>:ref:refs/heads/main, instead of plain
# owner/repo names -- so the credential must be built from GitHub's real IDs,
# not just the names, or Azure will reject the token with AADSTS700213.
GH_OWNER="${GITHUB_REPO%%/*}"
GH_REPO_NAME="${GITHUB_REPO##*/}"
GH_OWNER_ID=$(gh api "repos/$GITHUB_REPO" --jq .owner.id)
GH_REPO_ID=$(gh api "repos/$GITHUB_REPO" --jq .id)
SUBJECT="repo:${GH_OWNER}@${GH_OWNER_ID}/${GH_REPO_NAME}@${GH_REPO_ID}:ref:refs/heads/main"

EXISTING_SUBJECT=$(az ad app federated-credential list --id "$CLIENT_ID" \
  --query "[?name=='github-main'].subject | [0]" -o tsv 2>/dev/null || true)
cat > /tmp/fic.json <<JSON
{
  "name": "github-main",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "${SUBJECT}",
  "audiences": ["api://AzureADTokenExchange"]
}
JSON
if [[ -z "$EXISTING_SUBJECT" ]]; then
  az ad app federated-credential create --id "$CLIENT_ID" --parameters @/tmp/fic.json -o none
elif [[ "$EXISTING_SUBJECT" != "$SUBJECT" ]]; then
  echo "    updating federated credential subject to match GitHub's actual token"
  az ad app federated-credential update --id "$CLIENT_ID" --federated-credential-id github-main \
    --parameters @/tmp/fic.json -o none
fi
rm /tmp/fic.json

# Goal: let that GitHub identity actually do something once it's logged in --
# deploy the app, and read the vault (used by the workflow's demo read step).
# The "Website Contributor" grant is App Service only -- drop it (and
# WEBAPP_ID) if deploying elsewhere; the Key Vault grant still applies if the
# pipeline itself needs to read secrets during an on-prem deploy too.
WEBAPP_ID=$(az webapp show -n "$WEBAPP_NAME" -g "$RG" --query id -o tsv)
ensure_role_assignment "$SP_ID" ServicePrincipal "Website Contributor" "$WEBAPP_ID"
ensure_role_assignment "$SP_ID" ServicePrincipal "Key Vault Secrets User" "$KV_ID"

# Goal: hand back everything you need to wire up the GitHub side (as
# repository variables, not secrets -- see README for why that's safe here).
cat <<OUT

Done. Add these as GitHub repository *variables* (Settings > Secrets and variables > Actions > Variables).
None of them are secrets -- that's the point of OIDC.

  AZURE_CLIENT_ID       = $CLIENT_ID
  AZURE_TENANT_ID       = $TENANT_ID
  AZURE_SUBSCRIPTION_ID = $SUBSCRIPTION_ID
  AZURE_WEBAPP_NAME     = $WEBAPP_NAME       # App Service only -- N/A if deploying on-prem
  AZURE_KEYVAULT_NAME   = $KV_NAME

App URL: https://$(az webapp show -n "$WEBAPP_NAME" -g "$RG" --query defaultHostName -o tsv)
Tear down later with: az group delete -n $RG && az ad app delete --id $CLIENT_ID
OUT
