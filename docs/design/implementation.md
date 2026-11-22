# Flutter preview design

This design record describes the 18-screen redesign delivered on 17 November 2026. For the current app, API and database setup, start with the [project README](../../README.md). For the results and images from the design review, see [visual validation](validation.md).

## Starting point

Before the redesign, the app had seven routes covering splash, login, signup, home, leaderboard, session and summary. Riverpod and go_router were in place. The screens held local mock state, the theme was empty, orange and brown styling was duplicated, and two navigation actions were inactive. The old splash logo was the only bundled artwork.

## Implementation stages

1. Kept the app entry point, central routes and feature directories. Moved shared colors, typography, theme and widgets into the design system.
2. Implemented the splash, three onboarding pages and keyboard-safe authentication previews.
3. Added the home, sample camera, litter report, map, session and summary screens.
4. Built the cleanup, challenge, leaderboard, badge, community and profile screens with typed fixtures and Riverpod controllers.
5. Checked navigation, interactions, compact layouts and large text, then captured the Android screens and built the debug APK.

## Reference screen interpretation

| Screen | Composition |
| --- | --- |
| Splash | Botanical corner, dark green wordmark, two-line motto, layered park |
| Onboarding 1 | Park clean-up illustration, centered heading/body, dots, next |
| Onboarding 2 | Large green trophy in pale circle, leaves, dots, next |
| Onboarding 3 | Hands supporting seedling, centered copy, Get Started |
| Login | Botanical accent, wordmark, welcome heading, outlined fields, social row |
| Sign up | Back, centered title, five outlined fields, green action |
| Home | Greeting, pale impact card, three stats, two actions, challenge, shortcuts |
| Scan | Full sample photo, corner viewfinder, caption, shutter/gallery/flash |
| Report | Photo, six litter choices, coordinates, optional description, save |
| Litter map | Two tabs, pale street map, green/red pins, selected litter card |
| Session | Timer, three metrics, route map, pause/stop, nearby alert |
| Summary | Date/distance/time, weight stepper, litter chips, photos, save |
| Nearby | Map/list tabs, green pins, event distance/date/attendees/join |
| Challenges | Three filters, illustrated cards, time/progress indicators |
| Leaderboard | Time filters, compact rows, medals, highlighted self |
| Badges | Large leaf shield, earned count, six achievement tiles |
| Community | Feed/My Posts, avatar rows, photo post, reactions, compose |
| Profile | Avatar/name/handle, three stats, five destinations, bottom nav |

## Design decisions

Feature controllers own preview state. The app bundles artwork and fonts, draws sample maps locally, and identifies simulated services in the UI. Safe areas, scrollable forms, constrained widths, wrapping controls and 48 dp targets support phones and enlarged text. [Asset provenance](assets.md)

## Signed-in Android flows

| Issue found | Implemented interaction | Acceptance check |
| --- | --- | --- |
| A pickup opened the public report editor and required coordinates. | Add a private pickup directly from the camera or gallery. | Deny location, add a photo and save the walk. No map entry or coordinate field appears. |
| Inaccurate GPS made reports difficult to place. | Search landmarks or move a map pin, with optional device location and an accuracy circle. | Adjust the pin and reopen the published sighting at its saved location. |
| People could not tell whether litter was still there. | Select a real marker for photos and status. Confirm a cleanup, report remaining litter or mark a missing sighting. | Only a synced cleanup removes the pin. Two independent missing observations add a moderation task. |
| Finishing could stop a walk unexpectedly and route counts dominated the live screen. | Keep Add pickup, Pause or Resume, and confirmed Finish within reach. Show active duration and distance. | Cancel Finish, resume after a pause and open the saved walk after a successful retry. |
| Leaderboard and community features disappeared after login. | Expose standings, community posts, events, challenges and badges from signed-in navigation. | Open each destination from Home, Community or Profile and exercise its empty and populated states. |
| Buttons blended into cards or lost their labels. | Use forest primary actions, outlined secondary actions, labeled navigation, 48 dp control targets and keyboard-aware footers. | Check compact widths, increased text size and the open keyboard. |
| The landscape keyboard could cover Publish or the next form field. | Use the space above the keyboard for the primary action and a Hide keyboard button on short screens. | Enter a cleanup name, select its meeting point and publish a post in landscape. |
| Scrolling before switching a leaderboard period could break the scoring explanation. | Store its expanded state separately from the page’s scroll position. Do the same for photo findings and help topics. | Open scoring, scroll and switch periods without losing access to the standings. |
| Activity details lost context when navigating Back. | Use routes for a specific Plog or sighting. Link the latest report and the saved activity directly. | Open a detail from the list, return and retain the list position. |
| Sharing a short walk with GPS off showed zero distance and zero minutes. | Use the same active time and recorded distance in Activity and Community. Show seconds for walks under a minute. | Share a short pickup after denying location and compare the feed with the saved activity. |
| A second account could land on the previous account’s map after sign-out. | Reset navigation to Login when local sign-out completes. | Sign in to another account and verify it opens Home. |
| Photo uploads gave no explanation of what counted. | Show queue, processing, result, review and failure states. Open a grouped finding to inspect supporting photos. | Duplicate views count once. Unsupported carbon estimates remain absent. |

### Release checks

The Redmi Note 13 Pro 5G passed the signed-in field workflow on November 22, 2026. A device screenshot exposed a picker-width bug and a late map callback that moved a searched pin. The regression test checks the rendered width and compares the saved coordinates with the selected search result. This test uses the native map, SQLite, Nest, PostGIS and private object storage with a fixture photo and denied route permission. An API 37 emulator passed the native camera, system picker, screen-off GPS, API outage and process-restart checks. A separate layout test opens Community and Leaderboard at 320 dp and 160% text size.

[Field workflow test](../../integration_test/field_walk_test.dart) · [Configuration and scoring](../development/configuration.md#photo-analysis-ranking-and-account-services)

### Upcoming UI validation

| When | Task to observe | What to verify |
| --- | --- | --- |
| Before the first field pilot | Ask a first-time user to report a real litter spot on a walk with weak GPS. | They can identify the right landmark, adjust the pin and recognize their photo on the shared map. Record where they hesitate and compare the saved pin with the location they chose. |
| Before the first field pilot | Complete a pickup outdoors with the screen locked for part of the walk and connectivity interrupted at Finish. | Check camera focus, button readability in daylight, GPS accuracy and battery use. The user can find their saved activity and tell whether the cleanup has synced. |
| Before wider Android release | Repeat reporting, pickup, sharing and standings on a smaller and a larger physical device, using TalkBack, enlarged text and the keyboard. | Check focus order, spoken names and selected states, reachable primary actions, and a way to continue when map imagery fails. |
| Before enabling public scoring | Give reviewers and ploggers representative real analysis results, including uncertain and repeated objects. | Reviewers can correct a finding using its supporting photos. Ploggers can explain a pending result and trace a published score back to the materials and approved rules. |

### Photo-analysis rollout

The configured worker identified one plastic bottle in the bundled photo during a Redmi walkthrough. For the first accuracy evaluation, use consented, manually labeled Plogs. Keep all views of a pickup together in one evaluation set. Include mixed-material piles, sealed bags, poor light, an empty scene and repeated views of the same object. Compare predicted materials and quantities against the reviewed labels. Track count error, duplicate credit, the fraction sent for review and time from save to a visible result. Use those results to set review criteria before publishing scoring weights. Evaluate a new model version on the same held-out examples before changing the configured model.
