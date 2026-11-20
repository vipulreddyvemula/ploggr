# Backend maintainer guide

Use this guide when changing an API module or migrating the database. Run the commands from `backend/`. For local setup, start with the [backend quickstart](../README.md#first-time-setup). For the current full-stack test results, see the [foundation validation report](../../docs/development/foundation-validation.md).

## Architecture

`AppModule` loads validated configuration, the database infrastructure, and the
health module. `DatabaseModule` uses `TypeOrmModule.forRootAsync` to expose an
injectable TypeORM `DataSource` globally. The standalone CLI creates a data source
from the same options without starting NestJS.

- NestJS runs on the host. Compose runs only the PostgreSQL/PostGIS database.
- Both entrypoints validate `DB_*` values; process environment variables take
  precedence over `.env`. Both resolve the same backend file independently of
  working directory and skip it when the process environment has `NODE_ENV=test`.
  NestJS additionally validates its server settings.
- Register entities and migrations explicitly. Schema synchronization, automatic migrations, and automatic extension installation are disabled.
- Startup makes three connection attempts, with one-second retry delays and a
  five-second connection timeout. Queries/statements also have five-second
  timeouts. Future long migrations must account for those limits explicitly.
- Shutdown hooks close the connection pool. The check CLI also closes its pool
  on completion and exits nonzero on failure without printing credentials.

### Provisioning and permissions

The image tag `postgis/postgis:18-3.7` selects PostgreSQL 18 and PostGIS 3.7; its
upstream patch contents may change. The PostgreSQL 18 volume is mounted at
`/var/lib/postgresql`. Major database upgrades require a deliberate migration;
changing the image tag is not a volume upgrade procedure.

The image's initialization script installs PostGIS in the configured database.
`20-app-role.sh` then creates the application role and grants schema usage/create
privileges. NestJS and migrations use that role, which cannot create databases,
create roles, or act as a superuser. `POSTGRES_PASSWORD` is used only for
administrator provisioning. SQL inspection in the setup guide uses a separate
administrator session inside the container.

Provisioning scripts run only for an empty volume. Changing `.env` credentials
or database names does not alter existing roles/databases. Preserve required data;
use intentional administrator SQL changes or reset disposable development data
as described in [troubleshooting](../README.md#troubleshooting).

## Migrations

Run migrations explicitly before starting the backend. From `backend/`, inspect
and apply pending migrations:

```bash
npm run migration:show
npm run migration:run
npm run migration:show
```

The foundation migration calls `PostGIS_Full_Version()` to assert that privileged
provisioning has already installed PostGIS. Success is recorded in `migrations`.
The next migration, `CreateUsers`, creates the `users` table on fresh databases
and existing M1 volumes. Extension-owned tables and schemas are expected.

### Roll back intentionally

To revert the most recently applied migration, run this separately:

```bash
npm run migration:revert
```

Review that migration's `down()` implementation first. The M1.5 migration removes
only its history entry on rollback and deliberately retains PostGIS. Reverting
`CreateUsers` drops the `users` table and deletes its rows. It preserves PostGIS
and the M1 migration record. `npm run migration:run` recreates an empty table
after that rollback.

### Add a future schema change

To write a migration by hand, start with an empty file.

```bash
npm run migration:create -- src/database/migrations/DescribeChange
```

For a generated migration, first add the intended entities to the shared
`entities` list in `src/database/database.config.ts`, then compare them against
a development database with all existing migrations applied:

```bash
npm run migration:generate -- src/database/migrations/DescribeChange
```

Review the SQL and both
`up()`/`down()` methods. Import the new migration class into the shared `migrations`
list so NestJS, source CLI tools, and compiled execution use the same definitions.
Keep existing applied migrations unchanged; create a new migration for subsequent
schema changes. Test new migrations against a disposable database.

### Run compiled migrations

After `npm run build`, the following commands load JavaScript from `dist/`:

| Command | Purpose |
| --- | --- |
| `npm run migration:show:prod` | List applied and pending migrations |
| `npm run migration:run:prod` | Apply pending migrations |
| `npm run migration:revert:prod` | Intentionally revert the most recent migration |
| `npm run db:check:prod` | Check PostgreSQL connectivity and PostGIS |

The `:prod` suffix selects compiled execution; it does not change environment
variables, enable TLS, or configure a production deployment.

## User identity persistence

PostgreSQL generates each user's UUID. Later ownership columns can reference
`users.id` as a foreign key. The database requires a nonempty, lowercase email
with surrounding spaces removed and enforces uniqueness on that value.

Nest modules can import `UsersModule` and inject `UsersService`. `create` accepts
an email and a precomputed password hash. `findByEmail` and `create` both use
PostgreSQL's `lower(btrim(...))` to normalize the email. `findById` accepts a UUID.
Both lookup methods return `null` on a miss. Results contain `id` and `email`,
and TypeORM omits `password_hash` from ordinary entity reads. Attempts to reuse
an email fail on `users_email_key` with PostgreSQL code `23505`, even when the
inserts run concurrently.

## Plog activity persistence

Each row in `plogs` represents one cleanup activity. Its UUID is stable across
the activity's lifetime. The required `user_id` references `users.id`, so signing
out or rotating a session leaves the activity attached to its owner. The lifecycle API
uses the authenticated user's ID when starting or looking up a Plog. [M3.1 data model](https://github.com/devBuildersunique/ploggr/issues/20) · [M3.2 lifecycle API](https://github.com/devBuildersunique/ploggr/issues/21)

A new Plog defaults to `active` with a start time and zero measurements. A
partial unique index on the owner allows only one active Plog per user, even
when two starts arrive together. A completed Plog has an end time at or after
its start. Both timestamps are timezone-aware. Duration is measured in whole
seconds and distance in meters, including fractions of a meter.

Each GPS fix is a row in `plog_route_points` with a PostGIS
`geography(Point, 4326)` value. Coordinates use WGS 84 and the GeoJSON order
`[longitude, latitude]`. A Plog can start with zero fixes and retain a single
fix. For a route, read the points in ascending `sequence` order. The primary
key on `(plog_id, sequence)` prevents two fixes from occupying the same position
and lets different Plogs use the same sequence numbers. For example, this psql
query reads the route in recording order for one Plog.

```sql
\prompt 'Plog UUID: ' plog_id
SELECT sequence, ST_AsGeoJSON(location)::json AS point
FROM plog_route_points
WHERE plog_id = :'plog_id'
ORDER BY sequence;
```

Deleting a Plog also deletes its points. Deleting a user deletes that user's
Plogs. Reverting `CreatePlogs` drops both activity tables and their data.
Run `npm run test:database` to exercise the migration on an isolated database,
including rollback and reapplication with an existing M2 user and session.

## Structure

```text
src/
├── main.ts                 # Bootstrap, configured listen address, shutdown hooks
├── app.module.ts           # Root module and shared providers
├── app.setup.ts            # Global prefix and request validation
├── config/                 # Environment validation and defaults
├── database/               # Shared options, Nest module, CLI checks, migrations
├── common/filters/         # Shared HTTP error handling
└── modules/health/         # Health module and controller
test/
├── health.e2e-spec.ts             # Health and shared HTTP policy tests
├── database.integration-spec.ts   # Real PostgreSQL/PostGIS integration tests
├── commands.mjs                   # Bounded test subprocesses and signal handling
├── run-database-integration.mjs   # Isolated Compose test lifecycle
└── setup-env.cjs                  # Configuration for database-free tests
```

Add future features under `src/modules/<feature>/` and import their module in
`AppModule`. Keep controllers, DTOs, and any required services with their feature;
put reusable infrastructure in `common/`. The health controller delegates live
dependency checks to its service while keeping the process check static.
The server and HTTP tests use the same `configureApp` function.

## Request and response conventions

- Routes start with `/api`; feature controllers declare only their relative path.
- Requests with bodies use `Content-Type: application/json` and camelCase fields.
- Define validated input using DTO **classes** and `class-validator` decorators.
  The global pipe transforms inputs to DTO instances and rejects undeclared fields
  and invalid values with HTTP `400`. Primitive coercion is not enabled implicitly;
  use explicit parsing pipes or DTO transforms when needed.
- Success responses are JSON objects returned directly by controllers, without a
  global envelope. Use HTTP `200` for reads, `201` for creates, and `204` for actions
  with no response body. Each future endpoint should document its payload.
- Errors use the envelope below. `message` is a string for ordinary errors or an
  array of strings for DTO validation failures. Timestamps are UTC ISO 8601;
  `path` excludes the query string. Handle status codes rather than parsing messages.
- Throw Nest HTTP exceptions for expected client errors. Server failures are logged
  and return a generic message without stack traces or implementation details.

```json
{
  "statusCode": 404,
  "error": "Not Found",
  "message": "Cannot GET /api/missing",
  "path": "/api/missing",
  "timestamp": "2026-11-17T00:00:00.000Z"
}
```

### Readiness contract

`GET /api/health` remains the process check and returns `{"status":"ok"}` without
querying PostgreSQL. `GET /api/health/ready` performs a fresh, read-only query using
the existing TypeORM pool and its five-second connection/query/statement limits.
It checks `SELECT 1`, the PostGIS version function, and an SRID 4326 operation in
one statement. No version strings, SQL diagnostics, or credentials are returned.

Readiness success is HTTP `200`, `Cache-Control: no-store`, and:

```json
{"status":"ok","database":"up","postgis":"up"}
```

Any failed query/assertion becomes HTTP `503` with the existing error envelope.
The filter intentionally retains its generic server-error message. Flutter maps
the status and does not parse error messages or expose raw exceptions. Another
2xx payload is not sufficient for a green connection result.

## Milestone records

These results describe the code and tools exercised at the time of each review. Current reproduction steps are in the [contributor guide](../../CONTRIBUTING.md#check-and-submit).

### M1.5 review checklist

Database provisioning and migrations. [Issue #6](https://github.com/devBuildersunique/ploggr/issues/6)

| Requirement | Review | Verification |
| --- | --- | --- |
| Reproducible development database | [Compose service](../compose.yaml), named volume, loopback-only port | Fresh isolated Compose startup; container recreation preserves migration history |
| Backend connects to PostgreSQL | [Shared options](../src/database/database.config.ts), [Nest module](../src/database/database.module.ts) | Real Nest startup, HTTP health response, pool shutdown, unavailable-database startup failure |
| PostGIS is enabled and usable | Image initialization precedes [role setup](../docker/init/20-app-role.sh) | Version query and SRID 4326 spatial operation succeed |
| Configuration is reproducible | [.env.example](../.env.example), [validation](../src/config/environment.ts) | Unit tests cover credentials, ports, defaults, and environment precedence |
| Migrations are established | [Foundation migration](../src/database/migrations/1794873600000-VerifyPostgis.ts) and standalone CLI | Initial run, repeated run, revert/reapply, and compiled migration commands |
| No premature domain schema | Empty entity list; only migration metadata is application-owned | Integration test excludes extension-owned tables and expects only `migrations` in `public` |

#### Recorded validation

The 17 November 2026 run covered the following checks.

- Build, lint, TypeScript checking, and all 35 unit/HTTP tests.
- All six PostgreSQL/PostGIS integration tests.
- Source database check and compiled migration/check commands.
- Migration history surviving container recreation.
- Backend exit status 1 with wrong credentials or an unavailable database.
- Removal of the test project's containers and volume after the suite.

The recorded environment was Linux/x86-64, Node.js 26.13.1, npm 11.20.0, Docker
29.9.2, PostgreSQL 18.7, and PostGIS 3.7.0. M1.8 later verified the Node 24 baseline.

### M1.6 review checklist

Environment configuration. [Issue #7](https://github.com/devBuildersunique/ploggr/issues/7)

| Requirement | Review | Verification |
| --- | --- | --- |
| Flutter API URL comes from configuration | [AppConfig](../../lib/core/config/app_config.dart), [provider](../../lib/core/config/app_config_provider.dart), [bootstrap](../../lib/main.dart) | Invalid URLs fail validation; no declaration preserves the preview; provider overrides work |
| Public example and local configuration | [JSON example](../../config/development.example.json) and root ignore rules | Define-file configuration tests pass; local JSON is ignored |
| Backend file policy is consistent | [Shared policy](../src/config/environment-file.ts), Nest module and standalone data source | Absolute backend file path, process precedence, test isolation, source/compiled path checks |
| Secrets remain server-side | Backend example and ignored local files; Flutter example contains only an API URL | No credential values are emitted by validation errors; no local config is staged |
| M1.5 remains functional | Existing database module and migrations | Build/lint/type checking, unit/HTTP tests, and isolated PostgreSQL/PostGIS integration suite pass |

#### M1.6 recorded validation

On 18 November 2026, local validation passed Flutter analysis and all 148 Flutter
tests, plus all 24 configuration tests with the committed JSON define file.
Backend build, lint, type checking, all 40 unit/HTTP tests, and all six database
integration tests passed. Source and compiled configuration resolved the same
backend `.env` from the repository root, `backend/`, and an unrelated temporary
working directory. Documentation links/anchors, command syntax, example visibility,
and local-file ignore rules were also checked. The isolated test containers and
volume were removed successfully.

This run used Flutter 3.50.0 / Dart 3.14.0 and the Node.js/Docker versions listed
in the M1.5 record above. It verifies configuration and backend/database behavior;
mobile HTTP connectivity is covered by M1.7's separate validation below.

### M1.7 review checklist

Flutter, API and database communication. [Issue #8](https://github.com/devBuildersunique/ploggr/issues/8)

| Requirement | Review | Verification |
| --- | --- | --- |
| Configured Dio client | [Client provider](../../lib/core/network/api_client_provider.dart) | Configured base URL/prefix, bounded timeouts, owned-client cleanup |
| Backend queries PostgreSQL/PostGIS | [Health service](../src/modules/health/health.service.ts) | Read-only query, connectivity/PostGIS/SRID assertions, real database readiness test |
| Flutter handles success and failures | [Connection feature](../../lib/features/connection/connection_service.dart) and Settings screen | Payload validation, HTTP/transport/timeouts, retry, missing configuration, cancellation |
| Native phone connection | Internet permission and debug-only Android HTTP policy | USB-authorized physical phone and `adb reverse`; native integration test |
| Complete real stack | [Native integration test](../../integration_test/connection_check_test.dart) | Real Settings button → Dio → HTTP → PostgreSQL/PostGIS on Linux and Android |
| Foundation scope preserved | Existing entities/migrations and preview data | No new tables, authentication, or domain persistence |

#### M1.7 recorded validation

On 18 November 2026, Flutter analysis and all 180 ordinary Flutter tests passed,
including 27 connection service/screen tests. Backend build, lint, TypeScript
checking, all 45 unit/HTTP tests, and all six isolated database integration tests
passed. The real database suite also verified the readiness endpoint.

The opt-in native test passed on Linux and on a physical Android phone, model
`2312DRA50I`, running Android 16 (API 36), connected over USB with `adb reverse`.
The phone completed success → database unavailable → success across a controlled
PostgreSQL stop/restart. Linux also verified the success and unavailable screens.
During the outage the same API process returned `200` for `/api/health` and `503`
for `/api/health/ready`; after restart readiness returned `200` without restarting
NestJS. The live tests used a separate disposable database and API port.

This run used Flutter 3.50.0, Dart 3.14.0, Dio 5.11.1, Node.js 26.13.1, Docker
29.9.2, PostgreSQL 18.7, and PostGIS 3.7.0. Documentation links/anchors, shell/JSON
examples, Android XML, and the debug-only placement of the HTTP policy were
checked. The temporary services and test USB forwarding were cleaned up afterward.

## Authentication

Run `make setup` or, from the backend directory with a local .env, run
`node tool/setup-auth-key.mjs`. Keep AUTH_SECRET (32 random bytes in hex) stable
across API restarts and replicas. Supply it via the environment in production
and use HTTPS for credentials. Database CLI commands use only DB settings.
Changing the key invalidates access JWTs and outstanding encrypted retry results.

All routes below are under `/api/auth`. Signup and login accept email and
password. Signup requires 15–128 characters. The API preserves password spaces
and uses Argon2id. Both return a user object (id and email), accessToken and
refreshToken. Validation failures return 400, duplicate signup 409, and wrong
login credentials 401. Signup returns 201 and login returns 200.

Access JWTs default to 900 seconds. AUTH_ACCESS_TTL_SECONDS accepts 1–900 for shorter lifetimes.
Send the access JWT as a bearer token to GET me. POST refresh accepts
refreshToken and a UUID v4 requestId. Persist this ID before the request and
reuse it on retry. A retry returns the same successor while that successor
is current. A spent token presented under a different ID revokes the device
session. POST logout accepts refreshToken and returns 204 idempotently.
Each login has an independent session with no inactivity timeout. Session and
spent-token rows are deleted together on revocation or user deletion.

Run `npm run test:database` for the HTTP and PostgreSQL contract. Reverting
CreateAuthSessions signs out every device by dropping both session tables.
User identities and password hashes survive that rollback.

## Plog lifecycle API

All Plog operations require an M2 bearer token. `POST /api/plogs` starts an
activity and returns HTTP 201. A concurrent or repeated start returns 409.
`GET /api/plogs/active` returns an object with a `plog` field containing the
owner's active activity or null. Each summary includes id, userId, status,
startedAt, endedAt, durationSeconds and distanceMeters.

`POST /api/plogs/:id/finish` accepts endedAt (ISO 8601 with timezone),
durationSeconds, distanceMeters and an ordered route of up to 20,000 objects
with numeric latitude and longitude. An empty route is valid. The server locks
the owned activity and commits the measurements and fixes in one transaction.
An identical retry returns the saved result (200), a different completion
returns 409, and an unknown or foreign activity returns 404.

`GET /api/plogs` returns up to 25 completed summaries for the authenticated
owner, ordered by end time and then UUID descending. Supply the returned
`nextCursor` as the `before` query parameter for the next page.
`GET /api/plogs/:id` returns an owned completed summary and its ordered route
of latitude/longitude objects. An active, foreign or missing ID returns 404.
On Android, open **View activity** after saving or **My Activity** in Profile.

## Garbage evidence

Each garbage photograph has its own UUID and a required foreign key to a Plog.
Use the Plog's user association to determine ownership. The metadata records
the private storage key, media type, byte count, SHA-256 digest and upload
time. The digest lets an upload retry verify that it refers to the same bytes.
Reverting `CreateGarbageEvidence` removes the metadata table. Image bytes are
managed by the storage provider. [M4.1 data model](https://github.com/devBuildersunique/ploggr/issues/28)

### Private image storage

Run `make setup` to generate local credentials, then `make api`. Compose starts
SeaweedFS with a named volume and publishes its S3 port on loopback. The backend
uses the private bucket named by `EVIDENCE_S3_BUCKET`. For a managed S3 bucket,
set the bucket and region (`EVIDENCE_S3_REGION`), enable block public access,
and grant the backend workload role GetObject and PutObject on its evidence
prefix. For another S3-compatible service, set `EVIDENCE_S3_ENDPOINT` and the
backend-only `EVIDENCE_S3_ACCESS_KEY` and `EVIDENCE_S3_SECRET_KEY`. Use HTTPS
in production. Android receives image bytes through the authenticated API.

The Android client assigns each selected photo a UUID. Upload it with a bearer
token to `PUT /api/plogs/:plogId/evidence/:id` as multipart field `photo`.
The API decodes JPEG/PNG images up to 8 MiB and 32 megapixels and reserves a
slot on the owner's active Plog. A successful retry with the same ID and bytes
returns the original metadata. Each Plog has six slots. An interrupted storage
write keeps its reservation for retry and its image stays hidden until confirmed.

New Plogs require **one to six confirmed photos** at completion. Finish checks
the photo reservations under the same Plog row lock that serializes uploads.
It returns 422 if any upload is pending or if no photos have been stored. M3
activities already completed remain readable and support identical finish retries.
