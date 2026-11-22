# Garbage photos and Plog completion

A signed-in Android user can add collected-litter photos during a walk or at
Finish. Saving requires one to six photos and an explicit review of linked
pickups. The original route and evidence are owner-only. Newly confirmed
reports share a sanitized image and pin with signed-in ploggers.
[Completion rule](https://github.com/devBuildersunique/ploggr/issues/32) · [M4.7 acceptance criteria](https://github.com/devBuildersunique/ploggr/issues/34)

## Reproduce the Android check

Use the root development prerequisites, Python 3 and a disposable API 37
Android emulator with the English system UI, system photo picker,
emulated back camera and location enabled. Start with Ploggr uninstalled.
From the repository root, substitute the serial printed by the first command.

```bash
adb devices
make validate-evidence DEVICE=emulator-5554
```

The runner creates two accounts, a database, an S3 bucket, a temporary API port and a gallery
album containing the repository's sample image. It installs a debug APK that
uses the normal Android screens, picker, SQLite draft store and authenticated
HTTP client. It removes the temporary album, APK, forwarding rule and Compose
project after the check. The M3 command `make validate-plog` runs the same flow.

| Check | Passing behavior |
| --- | --- |
| Post and discover | The reporter posts a gallery image, manually confirms a pin and adds a note. A second account can view the photo and start a Plog from that spot. |
| Track and finish | After a permission denial and retry, the app records two GPS fixes. Finish freezes the end time, distance and route before photo selection. |
| Select and capture | The system picker returns the gallery fixture. The in-app viewfinder captures another photo during the walk. Both appear in the current Plog draft. |
| Interrupt and recover | With the API stopped, saving leaves the Plog unconfirmed. The runner force-stops and reopens the app. Retry uses the frozen measurements and the two saved photo IDs. |
| Persist and display | After completion, the runner recreates the storage container using its existing volume. The authenticated API returns both photos in order, byte-for-byte identical to the draft. The activity screen displays the saved evidence, and the confirmed spot leaves the open map. |
| Ownership and privacy | The HTTP tests exercise missing authentication, cross-account reads and uploads, and anonymous bucket access. The API gives the owner image bytes and keeps the storage key private. |
| Upload boundaries | The HTTP tests cover invalid and truncated images, file size limits, concurrent attempts at the sixth slot, and retry with different bytes under an existing ID. |
| Partial failure | A failed storage write leaves a pending reservation. Finish rejects pending evidence, even when another photo is ready. An identical retry confirms it once. A missing stored image leaves the completed activity and its other photos readable. |

The Android success line is `Android Plog tracking, evidence and completion validation passed.`
For the backend contracts alone run `npm --prefix backend run test:database`.
The local storage service is SeaweedFS. A managed S3 deployment requires its
own private bucket and access configuration. [Backend storage setup](../../backend/docs/maintenance.md#private-image-storage)

## Native Android verification

On November 22, 2026, an API 37 emulator posted a gallery report, placed its map pin and started a Plog from a second account. Denying and retrying the Android location permission led to a tracked walk with a screen-off fix. With the API offline, the walker took a camera photo, confirmed the linked spot and added a second photo from the system picker. After force-stop and retry, the completed activity retained the route, both original images and their order across a storage restart. The collected spot left the open map. The final automated checks passed with 221 Flutter tests, 53 backend tests and 31 database and HTTP integration tests.

## Previous Android verification

On November 21, 2026, the API 37 emulator completed the two-account workflow.
One account posted a gallery photo and manually confirmed the litter pin. A
second account opened it in Explore and recorded a walk with an ongoing
notification, including a GPS fix while the screen was locked. With the API
offline, the walker used the in-app camera, added a gallery photo, confirmed
the location and marked the linked spot as collected.

After force-stop and retry, the test compared the route and both original
photos with the local draft. The collected spot had left the open map, its
shared photo group contained two images, and the owner could view both
originals after the storage service restarted. The run passed 215 Flutter
tests, 53 backend unit and HTTP tests and 27 database integration tests.
Camera focus, outdoor GPS accuracy and battery use still need a physical walk.

## Redmi field workflow

On November 22, 2026, the signed-in workflow ran on a Redmi Note 13 Pro 5G running Android 16. Two disposable accounts used a separate API, database and private bucket. The test supplied a fixture gallery photo, a known geocoder response and a denied location source. MapLibre used the real basemap. The check asserted that the picker spanned the screen and that the posted coordinates matched the chosen search result.

The second account opened the report, started a Plog without GPS, paused, resumed, confirmed the cleanup and saved a single pickup photo. The activity had an empty route and one evidence record. The original spot left the open map. The test also shared the activity, switched leaderboard periods, organized and joined a cleanup, created a challenge and opened earned badges.

The device run without a provider key exercised the queued state. A second run enabled `FIELD_QA_LIVE_ANALYSIS` with an isolated API and a configured Gemini worker. Denying GPS left the report pin unconfirmed and landmark search remained available. The worker read the saved fixture photo from private storage and returned one plastic bottle. The activity displayed the result and the shared post showed the same active time. The worker requested the configured `gemini-3.5-flash` model and stored the returned model version `gemini-3.6-flash`. A later live request timed out. The worker retried the same saved pickup and stored a ready result on its second attempt. This verifies one example. The [evaluation plan](../design/implementation.md#photo-analysis-rollout) covers accuracy across real pickups. Separate HTTP tests use controlled provider responses for retries, review, sign-in and email recovery.

## Historical M4 baseline

On November 20, 2026, the API 37 x86-64 emulator completed the flow with one
gallery image and one camera capture. Both appeared in activity details after
the app and storage restarts. The check passed 212 Flutter tests, 53 backend
unit and HTTP tests, and 25 database integration tests. The Linux build and
live outage-and-recovery checks also passed with `make validate`. This run
used the emulator camera and the local SeaweedFS bucket.
