# SecretsDemo: GitHub Actions → Azure with OIDC, and Key Vault secrets

A minimal .NET 10 web app that reads a secret from Azure Key Vault, deployed from
GitHub Actions **without storing any Azure credentials in GitHub**.

## Two identities, zero secrets

```
 GitHub Actions job                         Microsoft Entra ID
 ──────────────────                         ──────────────────
 1. asks GitHub for an OIDC token  ───────► 2. checks iss / sub / aud against the
    (a signed JWT: "I am repo X,               federated credential on the app
     branch main, workflow Y")                 registration, then issues a short-lived
                                               Azure access token
 3. uses that token to read Key Vault
    and deploy to App Service

 App Service (at runtime)
 ────────────────────────
 4. the app's managed identity gets a token from the App Service
    platform and reads Key Vault. DefaultAzureCredential handles this.
```

- **Deploy time:** GitHub OIDC token ⇄ Entra *federated credential* (`infra/setup.sh` creates it).
- **Run time:** App Service *managed identity* → Key Vault (`Program.cs`).

Nothing in the repo or in GitHub settings is secret. Tokens live for minutes.

## About runners

You don't need your own runner. `runs-on: ubuntu-latest` uses **GitHub-hosted runners**,
free for public repos and included minutes for private ones. OIDC works on them out of the box.

## Steps

### 1. Push this code to GitHub
Create an empty repo (e.g. `secrets-evolution`) and push to the `main` branch.

### 2. Create the Azure resources (once)
Edit the variables at the top of `infra/setup.sh`. **`GITHUB_REPO` must match exactly**
(`owner/repo`). Then:

```bash
az login
./infra/setup.sh
```

It creates a resource group, a Key Vault containing `DemoSecret`, a free-tier (F1) Linux App
Service (tries several regions until one has free-tier capacity), an Entra app registration with
a federated credential trusting your repo's `main` branch, and the role assignments. The script is
safe to re-run if any step fails partway through.

> If `az webapp create` rejects `DOTNETCORE:10.0`, run `az webapp list-runtimes --os linux`
> and use the .NET 10 value it lists.

### 3. Add the repository variables
Go to GitHub → repo → **Settings → Secrets and variables → Actions → Variables** and add the five
values the script printed: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`,
`AZURE_WEBAPP_NAME`, `AZURE_KEYVAULT_NAME`.

### 4. Run the workflow
Push to `main` or use **Actions → Build and deploy → Run workflow**. In the `deploy` job's log:

- **Inspect GitHub OIDC token** prints the JWT claims. Compare `sub` with the federated
  credential subject.
- **Azure login (OIDC)** exchanges that token for an Azure token.
- **Read secret from Key Vault** gets `DemoSecret`. GitHub masks it as `***` in the log.

Then open `https://<AZURE_WEBAPP_NAME>.azurewebsites.net`. The page shows the secret, which the
app read through its managed identity.

### Troubleshooting: `AADSTS700213: No matching federated identity record found`

Repos created after 2026-07-15 get "immutable" subject claims by default: GitHub embeds the
numeric owner and repo IDs (`repo:owner@ownerId/repo@repoId:ref:...`), not just their names, so
that a renamed or deleted-and-recreated repo can't quietly inherit an old trust relationship
([GitHub changelog](https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/)).
`infra/setup.sh` builds the federated credential using those real IDs via `gh api`, so a fresh run
gets it right. If you ever hand-build a federated credential elsewhere, copy the exact `subject`
string Azure's own error message reports (or `azure/login`'s "Federated token details" log lines)
rather than assuming plain `owner/repo`.

## Things to try
- **Break the trust on purpose:** run the workflow from another branch. Login fails with
  `AADSTS700213: No matching federated identity record found`, because the `sub` claim no longer
  matches.
- **Nested config:** add a secret named `ConnectionStrings--Db`. The app sees it as
  `ConnectionStrings:Db`.
- **Run locally:** after `az login` (and with a Key Vault data role on your account), run
  `dotnet run --project src/SecretsDemo --KeyVault:Uri=https://<vault>.vault.azure.net/`.
  DefaultAzureCredential uses your CLI login.

## Clean up
```bash
az group delete -n rg-secretsdemo
az ad app delete --id <AZURE_CLIENT_ID>
```
