# Novayomi iOS novel UI — screenshot parity baseline

This document records the Aidoku-inspired **novel** interface reference from the
November 2026 screenshot review. It is an iOS presentation contract, not an
instruction to replace the original Dart/Rust source engine, repositories,
database, downloads, account operations, or reader persistence.

## Non-negotiable behavior

- iOS uses the UIKit routes by default. No preview flag or Flutter reader fallback.
- Keep all original novel actions functional; do not replace meaningful features
  with noninteractive visual replicas.
- Use Apple's UIKit system materials and real `UIButton.Configuration.glass()`
  on iOS 26+, and native UIKit-compatible materials on older supported iOS.
- Keep the four-tab Library / Browse / History / Settings navigation and
  independent floating search control readable across light and dark mode.
- Scroll content below the glass tabs far enough that every last row and cover
  can be reached. Respect the safe area and Dynamic Type.
- Reader dismissal must never await history I/O or Flutter frames before closing;
  the existing history repository still persists position independently.

## Screenshot mappings

| Screen | Native Swift | Target interaction and presentation |
| --- | --- | --- |
| Library | `NovayomiNativeLibrary.swift` | Large bold title, upper-right glass bell and overflow, search, two-column full-cover poster cards with bottom text gradient and unread badges. Continue Reading remains in the scrollable collection header so it scrolls away. |
| Novel details | `NovayomiNativeNovelDetail.swift` | Back and overflow above a cover/title/author row; status/source pills and useful native actions; readable synopsis and horizontally scrollable genre capsules; pink full-width reading CTA and plain, sortable chapter list. |
| Settings tab | `NovayomiNativeMore.swift` | Bold Settings heading, native search, separate text-and-switch Incognito section, grouped rows with colored SF Symbol tiles and right chevrons, floating glass tabs. Preserve real settings routes and toggles. |
| Browse | `NovayomiNativeBrowse.swift` | Top action row, large Browse title below, search, installed-source logo/version/language list, extension actions, and grid/list choice. Preserve pinning, install/update/uninstall and repository operations. |
| Source Home | `NovayomiNativeSourceResults.swift`, `native_ios_source_results.dart` | Home and Ranking modes, horizontal Trending Novels posters, Latest Updates illustrated rows with chapter metadata when provided, source search, paging and pull-to-refresh. |
| Search/results | `NovayomiNativeSourceResults.swift`, `native_ios_global_search.dart` | Search field with close control, horizontal native sorting/status/type/genre chips, two-column full-cover grid, proper bottom inset, debounced global search. |

## Current filter and metadata contract

- Dart forwards optional `status`, `genres` and latest `chapter` from MManga
  to native source cards. Never invent missing chapter numbers or metadata.
- The visible sorting, publication-status and genre filter chips operate on
  **already loaded results**. Remote source filtering and pagination continue
  through the existing provider APIs. The Type chip identifies Novel, since
  this route is scoped to novels; it is not a false mixed-media filter.
- Sort choices are Source order, Title A–Z and Title Z–A. A cross-source
  Latest Updated sort must not be advertised until reliable timestamps exist.

## Remaining acceptance checks

These screenshot-focused changes have automated Dart analysis, Swift parsing,
Xcode source-registration checks, and source-level smoke assertions. These are
**not a full IPA build** or physical-device verification.

On a real iPhone, verify: native glass behavior, the reference typography and
spacing, horizontal Trending covers, bottom tab clearance after the final row,
source-language and update labels, live-search cancellation, filter choices,
swipe navigation, reader progress persistence and immediate return to details.

Novayomi's settings currently expose the existing real feature routes. A
notification-preferences implementation should only be added when it has a
working backend; the screenshot's Notifications row alone is not authorization
to insert a dead or misleading control.
