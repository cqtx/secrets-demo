#!/usr/bin/env bash
# One-time Azure setup for the SecretsDemo app.
# Run after `az login`. Edit the variables below first.
set -euo pipefail

# ---- edit these ------------------------------------------------------------
GITHUB_REPO="your-github-user/secrets-evolution"   # owner/repo
LOCATION="eastus"
SUFFIX="$RANDOM"                                   # keeps global names unique
RG="rg-secretsdemo"
KV_NAME="kv-secretsdemo-$SUFFIX"                   # 3-24 chars, globally unique
PLAN_NAME="plan-secretsdemo"
WEBAPP_NAME="app-secretsdemo-$SUFFIX"              # globally unique
ENTRA_APP_NAME="github-oidc-secretsdemo"
# ---------------------------------------------------------------------------

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
ME=$(az ad signed-in-user show --query id -o tsv)

echo "==> Resource group"
az group create -n "$RG" -l "$LOCATION" -o none

echo "==> Key Vault (RBAC mode) + a demo secret"
az keyvault create -n "$KV_NAME" -g "$RG" -l "$LOCATION" --enable-rbac-authorization true -o none
KV_ID=$(az keyvault show -n "$KV_NAME" --query id -o tsv)
KV_URI=$(az keyvault show -n "$KV_NAME" --query properties.vaultUri -o tsv)
# You need data-plane rights to write the secret yourself.
az role assignment create --assignee "$ME" --role "Key Vault Secrets Officer" --scope "$KV_ID" -o none
echo "    waiting for role assignment to propagate..."
sleep 30
az keyvault secret set --vault-name "$KV_NAME" -n DemoSecret --value "hello-from-key-vault" -o none

echo "==> App Service (Linux, .NET 10) with a system-assigned managed identity"
az appservice plan create -n "$PLAN_NAME" -g "$RG" -l "$LOCATION" --is-linux --sku B1 -o none
az webapp create -n "$WEBAPP_NAME" -g "$RG" -p "$PLAN_NAME" --runtime "DOTNETCORE:10.0" -o none
WEBAPP_PRINCIPAL=$(az webapp identity assign -n "$WEBAPP_NAME" -g "$RG" --query principalId -o tsv)
az role assignment create --assignee-object-id "$WEBAPP_PRINCIPAL" --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" --scope "$KV_ID" -o none
az webapp config appsettings set -n "$WEBAPP_NAME" -g "$RG" --settings "KeyVault__Uri=$KV_URI" -o none

echo "==> Entra app registration that GitHub Actions will sign in as (via OIDC, no secret)"
CLIENT_ID=$(az ad app create --display-name "$ENTRA_APP_NAME" --query appId -o tsv)
SP_ID=$(az ad sp create --id "$CLIENT_ID" --query id -o tsv)

# The federated credential says: "trust tokens issued by GitHub for THIS repo's main branch".
cat > /tmp/fic.json <<JSON
{
  "name": "github-main",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:${GITHUB_REPO}:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}
JSON
az ad app federated-credential create --id "$CLIENT_ID" --parameters @/tmp/fic.json -o none
rm /tmp/fic.json

# What the pipeline may do: deploy to the web app, and read secrets from the vault.
WEBAPP_ID=$(az webapp show -n "$WEBAPP_NAME" -g "$RG" --query id -o tsv)
az role assignment create --assignee-object-id "$SP_ID" --assignee-principal-type ServicePrincipal \
  --role "Website Contributor" --scope "$WEBAPP_ID" -o none
az role assignment create --assignee-object-id "$SP_ID" --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" --scope "$KV_ID" -o none

cat <<OUT

Done. Add these as GitHub repository *variables* (Settings > Secrets and variables > Actions > Variables).
None of them are secrets -- that's the point of OIDC.

  AZURE_CLIENT_ID       = $CLIENT_ID
  AZURE_TENANT_ID       = $TENANT_ID
  AZURE_SUBSCRIPTION_ID = $SUBSCRIPTION_ID
  AZURE_WEBAPP_NAME     = $WEBAPP_NAME
  AZURE_KEYVAULT_NAME   = $KV_NAME

App URL: https://$(az webapp show -n "$WEBAPP_NAME" -g "$RG" --query defaultHostName -o tsv)
Tear down later with: az group delete -n $RG && az ad app delete --id $CLIENT_ID
OUT
