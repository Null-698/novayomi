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

**NATIVE ROOT AND NOVEL SOURCE RESULTS ACTIVE ON IOS:** UIKit searchable
source list, pin/unpin, Local novels, and a native extension catalog supporting
install/update/uninstall through the original Dart fetch and source repositories.
Novel source-result pages now render UIKit Popular/Latest and search results,
with pagination and native pull-to-refresh using the existing extension
service. Advanced filters, global search, repository management and extension
preferences remain to be ported; some still use the existing Flutter screens.
No new backend was introduced.

### 2.4 — Updates, History and Downloads

**NATIVE ROOT SCREENS ACTIVE ON IOS:** a UIKit Activity screen displays novel
History and Updates from their original Isar streams, with read, download,
remove/clear and refresh actions. The separate Download Queue route is UIKit,
with resume/cancel/series cancellation handled by the existing download
manager. Native navigation is the default, without a preview flag. More
advanced download controls and full parity remain subject to device testing.

### 2.5 — Settings, tracking, backup and sync

**NATIVE MORE AND SETTINGS ROOTS ACTIVE ON IOS:** UIKit grouped menus and
native Downloaded Only/Incognito switches with existing Riverpod persistence.
Native Settings includes grouped, searchable navigation. General,
Appearance, Downloads and Browse settings have UIKit toggle/slider/choice/text
forms writing the original Riverpod providers. Security settings also use UIKit
with a device-authentication gate for app-lock changes; DoH and proxy choices
preserve the original network stores. Deep novel-reader settings, tracking,
sync, backup/restore, collection configuration and some advanced settings are
not yet feature-complete native screens. Keep their existing account, restore
and file-handling logic intact; do not change backup formats.

### 2.6 — iOS shell cutover and cleanup

**PARTIALLY COMPLETE — NOT YET 100% NATIVE.** UIKit owns the default iOS
Novel Library, novel details, Browse, novel source results, Activity,
More, Download Queue, Settings navigation, and common preference forms.
There are no preview switches. Remaining Flutter-visible routes include
advanced extension configuration and repositories, global search, tracking,
sync, backup/restore, the standalone reader-settings page, and some
secondary forms/actions. Convert these with full parity before deleting the
old Flutter UI or claiming a fully native interface.

This phase also requires a successful fresh iOS build of the current commit,
on-device acceptance, VoiceOver and Dynamic Type checks, orientation testing
and testing long source/chapter lists. Swift remains presentation-only:
Flutter/Dart/Rust retain the backend and business logic.

## Verification gates for every screen

1. iOS unsigned IPA compiles with the current toolchain.
2. A device test verifies the screen and transitions on current iOS.
3. Functional parity checklist against the prior Flutter screen is complete.
4. No lost local data, regressions to extension behavior, or new backend.
5. Native accessibility, larger text, light/dark appearance and performance
   are validated before route replacement.
