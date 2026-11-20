# Garbage photos and Plog completion

A signed-in Android user taps **Finish Plog** to stop GPS, takes or chooses
one to six garbage photos, then taps **Save Plog**. The server confirms
completion after every selected upload has been acknowledged. Open **View
activity** or **Profile → My Activity** to see the saved photos and route.
[Completion rule](https://github.com/devBuildersunique/ploggr/issues/32) · [M4.7 acceptance criteria](https://github.com/devBuildersunique/ploggr/issues/34)

## Reproduce the Android check

Use the root development prerequisites, Python 3 and a disposable API 37
Android emulator with the English system UI, system photo picker, stock Camera
app, emulated back camera and location enabled. Start with Ploggr uninstalled.
From the repository root, substitute the serial printed by the first command.

```bash
adb devices
make validate-evidence DEVICE=emulator-5554
```

The runner creates its own account, database, S3 bucket, API port, and gallery
album containing the repository's sample image. It installs a debug APK that
uses the normal Android screens, picker, SQLite draft store and authenticated
HTTP client. It removes the temporary album, APK, forwarding rule and Compose
project after the check. The M3 command `make validate-plog` runs the same flow.

| Check | Passing behavior |
| --- | --- |
| Track and finish | After a permission denial and retry, the app records two GPS fixes. Finish freezes the end time, distance and route before photo selection. |
| Select and capture | The system picker returns the gallery fixture. The stock Camera app captures a second photo. Both appear in the current Plog draft. |
| Interrupt and recover | With the API stopped, saving leaves the Plog unconfirmed. The runner force-stops and reopens the app. Retry uses the frozen measurements and the two saved photo IDs. |
| Persist and display | After completion, the runner recreates the storage container using its existing volume. The authenticated API returns both photos in order, byte-for-byte identical to the draft. The activity screen displays the saved evidence. |
| Ownership and privacy | The HTTP tests exercise missing authentication, cross-account reads and uploads, and anonymous bucket access. The API gives the owner image bytes and keeps the storage key private. |
| Upload boundaries | The HTTP tests cover invalid and truncated images, file size limits, concurrent attempts at the sixth slot, and retry with different bytes under an existing ID. |
| Partial failure | A failed storage write leaves a pending reservation. Finish rejects pending evidence, even when another photo is ready. An identical retry confirms it once. A missing stored image leaves the completed activity and its other photos readable. |

The Android success line is `Android Plog tracking, evidence and completion validation passed.`
For the backend contracts alone run `npm --prefix backend run test:database`.
The local storage service is SeaweedFS. A managed S3 deployment requires its
own private bucket and access configuration. [Backend storage setup](../../backend/docs/maintenance.md#private-image-storage)

## Verified run

On November 20, 2026, the API 37 x86-64 emulator completed the flow with one
gallery image and one camera capture. Both appeared in activity details after
the app and storage restarts. The check passed 212 Flutter tests, 53 backend
unit and HTTP tests, and 25 database integration tests. The Linux build and
live outage-and-recovery checks also passed with `make validate`. This run
used the emulator camera and the local SeaweedFS bucket.
