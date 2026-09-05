# Teacher Workbench — iPhone Student Contact MVP

Teacher Workbench is a personal, offline-first SwiftUI application for a teacher who needs a private local student/contact directory.

## Build requirements

- macOS with Xcode 16 or newer
- iOS 17 or newer
- A development team configured for the app target
- Network access the first time Xcode resolves Swift packages

Open `TeacherWorkbench.xcodeproj`, select the `TeacherWorkbench` scheme, choose an iPhone Simulator or a physical iPhone, and run. Set your own development team in the Signing & Capabilities section. The example bundle identifier is `com.example.TeacherWorkbench` and should be changed before distribution.

The project uses:

- Swift 6 language mode
- SwiftUI
- the official `SQLCipher.swift` Swift Package, pinned to version 4.18.0
- ZIPFoundation 0.9.20 for in-memory XLSX archive reading
- Keychain Services and LocalAuthentication

The app target includes `SQLITE_HAS_CODEC=1` in Debug and Release. `EncryptedDatabaseService` verifies `PRAGMA cipher_version` and fails closed if the active SQLite connection is not SQLCipher.

## Test commands

Run the unit and UI tests from Xcode, or use a destination available on the machine:

```bash
xcodebuild \
  -project TeacherWorkbench.xcodeproj \
  -scheme TeacherWorkbench \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  test
```

The test suite uses synthetic values only. The UI target has two Debug-only launch arguments:

- `--ui-testing-lock` verifies that student names and phone numbers are not shown before unlock.
- `--ui-testing-demo-data --ui-testing-unlocked` seeds a synthetic record so the call-confirmation UI can be exercised.

Do not use these launch arguments in a Release build.

## Local database and key handling

After the first successful unlock, the app creates an encrypted database in the app's Application Support directory:

```text
TeacherWorkbench/teacher_workbench.sqlite
```

The database key is generated with `SecRandomCopyBytes` and stored only as a Keychain generic-password item with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. The database is initialized lazily after the app unlocks, and the repository is released when the app locks. The key is not in source code, UserDefaults, logs, or the database file name.

The database uses the schema from the task specification:

- `student`
- `parent_contact`
- `import_batch`
- `change_event`

The database file and its directory use complete iOS file protection. No plaintext database backup is created by the app. The SQLCipher database is only opened and accessed by `EncryptedDatabaseService`; views and the repository never execute SQL directly.

## Import workflow

1. Tap `Import` and select a `.csv` or `.xlsx` file from Files.
2. The app reads the source file into memory, computes a SHA-256 source hash, proposes aliases, and shows sample rows.
3. Review or adjust the canonical field mapping.
4. Review validation issues and rejected row numbers.
5. Tap `Import`, then confirm the write.

The current target layout is supported directly, and the mapping menu can be used for additional columns:

```text
学号 | 姓名 | 性别 | 身份证 | 毕业学校名称 | 小学班级 | 联系方式一 | 联系方式二 | 家庭地址
```

`小学班级` is stored as `primary_school_class`. `联系方式一` and `联系方式二` become separate `parent_contact` rows with `contact_role = 'unknown'`; the app never infers father/mother from column order.

Blank values and placeholders such as `-`, `无`, and `未填写` become database `NULL`. Phone values are stored as text after validation and normalization. Missing optional fields do not reject a row. Missing names, invalid phones, conflicting duplicate rows, ambiguous mappings, and rows without deterministic matching fields are reported before commit.

Imports match by student number first, then imported opaque student ID, then unambiguous name plus current/primary-school class. Matching updates preserve blank-sensitive manual contact data. A later file cannot delete records merely by omitting them; explicit contact archiving is a separate action.

The source URL is not copied into the app sandbox. Its bytes are read only while preparing the preview, and the in-memory parsed representation is released after the preview is dismissed or committed.

## Contact and call behavior

From a student detail screen, `Add Parent Contact` creates a local contact. Existing phone-only contacts can be edited later to add a name, relation, role, and primary flag. A contact may remain without a phone number, but the Call button is unavailable until the number is valid.

Tapping Call only opens a confirmation dialog. The app creates a `tel:` URL and invokes `OpenURLAction` only after the user taps `Call` in that dialog. It does not place calls automatically and does not send SMS, email, WeChat, or remote requests.

## Privacy boundary

Version 0.1 deliberately contains no Agent, cloud sync, iCloud synchronization, remote API, arbitrary SQL interface, Python runtime, analytics, automatic call, automatic message, document generation, or other teacher-workbench feature.

Names, student numbers, parent names, phone numbers, ID numbers, and addresses are never written to application logs. Import history records counts, an opaque import ID, and a source hash; change history is stored inside the encrypted database.

Use synthetic data until the full import, edit, re-import, lock, and call flow passes on a physical iPhone. A simulator cannot provide a meaningful final test of the iPhone phone interface.

## Version 0.1.2 fixes

- The app's visible copy and generated display name are Simplified Chinese by default.
- The app target has generated launch-screen metadata and portrait-only orientation settings so a current iPhone uses the full screen instead of a legacy letterboxed layout.
- XLSX import now resolves standard workbook relationships, handles common namespace/path variations, searches the first 20 worksheet rows for the real header, and prefers a student-like worksheet when a workbook contains a cover sheet. It supports shared strings, inline strings, booleans, and cached cell values.

## Known implementation boundaries

- XLSX parsing does not evaluate formulas, interpret merged cells, or join data across multiple worksheets. It selects the first recognizable student worksheet, or the best non-empty worksheet when no sheet matches the student-header heuristic.
- The project requires Xcode to resolve the SQLCipher binary package and build for Apple platforms.
- The database key is device-bound. Deleting the app or losing the Keychain item makes the encrypted database unrecoverable by design.
- The default import mode permits name-plus-class matching when student number is absent. Enable `Strict student-number matching` in the preview when every row must contain a student number.
