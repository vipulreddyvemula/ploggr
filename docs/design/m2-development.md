# Ploggr M2 development handoff

## D1 design system and navigation

D1 covers the shared work for M2.1, M2.15 and M2.16 and the accessibility foundation for M2.17. It builds on the M1 working tree captured for the [visual baseline](m2-baseline/README.md).

- The theme follows the system appearance. Forest and leaf greens, the existing illustrations and Nunito Sans carry the Ploggr identity across modes. Use the theme’s paired surface and foreground roles for UI. Camera controls and artwork retain their own scene colors.
- Use 20 dp standard page gutters, 12 dp control corners, 16 dp card and dialog corners, and touch targets of at least 48 dp. On narrow screens with enlarged text, the litter category picker switches to two columns. Shared page headers reserve more height for enlarged titles.
- Shared loading feedback has an accessible label. Notices pair an icon with text and use dedicated styles for success, warning, pending sync, failure, and information. The first adoption covers the report editor, live Plog, activity, community requests and session gate. Feature batches can use these components for their remaining states.
- Bottom navigation reads the current route. A selected destination preserves the current view. Header Back and system Back return to the preceding page where available. Direct links displayed in the shared page shell use their assigned fallback. An expired signed-in session clears its previous protected destination. Entry links from a cold signed-out launch continue through sign-in.

## Screen and interaction inventory

| Screens | Entry, actions, and Back behavior | States to cover |
| --- | --- | --- |
| Splash, onboarding, login, signup | Advance or skip onboarding, sign in, create an account, show or hide password, and open supported account recovery. Preview sign-in and sample data carry preview copy. | Session check, unavailable session, validation, sign-in failure and retry |
| Home, camera, report editor and location picker | Home opens the session or report flow. Preview scan is simulated. Live capture and the native picker return to the same draft. Confirmed location returns from the picker. Deliberate discard uses confirmation. | Camera access and unavailable hardware, draft recovery, invalid image, publishing, queued sync and published report |
| Litter Map, My Reports, report detail and cleanup sheet | Map and list select the same report. Tapping a card opens the corresponding detail. Back returns to the originating map, report list or feed. My Reports falls back to Profile on direct entry. | Empty viewport, map or location unavailable, selected report, pending withdrawal, cleanup verification |
| Active Plog, review, history and Plog details | Start or recover a session. Add pickup, pause or resume, confirm Finish, then review and save. History opens details over its list. The saved activity can open the post composer. | GPS denied, paused, recovering, private pickup evidence, local or remote save, retry, analysis and verification |
| Community feed, comments, composer, moderation | Filter between public posts, own posts, and sightings. Open or return from comments. Show actions allowed for the account and confirm deletion. | Empty feed, load failure, submit in progress and restricted moderation |
| Cleanups, challenges, leaderboard, badges | Reach programs from Home, Community or Profile. Open events, join or leave when offered, filter periods and check ranking information. | Empty, membership changes, challenge progress, unranked and earned states |
| Profile, settings, connection, Help and About | Edit profile, open activity and reports, check the connection, and sign out. Direct entry to Help or About returns to Profile. | Loading, unavailable account data, local sign-out, sign-out retry |

## Report publication regression

In the baseline, choosing a photo and pin and tapping **Post report** created one server report but left the user on an empty editor. The sync cleanup returned the future it was completing, so the caller never received the report ID. Report and observation sync now remove completed entries without returning their futures. Foreground submission reserves the draft’s upload before saving its queued state. The editor and background sync share the same result. The submission keeps a reference to the originating route and opens the selected report on the map after acknowledgement if that route is still current.

The focused Android retest used a fresh account, disposable database and storage, and a fixture photo and location. One submission produced one open report, opened the map, and selected the matching report ID at the chosen pin. An automated sync test also verified that a connection failure leaves the draft available for retry. Leaving the editor during a pending upload was deferred on Android.

Static contrast checks for the defined text, muted text, primary controls, selected navigation and warning pairs returned ratios of 4.96:1 or higher. The testing pass corrected the dashboard fixture’s totals record. The application now uses a darker gold on light surfaces, and the badge icon passes its 3:1 contrast test. Shared Back handling supports pages during transitions and in a standalone Navigator. The Core Plog Integrity rollback removes its SHA-256 index before reapplies.

The follow-up passed 278 Flutter tests, including the four refreshed goldens, navigation and contrast checks, and regressions for shared report completion and retry after a connection failure. The isolated database suite passed 35 contract tests and the migration rollback and reapply checks. Home goldens render the button labels in Nunito Sans. Emoji appearance still depends on the host test font.

## D2–D7 feature development

| Batch | Implemented changes |
| --- | --- |
| D2 camera and photo review | Live camera opens with a progress state and keeps gallery access available during camera failures. It supports focus at the tapped preview point, lens switching, zoom within camera limits, flash state, and optional framing. Report and pickup review share accessible photo selection, full-screen inspection, replacement, deletion confirmation, and local or upload status. Report photo order persists and is used on publication. |
| D3 reporting and location | Photos, details, location, and review are explicit steps over the existing local draft. Search or manual placement can confirm the pin without permission. The GPS estimate has a separate marker with accuracy and a timestamp. Review shows the public fields and pin. Server acknowledgement opens a success screen with links to the report and its map marker. Queued drafts remain available for retry. |
| D4 live Plog and completion | Active sessions show recording, pause, GPS and connectivity status alongside large controls. Completion keeps the finish confirmation and review, labels device estimates and unavailable distances, and shows the number of photos uploaded. Once the server confirms the save, the screen offers activity, sharing and Home actions. |
| D5 activity, discovery and analysis | Activity cards include GPS availability, pickup photo and linked sighting counts, and analysis status. The map uses distinct cluster and category markers, preserves selection when panning or recentering, and offers a list when the map is unavailable. Analysis separates photo estimates from measured mass and cleanup verification. Supporting photos have optional detection outlines. |
| D6 Home, onboarding and account | The live Home places session recovery, Start, Report and Explore before impact metrics. The account screens show recent Plogs, revised onboarding, form errors and retry feedback, live Help and About, installed build information, and logout confirmation. |
| D7 community and programs | Live posts show author and activity previews with labeled interactions. Events identify participation, challenges and badges show progress, and standings show ranks and points with the existing scoring explanation. Shared layouts wrap controls and maintain keyboard access. |

The device database upgrades existing Plog drafts from version 7 to 8. A replacement reserves a new photo first and removes the original in the same local transaction that saves the replacement. The existing server cleanup queue handles the old evidence ID. Activity list responses add route, photo count, linked pickup count and analysis fields. Older responses continue to parse, and activity detail and finish response shapes are preserved.

The Android test scripts now follow report review, acknowledgment, and the saved Plog screen. Native camera orientation, focus and zoom, system picker recovery during replacement, and the updated live Android journey belong to device validation. The most useful single device run is the report-to-cleanup journey on a disposable Android install.

The final local run passed 278 Flutter tests, 53 backend tests, and 35 isolated database integration tests, including rollback and reapply.
