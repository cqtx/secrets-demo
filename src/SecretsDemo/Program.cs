using System.Net;
using Azure.Identity;

var builder = WebApplication.CreateBuilder(args);

// If a Key Vault URI is configured, pull every secret in the vault into IConfiguration.
// A secret named "Foo--Bar" becomes the config key "Foo:Bar".
//
// DefaultAzureCredential picks an identity automatically:
//   - in Azure App Service: the app's managed identity (no secrets anywhere)
//   - on your machine:      your `az login` session
var vaultUri = builder.Configuration["KeyVault:Uri"];
if (!string.IsNullOrWhiteSpace(vaultUri))
{
    builder.Configuration.AddAzureKeyVault(new Uri(vaultUri), new DefaultAzureCredential());
}

var app = builder.Build();

app.MapGet("/", (IConfiguration config) =>
{
    var secret = config["DemoSecret"];
    var status = string.IsNullOrWhiteSpace(vaultUri)
        ? "KeyVault:Uri is not configured."
        : secret is null
            ? $"Connected to {vaultUri}, but no secret named DemoSecret was found."
            : $"Read DemoSecret from {vaultUri}";

    var html = $"""
        <!doctype html>
        <title>Secrets Demo</title>
        <body style="font-family:system-ui;max-width:40rem;margin:3rem auto;padding:0 1rem">
          <h1>Key Vault secrets demo</h1>
          <p>{WebUtility.HtmlEncode(status)}</p>
          <p>DemoSecret = <code>{WebUtility.HtmlEncode(secret ?? "(none)")}</code></p>
        </body>
        """;
    return Results.Content(html, "text/html");
});

app.Run();
