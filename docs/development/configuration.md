# Development configuration

Run `make setup` from the repository root to install dependencies and create the two local files listed below. Rerunning setup preserves your edits. The offline preview works without either file. [Project quickstart](../../README.md#run-the-complete-foundation)

| Consumer | Committed example | Local file | When changes take effect |
| --- | --- | --- | --- |
| NestJS, database CLI and Compose | [Backend environment](../../backend/.env.example) | `backend/.env` | Restart Nest or rerun the CLI. Container initialization settings apply to a new volume. |
| Flutter | [Public build configuration](../../config/development.example.json) | `config/development.local.json` | Stop and relaunch the app with the define file, or rebuild the artifact. |

## Backend setup and precedence

Nest and the database CLI resolve `backend/.env` from both the TypeScript source and compiled JavaScript entry points. Existing process variables take precedence. An invalid explicit value fails validation. When the process sets `NODE_ENV=test`, both skip the file and use the supplied test environment. Automated database tests provision their own Compose project.

Run direct backend and Compose commands inside `backend/`. For example, `PORT=3001 npm run start:dev` overrides the API port for a single run. `HOST` controls where Nest listens. `DB_HOST` tells Nest where to reach PostgreSQL. The client-facing API address depends on the device.

Choose the application role, database name and both passwords before creating the database. Initialization scripts run once on a fresh volume. Changing an existing role's password requires an administrator SQL change. Multiple checkouts running concurrently need distinct Compose project names and host ports. [Backend variables](../../backend/README.md#configuration) · [Database troubleshooting](../../backend/README.md#troubleshooting)

## Flutter setup

The default local file targets a Linux desktop or a USB-forwarded Android device.

```json
{
  "API_BASE_URL": "http://127.0.0.1:3000/api/"
}
```

Run `make app` from the root. It selects Linux and passes the JSON with `--dart-define-from-file`. Use `make app DEVICE=emulator-5554` with your actual device ID and URL. Use the same Flutter flag for a configured build. The API URL is compiled into the app, so changing it requires a restart or rebuild.

### API URL rules

`AppConfig` accepts an absolute HTTP or HTTPS URL with a hostname and valid port. Credentials, whitespace, a query string, and fragments are rejected at startup. Validation errors name the key without echoing its value. Include the backend's `/api/` prefix. The parser normalizes a missing trailing slash so the relative path `health/ready` preserves that prefix.

When the key is omitted, desktop debug builds use the offline preview. Android shows a configuration message. To explicitly run the sample UI on Android, use `flutter run --debug --dart-define=PLOGGR_PREVIEW=true` with no API URL. A configured app sends its first readiness request when the user taps **Check connection**. Tests can override `appConfigProvider` explicitly.

## Device addresses

| Flutter target | API URL with default port | Nest setting |
| --- | --- | --- |
| Linux desktop | `http://127.0.0.1:3000/api/` | `HOST=127.0.0.1` |
| Android emulator | `http://10.0.2.2:3000/api/` | `HOST=127.0.0.1` |
| Physical Android device with USB forwarding | `http://127.0.0.1:3000/api/` | `HOST=127.0.0.1` |
| Device on the same LAN | `http://<computer-LAN-IP>:3000/api/` | `HOST=0.0.0.0` |

For LAN access, use the computer's actual address and allow the API port on the trusted local network. Database access stays on loopback. M1.8 verified Linux and the Android emulator. M1.7 verified a USB-forwarded Android phone. [USB forwarding](connection-check.md#android-over-usb) · [Validation evidence](foundation-validation.md#validation-evidence)

## Public configuration and secrets

Flutter build defines are visible to anyone with the app. Use them only for public settings. Keep database credentials on the server. Git ignores local environment files, local JSON, and signing material. Check those rules from the repository root without printing file contents.

```bash
git check-ignore backend/.env config/development.local.json
```

## Validation

After setup, run `make check` from the repository root. To verify the public JSON-to-provider path specifically, run the following command. The full `make validate` workflow also runs this case.

```bash
flutter test --dart-define-from-file=config/development.example.json test/core/config/app_config_test.dart
```

## Android authentication sessions

With a configured API URL, the Android root initializes the Riverpod
`sessionControllerProvider`. Its controller exposes `signup`, `login`,
`accessToken`, and `logout` for feature code. On configured Android builds, onboarding opens live Login and Sign Up.
Signup requires an email and a 15–128 character password. A protected route
opened before sign-in resumes after successful authentication. Use **Skip → Sign up** to create the account, or **Skip → Login** for an existing account.
Desktop development and explicitly selected Android preview builds retain **Explore the preview**.
Configured Android stays in live mode during outages. Release builds require Android and an HTTPS API URL.

A successful signup or login returns an identity and a device session. The
controller publishes the identity after saving the refresh credential in
Android Keystore-backed secure storage. The record is scoped to the API base
URL and excluded from Android cloud backup and device transfer. Access JWTs
live in memory. Expiry triggers renewal. Startup and foreground retry can
recover the session after a restart or network outage. A network or storage
failure opens a session check with **Retry**. A rejected refresh clears the record and opens Login.

Before rotating, the controller saves a UUID request ID with the refresh token.
Retrying after a dropped response or interrupted write uses that ID again.
Concurrent callers share a renewal. Logout clears the local record and asks
the backend to revoke the device session. If the API is unreachable, local
sign-out still takes effect and the UI reports that server sign-out could not be confirmed.
Choose **Profile → Settings → Log out**. Logout clears navigation history and in-memory
activity. If secure deletion fails, **Retry logout** finishes the operation. An app-private
boolean keeps restoration blocked across a process restart until deletion succeeds.
Uninstall and clear-data remove device access. Android sends no server-side
revocation callback for uninstall.

Settings loads the signed-in email from the protected `GET auth/me` endpoint.
For protected feature calls, use `protectedApiProvider` with a method and a
relative API path. It attaches a bearer token for this API, shares concurrent
renewal requests and retries a rejected GET or HEAD once. Callers decide how
to recover a failed write. Public health and authentication calls continue
to use `apiClientProvider`.

### Android acceptance check

For the complete run, start an empty Android emulator and run
`make validate-auth DEVICE=emulator-5554` using its serial. The runner starts
its own API and database. [M2 acceptance report](authentication-validation.md)

To run the device checks individually, follow the steps below.

Use an empty, disposable emulator and a disposable local backend. Set
`AUTH_ACCESS_TTL_SECONDS=12` in that backend's environment before starting
Nest. Run the following from the repository root, substituting the emulator
serial and the API's host port.

```bash
tool/test_android_session.sh emulator-5554 3000
```

The script installs a debug probe, uses ADB reverse, and exercises the production
controller and secure storage against the real API. It verifies the same user
after force-stop, rejection of the expired access JWT, silent renewal, logout,
clear-data, uninstall/reinstall, revoked sessions, network recovery, and offline logout.
The probe creates disposable accounts. The
script removes its APK and forwarding rule on exit. Unit tests for storage and
network failures run with `flutter test test/features/auth`.

To exercise the real signup and login screens, Settings email, account switching,
and Back after logout, run the UI test against the same disposable API. Restore
USB forwarding after the probe exits, or use the emulator host address below.

```bash
flutter test -d emulator-5554 integration_test/auth_flow_test.dart --dart-define=API_BASE_URL=http://10.0.2.2:3000/api/
```

## Android Plog location

**Start Plog Session** checks for an active walk. Route recording uses Android foreground location with a three-meter movement filter. **Continue without a route** keeps the timer and pickup photos available when location is denied or unavailable. **Pause** stops the timer and GPS subscription. **Resume** starts a new route segment so distance excludes movement during the pause.

**Add pickup** opens the camera. **Choose from gallery** uses Android’s picker. The app stores one to six photos in the account’s private SQLite draft and accepts JPEG or PNG up to 8 MiB each. A fresh, accurate route fix can suggest nearby open sightings for a new camera photo. A linked spot can be confirmed offline. Gallery photos can be linked manually. Confirming a cleanup queues the supporting photo and spot update together. The open map changes after the server acknowledges it.

**Finish Plog** asks before ending the walk. Review the photos, then **Save Plog**. An interrupted save keeps its timestamps, route segments, photos and upload IDs. Use **Resume Plog Session** and **Retry save** after reconnecting. The completed record opens directly in My Activity.

## Maps and reporting

**Report** shares an open litter sighting. Search for a park or street, tap the map or move it underneath the pin. **Use my location** is optional and shows the reported GPS accuracy. **Use this spot** confirms the corrected position. The map remembers the selected area for that account. Open sightings have photo cards and map markers. Larger areas show counts, and List stays available when tiles fail.

`MAP_STYLE_URL` selects the MapLibre style at Flutter build time. The default is OpenFreeMap Liberty. Nest’s `PHOTON_URL` selects the place search and reverse-geocoding service. Development uses Photon’s public demo by default. Configure your own instance or hosted endpoint for production. [Photon deployment](https://github.com/komoot/photon) · [OpenFreeMap](https://openfreemap.org/quick_start/)

## Photo analysis, ranking and account services

Set server-side values in `backend/.env` and restart Nest after changes.

| Setting | Purpose |
| --- | --- |
| `GEMINI_API_KEY`, optional `GEMINI_MODEL` | Enable the photo-analysis worker. The default is `gemini-3.8-flash`. Completed activities queue until a worker is configured. |
| `GEMINI_FALLBACK_MODELS` | Up to two comma-separated Gemini model IDs in order of preference. The default is `gemini-3.5-flash-lite,gemini-3.8-flash`. The worker tries each unique model at most once per queue attempt. Set an empty value to use only the primary. |
| `MODERATOR_IDS` | Comma-separated Ploggr account UUIDs with access to flagged content and uncertain pickup photos under Profile → Moderation. |
| `AUTH_OIDC_ISSUER`, `AUTH_OIDC_CLIENT_ID`, `AUTH_OIDC_METHODS` | Auth0 native application, HTTPS tenant origin and enabled connections. Methods may include `google,apple,phone`. Set the native callback to `com.example.ploggr.auth://callback` and enable the associated Google, Apple or SMS connections on the tenant. |
| `RESEND_API_KEY`, `MAIL_FROM` | Enable password recovery with a verified sender. The app offers an eight-digit code that expires after 15 minutes. A successful reset revokes existing Ploggr sessions. |

The login page loads available methods from the server. Authentication uses the browser and PKCE for external connections. The backend exchanges the returned authorization code and issues a Ploggr session. [Auth0 native authorization](https://auth0.com/docs/get-started/authentication-and-authorization-flow/authorization-code-flow-with-pkce/call-your-api-using-the-authorization-code-flow-with-pkce) · [Email delivery](https://resend.com/docs/api-reference/emails/send-email)

The worker normalizes image orientation, strips metadata and sends up to six distinct pickup photos to Gemini together. Gemini classifies visible litter by material and type, counts objects across views and returns each group's estimated weight and plausible range. Sealed bags, indistinct objects and uncountable piles can have an unavailable count or weight. Unclear results and similar photos enter moderation. Activity details can retry a failed job, refresh an unreviewed legacy result or report a prediction for review. Credentials and storage keys stay on the server. [Gemini structured output](https://ai.google.dev/gemini-api/docs/structured-output)

Timeouts, rate limits and temporary Gemini errors trigger model fallback. If available models cannot complete the job, temporary failures stay queued with exponential backoff, capped at about 15 minutes unless Gemini requests a longer delay. The worker skips models during their cooldown, and a successful analysis records the responding model. Completed Plogs and photos remain available throughout. The configured models share the Gemini API and project key, so a provider-wide outage can delay every model. [Gemini retry guidance](https://ai.google.dev/gemini-api/docs/troubleshooting#retry-strategy)

For supported material and type combinations, the app estimates the difference between US-average landfill emissions and recycling or composting. The central estimate and range use the same disposal factors and propagate the Gemini weight range. They represent potential savings, with locally applicable disposal and actual handling left unverified. The activity shows which groups have estimates, the paths compared and the factor source. Users can also record weighed material and their declared disposal paths using imported factors. [EPA WARM v16 management practices, Exhibit 1-1](https://www.epa.gov/system/files/documents/2024-01/warm_management_practices_v16_dec.pdf)

Leaderboard periods use UTC calendar weeks and months. The default policy awards one point per eligible item and two bonus points per modeled kg CO₂e, capped at ten bonus points and 100 total points per Plog. Eligibility requires a completed, verified cleanup claim supporting the identified items. Reused evidence and analyses awaiting moderation are excluded. Leaderboard and activity points use the same calculation, so results reflect the current review and scoring policy. User-entered disposal details have no effect on ranks.

To import approved data, run `npm --prefix backend run impact:import -- /absolute/path/to/policy.json`. Supply one or both JSON fields.

| Field | Contents |
| --- | --- |
| `factors` | Array of objects with `region`, `material`, `pathway`, `factor` in kg CO₂e per kg, a published HTTPS `source`, and `version`. Both pathways must use the same region, material and version. |
| `rules` | Object with `version`, `materialPoints` mapping material names to points per item, and `carbonPointsPerKg`. Import activates that version atomically. |

Use material names from the authenticated `GET /api/impact/classification` endpoint. Supply a new version for revised factors or scoring weights. The imported scoring policy overrides per-item values and the carbon bonus rate. The M3 caps and cleanup eligibility apply to all policies.
