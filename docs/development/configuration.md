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

When the key is omitted in a debug build, Flutter runs the offline preview and the connection button is disabled. A configured app sends its first readiness request when the user taps **Check connection**. Tests can override `appConfigProvider` explicitly.

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
Desktop development and unconfigured Android debug builds retain **Explore the preview**.
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

Starting an authenticated Plog requests location while using the app. Enable
device location and grant precise access for walking routes. If Android stops
offering the prompt, open the app's system permissions to allow Location, then
retry GPS. The tracker requests foreground fixes with a three-meter movement
filter and releases its subscription when tracking ends.
