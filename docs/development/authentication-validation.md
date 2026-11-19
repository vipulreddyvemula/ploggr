# M2.7 authentication acceptance report

M2.7 checks that the Android app and NestJS agree on who is signed in, which credentials are still valid, and when access ends. The protected resource for this milestone is `GET /api/auth/me`, which returns the account UUID and email. [Official acceptance criteria](https://github.com/devBuildersunique/ploggr/issues/17)

## Recorded run

**Passed. The Android authentication foundation is ready for M3 development.** Both the real-screen account flow and the Android process-restart and expiry suite passed. The backend recognized the same UUID after a fresh login and refused the previously accepted bearer token after logout. No critical authentication defect surfaced in these checks.

Validated on 19 November 2026 on top of M2.6 `e91d755`. The environment used Flutter 3.50.0, Dart 3.14.0, Node 26.13.1, PostgreSQL 18.7 with PostGIS 3.7.0, and an Android 17 x86-64 emulator (API 37). The run passed 202 Flutter unit/widget tests, 53 backend tests and 15 PostgreSQL integration tests. A separate `make validate` run from a clean source copy passed the Linux build, migrations, and API/database outage and recovery checks.

The production dependency audit (`npm --prefix backend audit --omit=dev`) reported zero high or critical findings and three moderate package findings across `glob`, `minimatch`, and their dependent `typeorm`. Android secure storage and the live API are the supported mobile path covered by this result. Offline logout clears this device's credentials. Server-side revocation requires connectivity.

## Reproduce the run

Use a Linux checkout with the project's Flutter, Node, Android SDK, ADB, and Docker Compose toolchains. Boot a disposable Android emulator with Ploggr uninstalled. From the repository root, substitute the serial shown by ADB.

```sh
adb devices
make validate-auth DEVICE=emulator-5554
```

The runner installs locked dependencies, runs Flutter analysis, unit and widget tests, and backend lint, type checks, and tests. It then starts an isolated PostgreSQL/PostGIS Compose project with random credentials and exercises the real HTTP and database contract. Both Android suites use the compiled NestJS API on loopback through ADB. The forms suite uses a 900-second access token to test explicit logout. The persistence suite uses 12 seconds to test natural expiry. Each suite removes its app and forwarding rule. The runner stops its API and removes its database volume before printing `M2 authentication validation passed.`.

## Acceptance evidence

| Check | What the tests observe |
| --- | --- |
| Account creation and rejection | A fresh install reaches Sign Up through onboarding. Invalid email and a short password show form errors. A valid submission creates an identity. Duplicate signup shows an actionable error and leaves device storage empty. The database contract verifies HTTP 400 for invalid input, 409 for a normalized duplicate, and a single account under concurrent signup. |
| Login and protected identity | An incorrect password leaves the app signed out with no stored session. Logging in with the original credentials returns the UUID created at signup. Settings displays the server's email, the protected client receives that UUID and email, and an anonymous HTTP request to the same route gets 401. |
| Online logout | An access token accepted by the backend immediately before tapping **Log out** is rejected with 401 after the UI's logout request receives 204. The old refresh credential is also rejected with 401. Android secure storage is empty, the protected client denies access, and Back cannot reopen Settings. Database tests verify removal of the session and its token rows. Another device signed into the same account retains access. |
| Restoration and expiry | A force-stopped Android app restores the same account UUID. The backend rejects the expired JWT and accepts its replacement. Server revocation returns the device to sign-in. Clearing app data or uninstalling and reinstalling also requires sign-in. |
| Offline and interrupted operations | With the ADB connection removed, startup reports an unavailable session. Reconnecting restores the original UUID. Offline logout clears local access across restart. Widget and controller tests exercise secure storage failures, retry after interrupted deletion, and a late request completing after logout. |
| Credential handling and account isolation | The Android test reads the refresh credential through Android secure storage and checks that the test password, access token, and refresh token do not appear in plaintext in app-private shared preferences. PostgreSQL stores an Argon2id password hash and a SHA-256 digest of the issued refresh token. Tests cover sanitized authentication failures and verify that a second account cannot see the first account's Settings identity or modified in-memory profile. |

The Android checks live in the [forms integration test](../../integration_test/auth_flow_test.dart) and [process-restart probe](../../tool/test_android_session.sh). The [backend HTTP contract](../../backend/test/auth.contract.ts) runs against PostgreSQL. [Flutter session tests](../../test/features/auth) cover failures and concurrency that are difficult to trigger deterministically on a device.
