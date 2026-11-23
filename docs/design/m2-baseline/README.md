# M2 visual baseline

Captured on 23 November 2026 from the working tree based on commit `eda6597cf5b581a173b29bdc7ddb844e9fd3e14b`, including its uncommitted and untracked source changes. The source archive is `build/m2-baseline/source-snapshot.tar.gz` with SHA-256 `8faa867c86b572cca01482747c71e369f6fc97314ed837e13b17b606f928fade`. The archive excludes ignored local configuration and dependencies. The `build` directory is disposable, so copy the archive elsewhere before running `flutter clean`.

The preview captures use Android emulator `Medium_Phone_API_37.0`, 1080 × 2400 physical pixels, 420 dpi, portrait orientation, light theme and 100% text scale. The images contain the Flutter surface without native Android system bars. The test used the existing sample data. The isolated capture checkout used a separate Android application ID to preserve the pre-existing emulator installation. Flutter 3.50.0 ran the 24-screen screenshot scenario and the existing preview interaction scenario successfully.

The [preview contact sheet](preview-contact-sheet.jpg) shows the captured screens in filename order. The [preview folder](preview/) contains the individual screenshots. The capture includes the three onboarding pages, authentication, home, scan, report, map, session, summary, cleanups, challenges, leaderboard, badges, community, profile, activity, saved spots, settings, connection, help and about.

These captures record the current appearance for comparison during M2. They do not establish acceptance for dark theme, enlarged text, landscape, native camera and picker, accessibility, offline recovery or physical devices. The redesigned report review and completion screens do not yet have a separate baseline screen in the existing flow.

## Live captures

The [live contact sheet](live-contact-sheet.jpg) and [live folder](live/) contain 26 signed-in captures from the same source snapshot and emulator settings. The run used an isolated database and object store, a new test account, a fixture gallery image, denied GPS and a local place-search fixture. The isolated services were removed afterward. Live data in these screenshots is test data. Map tiles depend on network availability.

The field test timed out twice after selecting a location and tapping **Post report**. It waited 35 seconds for the map route while the app displayed a new empty report form on `/report`. A fresh diagnostic run checked the account’s reports immediately after the timeout and found exactly one published report at the selected fixture location. The screenshot `live-report-publish-failure.png` records the cleared form after the timeout. Investigate why the app stays on the report route after publication. The field test returned a failing result.

The live camera uses the emulator’s virtual scene. The active Plog and completion captures use a denied GPS fixture and a sample gallery photo. A separate completion scenario passed and produced an activity with one pickup and analysis waiting. Captures of a recovered Plog, published report detail, ready or failed analysis, and post details are pending.
