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

## Running it on a developer's machine

The deployed app authenticates with managed identity; the pipeline authenticates with GitHub
OIDC. Locally there's a third path: **your own Azure identity** — but unlike the other two,
it doesn't work out of the box. Someone has to explicitly grant you access first.

**One-time setup, per developer:**

1. Someone who already has rights on the vault grants yours:

   ```bash
   az role assignment create --assignee <your-email-or-object-id> \
     --role "Key Vault Secrets User" \
     --scope $(az keyvault show -n <AZURE_KEYVAULT_NAME> --query id -o tsv)
   ```

   Skipping this step is the most common reason "it works when deployed but not on my
   machine" — being signed in proves *who* you are, but says nothing about *what* you're
   allowed to read. Both are required.
2. Sign in locally, any one of: `az login`, signing into the Azure Account extension in
   VS Code, or signing into Visual Studio with an account that has that role.
   `DefaultAzureCredential` checks all of these.

**Every time you run it:**

```bash
dotnet run --project src/SecretsDemo --KeyVault:Uri=https://<AZURE_KEYVAULT_NAME>.vault.azure.net/
```

With no managed identity available (you're not running inside Azure), `DefaultAzureCredential`
falls through to whichever sign-in it found above.

**A note for real projects (not this demo):** here, everyone points at the one Key Vault
`infra/setup.sh` created, since it's just a demo. On a real team, you'd normally create a
separate, lower-privilege *dev* Key Vault and only ever grant developers access to that one —
never the vault production uses — so no individual's laptop access can reach production
secrets, however it's authenticated.

## Apps that aren't hosted in Azure at all (on-prem, etc.)

Managed identity only exists for things Azure itself is running. An on-prem server has no
equivalent, so `DefaultAzureCredential` will fail through its entire fallback chain and find
nothing — unless you give it something explicit. Realistic options, best first:

- **Azure Arc-enabled servers.** If you can install the Arc agent on the on-prem machine, it
  gets a real system-assigned managed identity, the same mechanism App Service uses here. This
  is the closest thing to "no stored secret" you can get for on-prem hardware.
- **A dedicated service principal with a client secret or certificate.** Register an app
  registration (same idea as the GitHub one), but instead of a federated credential, generate an
  actual client secret or certificate for it. Store that credential in whatever secret store the
  on-prem environment already has, and expose it via the `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` /
  `AZURE_CLIENT_SECRET` environment variables — `DefaultAzureCredential` picks these up
  automatically. This does bring back a stored secret, so scope its Key Vault role to read-only
  and rotate it on a schedule.
- **Federated credential from your own OIDC issuer**, if the on-prem platform can act as one
  (e.g., HashiCorp Vault, or a SPIFFE/SPIRE setup with a reachable discovery endpoint). Same
  trust-rule approach as the GitHub Actions credential in this repo, just pointed at a different
  issuer. Avoids a stored secret entirely, but is more infrastructure than most on-prem setups
  already have in place.

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
- **Run it locally:** see [Running it on a developer's machine](#running-it-on-a-developers-machine) above.

## Clean up
```bash
az group delete -n rg-secretsdemo
az ad app delete --id <AZURE_CLIENT_ID>
```

## Plain-English recap: what `infra/setup.sh` actually did

If the diagram up top didn't land, here's the same thing as a checklist. Every step below
checks "does this already exist?" first, so re-running the script after a failure resumes
instead of duplicating things.

1. **Resource group** — just a folder to keep everything else in.
2. **Key Vault** — created it, gave *you* permission to write secrets into it, and added one
   secret named `DemoSecret`.
3. **App Service** (the free tier, tried a few regions until one had room) — created the web
   app, turned on its **managed identity** (an identity Azure manages for you, with no
   password/secret to leak), and gave that identity permission to *read* the vault. Also told
   the app where the vault is, via the `KeyVault__Uri` app setting.
4. **App registration** — a separate identity, this one for GitHub Actions to log in as.
   Attached a **federated credential**: a rule saying "trust OIDC tokens from this exact
   GitHub repo's main branch," built from GitHub's real numeric owner/repo IDs rather than
   just their names.
5. **Permissions for that identity** — let it deploy to the App Service, and read the vault
   (used by the workflow's demo "read secret" step).
6. Printed the 5 values you paste into GitHub as repository *variables* (not secrets — none
   of them are sensitive on their own).

Two different identities do the actual work, and they never overlap:

- **Deploy time**: GitHub's own token proves "this is repo X's workflow" to Azure, which
  swaps it for a short-lived Azure token. Used only while the workflow runs.
- **Run time**: whenever anyone loads the live app, it's the App Service's managed identity
  reading the vault — nothing to do with GitHub or OIDC at that point.

**Where the secret actually lives:** in memory only, inside the running app process. On
startup, the app fetches it from Key Vault over HTTPS using its managed identity and holds it
in `IConfiguration` in RAM — never written to disk, and re-fetched fresh on every restart.

**Does the developer's own Azure login ever get used by mistake?** No. Managed identity
(used when the app runs *in* Azure) and your local `az login` session (used when *you* run the
app on your own machine) live in completely different places and never compete: the deployed
App Service has no way to see a token cache that only exists on your laptop, and vice versa.
`DefaultAzureCredential` just picks whichever one is actually available in the environment
it's running in.
