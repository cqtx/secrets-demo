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
    var status = DescribeStatus(vaultUri, secret);
    var html = RenderPage(status, secret);
    return Results.Content(html, "text/html");
});

app.Run();

// Turns the vault URI + whatever we found into a plain-English sentence, so
// someone loading the page for the first time can tell what's actually wired up.
static string DescribeStatus(string? vaultUri, string? secret)
{
    if (string.IsNullOrWhiteSpace(vaultUri))
    {
        return "KeyVault:Uri is not configured.";
    }

    if (secret is null)
    {
        return $"Connected to {vaultUri}, but no secret named DemoSecret was found.";
    }

    return $"Read DemoSecret from {vaultUri}";
}

// Builds the page shown at "/". Both values are HTML-encoded because a Key Vault
// secret is arbitrary text and could otherwise break the markup.
static string RenderPage(string status, string? secret)
{
    var encodedStatus = WebUtility.HtmlEncode(status);
    var encodedSecret = WebUtility.HtmlEncode(secret ?? "(none)");

    return $"""
        <!doctype html>
        <title>Secrets Demo</title>
        <body style="font-family:system-ui;max-width:40rem;margin:3rem auto;padding:0 1rem">
          <h1>Key Vault secrets demo</h1>
          <p>{encodedStatus}</p>
          <p>DemoSecret = <code>{encodedSecret}</code></p>
        </body>
        """;
}
