# Ploggr field testing on Azure

The field APK connects to the public HTTPS endpoint for the field API. Its Android package is `com.example.ploggr.field`, so it installs alongside the local build. Sign up with your email or sign in to an existing field account. Install newer APKs over the previous field build to retain the Android session and drafts.

## Provision

Use an Azure for Students subscription with an active Standard registry allowance. Select a region permitted by the subscription that supports Container Apps. Use an existing student-covered PostgreSQL server where available. Give Ploggr its own database and role. Enable `postgis` in the server's extension allowlist, preserving existing entries. Run [database.sql](database.sql) as the server administrator on `postgres` with `PLOGGR_DB_PASSWORD` and `PLOGGR_SCALER_PASSWORD` in the environment. Run [scaler.sql](scaler.sql) as `ploggr_field` on `ploggr_field`. Use verified TLS for both connections. Keep any temporary administrator firewall rule only for setup.

Deploy [base.bicep](base.bicep) into the field resource group as deployment `ploggr-field-base`. Pass its outputs to [apps.bicep](apps.bicep) as deployment `ploggr-field-apps`. Supply its secure parameters in a private ARM parameters file. Use `sslmode=verify-full` and the `ploggr_field_scaler` role in the PostgreSQL scaler connection string. This uses the scaler's system trust store. The service uses a managed identity scoped to the private evidence container. The API and migration job share the Container Apps environment and PostgreSQL firewall access. If you restrict the server to individual egress IPs, include the environment's current egress addresses and revisit those rules when Azure changes the addresses.

Generate a persistent PKCS#12 Android key with alias `ploggr-field` and the same store and key password. Keep a secure backup. Run [configure-github.sh](configure-github.sh) with `AZURE_RESOURCE_GROUP`, `FIELD_KEYSTORE`, and `FIELD_KEYSTORE_PASSWORD` set. GitHub limits the signing secrets to deployments from `feature/live-litter-map`. Leave Gemini credentials on the backend and use a model covered by the Google project's quota.

## Deploy and verify

Push to `feature/live-litter-map`. The workflow validates the backend, pushes a versioned image, runs the PostgreSQL migration job, and deploys the image by digest. Azure probes database readiness before switching revisions. Failed migrations hold back deployment. After a failed readiness check the workflow reapplies the prior API template. Deploy backward-compatible database migrations so the previous API can still serve requests during rollout or rollback.

Android changes produce a signed `ploggr-field.apk` on the repository's GitHub Releases page. To repeat a deployment of the same commit, rerun its workflow. The **Run workflow** button becomes available once this workflow exists on the default branch. The APK contains the API URL and public Flutter settings.

Test on cellular with Wi-Fi off. Open the app after several idle minutes, start a walk, take a photo and save. Close the app and reopen it after processing to confirm the route, photo, analysis and reward. Repeat across a temporary loss of connectivity and confirm one completed activity. Place search requires a Photon deployment.

Track credit use for the field resource group after 48 hours and again after a week. Check registry coverage and Container Apps active usage, storage transactions and regional transfer. When the free registry benefit expires, re-evaluate the registry before continuing. Use a monthly $5 Azure budget if supported. Alerts notify you at the configured thresholds.
