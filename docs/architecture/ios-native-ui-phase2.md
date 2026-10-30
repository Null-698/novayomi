# Novayomi iOS native-interface migration

## Contract

The goal is a **100% native iOS interface** using UIKit, Apple's standard
navigation and scroll-edge effects, and native WebKit for the novel reader.
The source-extension engine, Isar database, Rust EPUB parser, downloads,
sync, history, and other application logic **remain unchanged** in Dart/Rust.

* Only presentation, screen navigation, and interaction controls migrate.
* Native screens receive snapshots and send actions through narrow platform
  channels. Data authority and persistence stay with the existing services.
* Never introduce a second database, a second extension runtime, or duplicate
  native background-download logic.
* Novel reading continues to use `NovayomiNativeReaderController`.
* There is no Flutter-based iOS **reader** fallback.
* Do not remove working UI until equivalent native actions are available.

## Phases

### 2.1 — Native navigation and Novel Library

The existing iOS bottom tab bar is a real `UITabBar`. A native Library
`UICollectionView` has now been added, with `UISearchBar`, native category
buttons, sorting, grid/list displays, image loading and context menus.
`NativeIosNovelLibrary` supplies the existing reactive Riverpod/Isar data.

**Integration status: ACTIVE on iOS.** The novel Library route uses the
UIKit collection view directly. There is no native-Library preview flag,
and unsigned IPA builds ship the native Library without special inputs.
The backend continues to run in Dart, as before. Test the native interface
on a device before treating its remaining UI migration stages as complete.

Implemented in the active native Library:
- UICollectionView grid and list, system search field and category chips.
- Native Filter / Sort / Display sheet using the current persisted providers,
  including source filters, reverse unread-count sorting and grid columns.
- Search by novel title, source, genre and author with filtered/all scope.
- Long-press multi-selection, mark read/unread, set categories and remove
  library entries with a native confirmation; removal keeps downloaded files.
- Unread/downloaded count badges, custom covers, cover request headers,
  continue-reading buttons, pull-to-refresh and native context menus.
- Native horizontal Continue Reading shelf sourced from the existing
  batched history resolver; tapping opens the exact chapter via the native
  reader route (no new history storage).
- Native overflow actions for update, random novel and EPUB import with
  split/one-chapter choice; file selection and EPUB processing remain in the
  existing Dart file-picker / Rust EPUB pipeline.
- Native collection management with create, rename, hide/show,
  skip-update, drag-to-reorder and confirmed deletion, all routed to the
  current CategoryRepository and category-deletion sync notification.
- Native alerts for Dart repository/import errors, instead of silently
  abandoning an operation.
- Independent "Remove from Library" and "Delete downloaded chapters" switches
  in a native sheet. Both Flutter and UIKit now call the same original Dart
  file/Isar cleanup implementation. Local EPUBs receive a permanent-file
  deletion warning; downloaded chapters remain re-downloadable.
- Independent native badges for local sources, downloaded/unread counts,
  language and source, respecting existing persisted display preferences.
  Comfortable and cover-only grids hide labels as in the original UI.
- Native long-press selection, Select All and Invert Selection controls.
- Session-only restoration of search text, filter scope, category and list
  scroll position across tab reconstruction; no extra persistent store.
- Native empty and no-results states, with Browse and clear-filter actions.

**Remaining verification and parity work (the route is already native):**
- Verify display-style parity across all supported device sizes.
- Continue Reading is now a non-sticky UICollectionView section header,
  not a fixed second collection above the scrolling grid. For libraries with
  just one or two novels, bottom scroll space is reserved so the entire
  shelf can scroll off the screen on an iPhone. Validate on device.
- Ensure the native migration workflow matches any available original
  source-migration actions before exposing it.
- iOS build, real-device performance, VoiceOver and large-type testing.
- Complete chapter filtering and source-migration parity in novel details.
- Verify UIKit Library layout and gesture behavior on the two-novel device case.
These are not preview gates: iOS uses UIKit by default, with no preview switch.

### 2.2 — Native novel details

**ACTIVE ON IOS:** `NativeIosNovelDetail` presents the native UIKit novel
information card, chapter search/list, read/resume, mark read/unread, bookmarks,
favorite, download chapter/all unread, refresh and sorting. It is the default
iOS novel-detail route without any preview switch. Other media retain their
original detail views. The original Isar, updater and download providers remain
the only backend. Remaining parity work: full chapter filters, categories,
tracking, source migration and advanced overflow actions.

### 2.3 — Browse, search and extension management

**NATIVE NOVEL BROWSE, SEARCH AND EXTENSION SCREENS ACTIVE ON IOS:**
UIKit source and extension catalog, extension landing page, source filtering,
extension preferences, and repository add/remove/hide/refresh. Novel source
results present UIKit Popular/Latest and search with paginated results,
pull-to-refresh and covered images. Global novel search also uses UIKit,
aggregating the existing source searches with a three-request concurrency
limit. Extension cookies and dynamically declared preferences still persist
using the existing Dart services. Some advanced source tools, editor
screens and cross-source migration flows remain Flutter-presented.

### 2.4 — Updates, History and Downloads

**NATIVE ROOT SCREENS ACTIVE ON IOS:** a UIKit Activity screen displays novel
History and Updates from their original Isar streams, with read, download,
remove/clear and refresh actions. The separate Download Queue route is UIKit,
with resume/cancel/series cancellation handled by the existing download
manager. Native navigation is the default, without a preview flag. More
advanced download controls and full parity remain subject to device testing.

### 2.5 — Settings, tracking, backup and sync

**NATIVE MORE, SETTINGS, TRACKING, SYNC AND STORAGE ROOTS ACTIVE ON IOS:**
UIKit grouped menus and the Downloaded Only/Incognito switches continue
to write the existing settings. General, Appearance, Downloads, Browse,
Security and Novel Reader preferences use native UIKit form controls,
preserving the original Riverpod persistence, app-lock authentication,
DoH/proxy settings and TTS service. Tracking, connected tracker management
and synchronization have native UIKit routes with original OAuth, credential
and sync backends. Data & Storage and Create Backup are also UIKit screens;
backup creation still uses the original archive provider and iOS backup
directory, with password storage in the Keychain. **The restore workflow
still opens its original Flutter confirmation/import dialogs** so that
cross-format validation, merge/replace, safety snapshots and rollback are not
lost. Tracker details, advanced library/source maintenance, backup
restore dialogs, and additional service forms need native parity work.
Neither account formats nor backup formats are changed.

### 2.6 — iOS shell cutover and cleanup

**PARTIALLY COMPLETE — NOT YET 100% NATIVE.** UIKit owns the
default iOS Novel Library, novel details, reader, Browse, extension catalog,
source filters/results, global search, repository management, dynamic
extension preferences, Activity, More, Download Queue, Settings, tracking,
sync and backup creation/storage forms. **There are no preview switches.**
Remaining Flutter-visible routes include tracker details, chapter migration,
some advanced extension/source editors, stats and calendar, library cleanup,
backup restoration's interactive safeguards, and other secondary flows.
Do not remove the old Flutter UI or claim the shell is 100% native until
these are converted and passed functional parity checks.

The new Ubuntu native UI smoke workflow analyzes all iOS bridge Dart files,
parses Swift files and checks route/Xcode registration automatically on pushes.
It does not replace a full iOS unsigned IPA build, Swift UIKit typechecking
against the iOS SDK, or on-device testing. Full cutover additionally requires
VoiceOver and Dynamic Type checks, orientation testing, and long
source/chapter list and gesture validation. Swift remains presentation-only:
Flutter/Dart/Rust retain the backend and business logic.

## Verification gates for every screen

1. iOS unsigned IPA compiles with the current toolchain.
2. A device test verifies the screen and transitions on current iOS.
3. Functional parity checklist against the prior Flutter screen is complete.
4. No lost local data, regressions to extension behavior, or new backend.
5. Native accessibility, larger text, light/dark appearance and performance
   are validated before route replacement.
