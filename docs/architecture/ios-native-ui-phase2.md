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

**Integration status: STAGED; normal builds still use the existing Library.**
To build a test IPA, open GitHub Actions → Build IPA Unsigned → Run workflow,
enable **native_library_preview**, and build from the latest `main`.
For a local build, use
`flutter build ios --release --no-codesign --dart-define=NOVAYOMI_NATIVE_LIBRARY_PREVIEW=true`.
The switch is iOS-only and defaults to false. Do not treat the preview as
production-ready.

Implemented in the staged native Library:
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

**Still required before the default route can switch:**
- Full migration and downloaded-file deletion actions with native
  confirmation UI while preserving repository/download cleanup rules.
- Display-specific badges and cover-style parity across all grid modes.
- Search, selected category, shelf and scroll-position restoration across
  route/tab changes; error and empty-state polish.
- iOS build, real-device performance, VoiceOver and large-type testing.
- Native novel details and remaining tab screens as later Phase 2 stages.
Do not promote the preview until these gates pass.

### 2.2 — Native novel details

Implement details, chapter lists, track status and download controls as
native UIKit views. Reuse existing providers and navigation into the native
reader. Retain Isar and source extension operations in Dart.

### 2.3 — Browse, search and extension management

Native search, repositories, source filters and extensions UI. Keep the
original extension installation and execution services.

### 2.4 — Updates, History and Downloads

Native lists, sheets and progress indicators fed by existing streams.
Keep the download queue, updater and history repositories unchanged.

### 2.5 — Settings, tracking, backup and sync

Native forms with real system controls. Write existing settings through
current providers and preserve account and backup formats.

### 2.6 — iOS shell cutover and cleanup

Promote UIKit to own the complete visible navigation hierarchy. Remove
unused iOS Flutter UI surfaces only after functionality, accessibility,
VoiceOver, local data and performance have been verified. Flutter/Dart may
remain a headless backend; no full Swift backend rewrite is required.

## Verification gates for every screen

1. iOS unsigned IPA compiles with the current toolchain.
2. A device test verifies the screen and transitions on current iOS.
3. Functional parity checklist against the prior Flutter screen is complete.
4. No lost local data, regressions to extension behavior, or new backend.
5. Native accessibility, larger text, light/dark appearance and performance
   are validated before route replacement.
