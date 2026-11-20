# Core Plog and GPS validation

Run the M3 acceptance check from the repository root. It uses the production
Nest application, PostgreSQL/PostGIS migrations and Android tracking screens.
The debug-only app entry point creates a disposable account and observes the
measurements across an actual app process restart. [M3.8 acceptance criteria](https://github.com/devBuildersunique/ploggr/issues/27)

## Run on an Android emulator

Use the development prerequisites from the root quickstart, Python 3, and a
running Android emulator with location enabled and no Ploggr installation.
Choose the device serial from `adb devices`.

```bash
make validate-plog DEVICE=emulator-5554
```

The runner creates a disposable database and API, installs the test APK,
selects Android permission buttons and sends simulated coordinates. It removes
the APK, port forwarding rule and Compose project when it finishes. On M4 branches this runner also exercises the camera, gallery and private image storage. The final line is `Android Plog tracking, evidence and completion validation passed.` [Emulator requirements and evidence checks](evidence-validation.md)

| Scenario | What the check observes |
| --- | --- |
| Start | Home starts an authenticated activity. The HTTP contract also checks anonymous requests and a second start. |
| Permission and GPS | The host denies Android's permission prompt, retries from the Plog screen and grants foreground access. The app receives two known emulator locations in the active session. |
| Finish during an outage | The runner stops the API before tapping Finish. The app stores the end time, full route, duration and distance locally. A further device fix leaves the frozen activity intact. |
| Recover | The host force-stops the app, restores the API and reopens the app. Retry submits the frozen track. The account has one completed activity and clears its local draft after confirmation. |
| Retrieve | The app opens activity details. The probe compares every returned coordinate, both timestamps, seconds and meters to the pre-restart snapshot. HTTP integration tests exercise owner filtering, pagination and invalid transitions. |

Android receives simulated GPS fixes in this check. Physical-device accuracy,
battery consumption and tracking with the app backgrounded require separate
field measurements.

## Verified run

On November 20, 2026, the Android check passed on a fresh API 37 x86-64
emulator with Flutter 3.50.0, Node 26.13.1, PostgreSQL 18.7 and PostGIS 3.7.0.
It passed 209 Flutter tests, 53 backend unit/HTTP tests and 21 database
integration tests before driving the device. The route survived both the API
outage and app process restart. Android removed the app's location listener
at Finish, and the extra emulator fix did not alter the saved track.

The full Linux build and live API/database outage-and-recovery check also passed with `make validate`.
