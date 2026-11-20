# Ploggr

Ploggr is a Flutter app for people who pick up litter while walking or jogging. Its 18-screen preview lets you try a session, report sample litter, join a cleanup, and explore community and profile screens. Preview activity lives in memory until the app restarts.

**Profile → Settings → Connection check** calls NestJS, which runs a read-only spatial query against PostgreSQL and PostGIS. [Foundation decisions](https://github.com/devBuildersunique/ploggr/issues/2#issuecomment-5240945427)

The backend supports email/password authentication and renewable device sessions. Android can securely store a refresh token and restore the session after restart. On Android with a configured API, Login and Sign Up establish a live session. Profile → Settings shows the authenticated email and offers Log out. Desktop development and unconfigured debug builds retain the sample preview. [Authentication contract](backend/docs/maintenance.md#authentication) · [Android session verification](docs/development/configuration.md#android-authentication-sessions)

Signed-in Android users can start a Plog from Home, record a GPS route, and
finish tracking, then take or choose **1–6 garbage photos**. **Save Plog**
uploads the selected photos and confirms completion. **Profile → My Activity**
shows the route, measurements and private photos. An interrupted save can
resume from the Android draft after an app restart. [Android tracking](docs/development/configuration.md#android-plog-location) · [Plog API](backend/docs/maintenance.md#plog-lifecycle-api)

## Get a checkout

For ordinary development, clone upstream.

```bash
git clone https://github.com/devBuildersunique/ploggr.git
cd ploggr
```

While M1.8 is under review, clone the branch from the fork or local checkout that contains it. Replace `SOURCE` with that URL or path. The branch starts at M1.7 commit `e6abeeb`.

```bash
git clone --branch feature/m1.8-foundation-validation SOURCE ploggr-m18
cd ploggr-m18
```

## Run the complete foundation

The verified development path uses Linux x86-64, GNU Make, Flutter 3.50.0 (Dart 3.14), Node 24.15 or later in the 24.x line, npm, and Docker with Compose supporting `--wait`. The published PostGIS image targets amd64. Linux desktop builds require clang, CMake, Ninja, pkg-config, and the development headers for GTK 3 and libsecret. Check your toolchain with `flutter doctor -v` and Docker access with `docker info`. If you use nvm, select the project version with `nvm install 24 && nvm use 24`. [Flutter Linux setup](https://docs.flutter.dev/platform-integration/linux/setup)

Run these commands from the **repository root**.

1. Run `make setup` to install the dependencies recorded in both lockfiles and copy the example configuration. It preserves existing local files. Before the first database startup, choose separate application and administrator passwords in `backend/.env`.
2. In the first terminal, run `make api`. It starts PostgreSQL and private image storage, waits for readiness, applies pending migrations, then runs Nest in watch mode. Keep it running after `API listening at http://127.0.0.1:3000/api`.
3. In a second terminal, run `make app`. Choose **Skip → Explore the preview → Profile → Settings → Connection check → Check connection**. **Connected** confirms the full path.
4. Quit Flutter with `q`, stop Nest with Ctrl+C, then run `make down`. Your database and image volumes persist.

To check just the API and database with the default port, run the following in another terminal.

```bash
curl --fail-with-body http://127.0.0.1:3000/api/health
curl --fail-with-body http://127.0.0.1:3000/api/health/ready
```

Liveness returns `{"status":"ok"}`. Readiness returns `{"status":"ok","database":"up","postgis":"up"}`.

- **Android.** Install the Android SDK and select a device from `flutter devices`. Set the device-appropriate URL in `config/development.local.json`, then run `make app DEVICE=emulator-5554`, substituting your ID. [Device addresses](docs/development/configuration.md#device-addresses) · [USB setup and troubleshooting](docs/development/connection-check.md)
- **Flutter-only preview.** Run `flutter pub get --enforce-lockfile` and `flutter run` without defines. You can navigate the preview offline. The connection screen displays **No server configured**.
- **Backend-only development.** Run the npm and Compose commands directly from `backend/`. [Backend setup](backend/README.md#first-time-setup)
- **Parallel checkouts.** Set a unique `COMPOSE_PROJECT_NAME`, `DB_PORT`, `EVIDENCE_S3_PORT`, and `PORT` in the new checkout's `backend/.env`, set `EVIDENCE_S3_ENDPOINT` to the matching loopback storage port, then update the Flutter URL. Each checkout has its own database and image volumes. [Configuration reference](docs/development/configuration.md)

## How the project fits together

```text
Flutter screen → Riverpod controller → Dio → GET /api/health/ready
                                                  ↓
                                         NestJS health service
                                                  ↓
                                      TypeORM → PostgreSQL 18 + PostGIS 3.7
```

| Area | Where to work |
| --- | --- |
| Flutter entry and navigation | `lib/main.dart` validates configuration and creates the Riverpod scope. `lib/app.dart` mounts the router. Register destinations in `lib/routes/`. |
| Screens and networking | Screens, controllers and feature services live in `lib/features/`. The connection feature is a working HTTP example. Shared providers, theme and preview data live in `lib/core/`, and reusable widgets in `lib/shared/widgets/`. |
| API | Register Nest modules from `backend/src/modules/` in `AppModule`. Controllers expose relative routes under `/api`. Services own application logic. [API conventions](backend/docs/maintenance.md#request-and-response-conventions) |
| Database | Compose provisions PostgreSQL, PostGIS and the application role. Nest and the CLI share TypeORM options. Register explicit migrations in `backend/src/database/`. [Migration guide](backend/docs/maintenance.md#migrations) |
| Design | The design record maps screens to the bundled illustrations, font, and shared widgets. [Design notes](docs/design/implementation.md) · [Asset provenance](docs/design/assets.md) · [Visual validation](docs/design/validation.md) |

## Test and verify

| From the root | What it checks |
| --- | --- |
| `make help` | List the everyday commands. |
| `make check` | After setup, run Flutter analysis and unit/widget tests, then backend lint, type-checking and unit/HTTP tests. Works without Docker. |
| `make validate` | Install locked dependencies, build both applications, verify migrations and PostGIS, and drive a real Linux app through database and API outages and recovery. Uses a disposable Compose project and random ports. |
| `make validate-auth DEVICE=emulator-5554` | Verify signup, login, identity, session persistence, and logout on an empty Android emulator against an isolated API and database. [M2 acceptance report](docs/development/authentication-validation.md) |
| `make validate-plog DEVICE=emulator-5554` | Exercise location permission, GPS fixes, offline finish, process restart and activity retrieval on a disposable Android emulator. [M3 verification](docs/development/plog-validation.md) |
| `make validate-evidence DEVICE=emulator-5554` | Exercise Android camera and gallery, interrupted upload, retry, private storage restart and photo retrieval. [M4 verification](docs/development/evidence-validation.md) |
| `flutter build apk --debug` | Build an Android debug APK with the Android toolchain. |

Full validation requires Docker and a Linux display. Use `xvfb-run -a make validate` on headless Linux with Xvfb and xauth installed. CI runs the same Node runner. Expect `Foundation validation passed.` Use a separate checkout while a watch server or another build is using the same output directories. [Foundation validation and security report](docs/development/foundation-validation.md)

## Contribute

Open ordinary pull requests against `devBuildersunique/ploggr:main`. The contributor guide covers branching from a fork, locating the code and tests for a change, and preparing it for review. [Contributing to Ploggr](CONTRIBUTING.md)
