#!/usr/bin/env node

/**
 * Register Application with Frontegg
 *
 * This script registers a single application with Frontegg, allowing login
 * through the specified URL by adding it as a custom domain and OAuth callback URL.
 *
 * Usage:
 *   node frontegg-register.mjs --app-name <name> --app-url <url>
 *
 * Required Environment Variables (provided via secretspec):
 *   FRONTEGG_CLIENT_ID     - Frontegg vendor client ID
 *   FRONTEGG_API_KEY       - Frontegg vendor API key
 *   FRONTEGG_BASE_URL      - Frontegg base URL (e.g., https://app-xxx.us.frontegg.com)
 *   FRONTEGG_API_URL       - Frontegg API URL (default: https://api.us.frontegg.com)
 */

import https from "node:https";

// Simple argument parser
function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i++) {
    if (argv[i].startsWith("--")) {
      const key = argv[i].slice(2);
      const value = argv[i + 1];
      args[key] = value;
      i++;
    }
  }
  return args;
}

const args = parseArgs(process.argv);

if (args.help || args.h) {
  console.log(`
Usage: frontegg-register.mjs [options]

Options:
  --app-name <name>     Application name (e.g., atlas3-localhost, willdan-custom)
  --app-url <url>       Application URL (e.g., https://atlas-docs.localhost or http://localhost:3000)
  -h, --help            Show this help message

Environment Variables (required, provided via secretspec):
  FRONTEGG_CLIENT_ID    Frontegg vendor client ID
  FRONTEGG_API_KEY      Frontegg vendor API key
  FRONTEGG_BASE_URL     Frontegg base URL
  FRONTEGG_API_URL      Frontegg API URL (optional)
  `);
  process.exit(0);
}

// Configuration
const config = {
  frontegg: {
    clientId: process.env.FRONTEGG_CLIENT_ID,
    apiKey: process.env.FRONTEGG_API_KEY,
    apiUrl: process.env.FRONTEGG_API_URL || "https://api.us.frontegg.com",
    baseUrl: process.env.FRONTEGG_BASE_URL,
    accessToken: null,
  },
  app: {
    name: args["app-name"],
    url: args["app-url"],
    loginUrl: null,
  },
};

// Validate required config
if (!config.app.name || !config.app.url) {
  console.error("❌ Missing required arguments: --app-name, --app-url");
  console.error("   Run with --help for usage information");
  process.exit(1);
}

if (!config.frontegg.clientId || !config.frontegg.apiKey || !config.frontegg.baseUrl) {
  console.error("❌ Missing required environment variables:");
  console.error("   FRONTEGG_CLIENT_ID, FRONTEGG_API_KEY, FRONTEGG_BASE_URL");
  console.error("   Make sure these are set in your secretspec configuration");
  process.exit(1);
}

config.app.loginUrl = `${config.frontegg.baseUrl}/oauth`;

/**
 * Make HTTPS request with better error handling
 */
function makeRequest(url, options = {}) {
  return new Promise((resolve, reject) => {
    const urlObj = new URL(url);
    const requestOptions = {
      hostname: urlObj.hostname,
      port: urlObj.port || 443,
      path: urlObj.pathname + urlObj.search,
      method: options.method || "GET",
      headers: {
        "Content-Type": "application/json",
        ...options.headers,
      },
    };

    const req = https.request(requestOptions, (res) => {
      let data = "";
      res.on("data", (chunk) => {
        data += chunk;
      });
      res.on("end", () => {
        try {
          const parsed = data ? JSON.parse(data) : {};
          if (res.statusCode >= 200 && res.statusCode < 300) {
            resolve(parsed);
          } else {
            reject(new Error(`HTTP ${res.statusCode}: ${JSON.stringify(parsed)}`));
          }
        } catch (_err) {
          if (res.statusCode >= 200 && res.statusCode < 300) {
            resolve(data);
          } else {
            reject(new Error(`HTTP ${res.statusCode}: ${data}`));
          }
        }
      });
    });

    req.on("error", reject);

    if (options.body) {
      const bodyStr =
        typeof options.body === "string" ? options.body : JSON.stringify(options.body);
      req.write(bodyStr);
    }

    req.end();
  });
}

/**
 * Authenticate with Frontegg vendor API
 */
async function authenticateFrontegg() {
  console.log("🔐 Authenticating with Frontegg...");

  const url = `${config.frontegg.apiUrl}/auth/vendor`;

  try {
    const response = await makeRequest(url, {
      method: "POST",
      body: {
        clientId: config.frontegg.clientId,
        secret: config.frontegg.apiKey,
      },
    });

    config.frontegg.accessToken = response.token || response.accessToken;
    console.log("✅ Successfully authenticated with Frontegg");

    return config.frontegg.accessToken;
  } catch (error) {
    console.error(`❌ Failed to authenticate with Frontegg: ${error.message}`);
    throw error;
  }
}

/**
 * Register application with Frontegg
 */
async function registerApplication() {
  console.log("\n🏗️  Registering application with Frontegg...");
  console.log(`   - App Name: ${config.app.name}`);
  console.log(`   - App URL: ${config.app.url}`);
  console.log(`   - Login URL: ${config.app.loginUrl}`);

  const payload = {
    name: config.app.name,
    appURL: config.app.url,
    loginURL: config.app.loginUrl,
    type: "web",
    // Note: appURL and loginURL become {{APP_URL}} and {{LOGIN_URL}} variables
    // that are automatically added to allowed origins at the environment level.
  };

  try {
    // Check for existing application
    console.log(`\n   🔍 Checking for existing application: ${config.app.name}...`);
    const listUrl = `${config.frontegg.apiUrl}/applications/resources/applications/v1`;
    const apps = await makeRequest(listUrl, {
      headers: {
        Authorization: `Bearer ${config.frontegg.accessToken}`,
      },
    });

    const existingApp = apps.find((app) => app.name === config.app.name);

    if (existingApp) {
      console.log(`   ℹ️  Found existing, updating: ${existingApp.id}`);

      // Update existing application
      const updateUrl = `${config.frontegg.apiUrl}/applications/resources/applications/v1/${existingApp.id}`;
      await makeRequest(updateUrl, {
        method: "PATCH",
        headers: {
          Authorization: `Bearer ${config.frontegg.accessToken}`,
        },
        body: payload,
      });

      console.log(`   ✅ Updated: ${config.app.name}`);
      return existingApp.id;
    }

    // Create new application
    console.log(`   ℹ️  Not found, creating: ${config.app.name}...`);
    const createUrl = `${config.frontegg.apiUrl}/applications/resources/applications/v1`;
    const result = await makeRequest(createUrl, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${config.frontegg.accessToken}`,
        "frontegg-environment-id": config.frontegg.clientId,
      },
      body: payload,
    });

    console.log(`   ✅ Created: ${config.app.name}`);
    return result.id;
  } catch (error) {
    console.error(`❌ Failed to register application: ${error.message}`);
    throw error;
  }
}

/**
 * Main execution
 */
async function main() {
  console.log("🚀 Registering Application with Frontegg");
  console.log("=========================================\n");

  try {
    // Step 1: Authenticate
    await authenticateFrontegg();

    // Step 2: Register application
    await registerApplication();

    console.log("\n✅ Application successfully registered with Frontegg!");
    console.log("\n💡 Registered configuration:");
    console.log(`   - App Name: ${config.app.name}`);
    console.log(`   - App URL: ${config.app.url}`);
    console.log(`   - Login URL: ${config.app.loginUrl}`);
    console.log("\n✨ Automatic Frontegg Configuration:");
    console.log("   The following are automatically configured via {{APP_URL}} placeholder:");
    console.log(`   • Allowed Origin: ${config.app.url}`);
    console.log(`   • Redirect URL: ${config.app.url}/oauth/callback`);
    console.log("   No manual portal configuration needed!");
    console.log("\n📝 Next steps:");
    console.log("   1. Configure your development environment secrets:");
    console.log("      Run: secretspec check --profile development");
    console.log("      This will identify missing values and prompt you to input them");
    console.log("   2. Start your development server: devenv up");
    console.log(`   3. Open ${config.app.url}`);
    console.log(`   4. Test login - you should be redirected to ${config.app.loginUrl}`);
  } catch (error) {
    console.error("\n❌ Registration failed:", error.message);
    console.error("\n💡 Troubleshooting:");
    console.error("   1. Verify your Frontegg credentials are correct");
    console.error("   2. Check that FRONTEGG_BASE_URL matches your Frontegg environment");
    console.error("   3. Ensure you have admin access to the Frontegg vendor portal");
    process.exit(1);
  }
}

// Run the script
main();
