# Implementation report — 班匣（ClassVault）MVP 0.1

## Completed

- Created a Swift 6 / SwiftUI iPhone Xcode project with app, unit-test, and UI-test targets.
- Added pinned SQLCipher.swift 4.18.0 and ZIPFoundation 0.9.20 package dependencies.
- Implemented `EncryptedDatabaseService` as the only owner of the database path, SQLCipher keying, migrations, raw SQL, transactions, and schema access.
- Added Keychain database-key generation and retrieval with `WhenUnlockedThisDeviceOnly`.
- Implemented the four required tables and indexes: `student`, `parent_contact`, `import_batch`, and `change_event`.
- Implemented CSV parsing and in-memory XLSX parsing with relationship/path tolerance, header-row detection, and student-worksheet selection.
- Implemented configurable Chinese/English header aliases and editable field mapping.
- Implemented import preview, sample rows, validation, duplicate detection, invalid-phone detection, strict matching mode, database-dependent conflict preflight, and explicit commit confirmation.
- Implemented student-number matching, opaque-ID matching, unambiguous name/class matching, safe updates, and no implicit deletion.
- Implemented preservation of manually entered parent name, relation, and role when a later import has blank or missing values.
- Implemented searchable student cards, class filtering, student detail screens, phone-only contact display, contact add/edit/archive, and incomplete-contact state.
- Implemented Face ID/device-passcode lock behavior with a five-minute background timeout; the encrypted repository is initialized after unlock and released when locked.
- Implemented explicit call confirmation before opening a normalized `tel:` URL.
- Added unit tests for schema initialization, incorrect-key failure, opaque-ID insertion, CSV/XLSX import mapping, title-row/header-row detection, phone normalization, duplicate/invalid input, search, manual contact editing, safe re-import, archiving, change events, database-dependent contact-ID conflicts, cancel-before-commit behavior, and log privacy.
- Added UI tests for locked launch and the call confirmation dialog.
- Updated the visible app copy to Simplified Chinese, added a generated launch screen, portrait-only target metadata, and a responsive card-based SwiftUI layout for iPhone screens.
- Set the on-device app display name to `班匣` and reserved the private repository slug `class-vault-ios`; the internal Xcode target remains `TeacherWorkbench` for v0.1.x build and signing continuity.
- Fixed the Swift 6/Xcode compile errors in `XLSXParser` by using an explicit optional downcast for the last import error and explicitly discarding ZIPFoundation's extraction result.
- Added README build, test, privacy, and physical-device testing instructions.

## Verification status

The implementation was statically reviewed in this workspace. The workspace is Linux-only and does not contain Xcode, an iOS SDK, or a Swift compiler, so `xcodebuild test` could not be run here. The first macOS/Xcode pass should resolve the packages, compile the project, and run the complete test scheme.

## Known limitations

1. XLSX import reads cached cell values and selects a recognizable student worksheet. Formula evaluation, multi-sheet joins, merged-cell interpretation, and advanced Excel formatting are outside version 0.1.
2. The current project uses the example bundle identifier `com.example.TeacherWorkbench`; signing team and production bundle identity must be configured by the app owner.
3. The database key is intentionally device-bound and not recoverable after the Keychain item is lost.
4. The default import preview has strict student-number matching disabled. The user can enable it before commit.
5. UI testing uses synthetic Debug-only data and launch arguments. Final call behavior must be checked on a physical iPhone.

## Decisions requiring confirmation

- Confirm the iOS 17 minimum deployment target and Swift 6/Xcode 16 baseline.
- Confirm the production bundle identifier and Apple development team.
- Confirm that selecting the first recognizable student worksheet (or the best non-empty fallback) is sufficient for the expected files.
- Confirm whether strict student-number matching should become the default for the current target table, which already contains `学号`.
- Confirm the SQLCipher.swift Community Edition dependency and its licensing/attribution requirements before App Store distribution.

## Explicit exclusions preserved

Agent integration, cloud sync, iCloud sync, remote APIs, automatic calls, automatic messages, arbitrary SQL, Python execution, analytics, document generation, seating charts, duty rosters, and performance-analysis features are not implemented.
