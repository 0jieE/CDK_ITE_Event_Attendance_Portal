# In-app updates from GitHub Releases — setup

**ITE Instructors** checks the project's GitHub Releases for a newer version, shows an
*Update available* dialog, downloads the APK with progress, verifies its SHA-256 checksum and
opens Android's own installer. The app is updated in place: same app, data kept (including
offline scans that haven't synced yet). (The **ITE Students** app in `../mobile_student` works
the same way with its own tag prefix and APK name — see the table below.)

## 1. The release contract

Both apps publish to the same repository, so each app only looks at **its own** releases:

| | ITE Students | ITE Instructors |
|---|---|---|
| Release **tag** | `students-v<version>`, e.g. `students-v1.0.1` | `instructors-v<version>`, e.g. `instructors-v1.0.1` |
| APK **file name** (exactly) | `ite-students.apk` | `ite-instructors.apk` |
| Android app ID (never change it) | `ph.edu.cok.ite_attendance` | `ph.edu.cok.ite_instructors` |

Rules the app applies:
- Only **published** releases count: drafts and *pre-releases* are ignored, and so are tags
  with another prefix (a bare `v1.0.1` is ignored by both apps).
- `<version>` must be a version number (`1.0.1`, `1.2.0`, `2.0.10`) and must equal the
  `x.y.z` part of `version:` in that build's `pubspec.yaml`.
- The app updates only when the release version is **higher** than the installed one
  (`1.0.10` > `1.0.9`; never a downgrade).
- The release must have the APK attached under the exact file name above. A release without it
  is skipped.
- GitHub shows a SHA-256 checksum ("digest") for every uploaded file; the app downloads the APK,
  recomputes the checksum and refuses to install on any mismatch (or if GitHub gives none).

## 2. Configure the repository

All settings are in **`lib/config/update_config.dart`**:

```dart
static const owner = '0jieE';
static const repo = 'CDK_ITE_Event_Attendance_Portal';
static const tagPrefix = 'instructors-v';
static const apkAsset = 'ite-instructors.apk';
static const autoCheckInterval = Duration(hours: 6);
```

The repository must be **public**: the app reads releases without any token (no secrets are
built into the app). GitHub allows 60 such requests per hour per network, and the app checks at
most every 6 hours on its own (plus when the user taps *⋮ → Check for updates*).

## 3. Versions: `version: x.y.z+N`

`pubspec.yaml` has `version: 1.0.1+4`:
- `1.0.1` is the **version name** — what users see and what the release tag carries.
- `4` is the **build number** (Android `versionCode`). Android only installs an update whose
  build number is **higher** than the installed one, so raise it with **every** build you hand
  out, even if the version name stays the same.

ITE Instructors has its own app ID, so no earlier build of it has been handed out. The old
combined app went out as 1.0.0 builds 2 and 3 (under the student app's ID); to keep the numbers
apart, ITE Instructors starts at `1.0.1+4`. Publish that as the first release
(`instructors-v1.0.1`); the next one is e.g. `1.0.2+5`.

## 4. Signing — read this before publishing

Android accepts an update only if it is signed with **the same key** as the installed app.
Both apps are currently signed with this PC's **debug keystore**
(`C:\Users\ASUS\.android\debug.keystore`; `android/app/build.gradle.kts` → `signingConfig =
signingConfigs.getByName("debug")`). Therefore:
- **Build every release on this PC** (or copy that keystore to the other build PC).
- **Back up `debug.keystore`.** If it is lost, installed apps can never be updated again; users
  would have to uninstall (losing saved data) and install fresh.
- Switching to a separate release keystore later is possible but is a one-time break: every
  phone must uninstall the old app first. If you want that, do it before handing the app to many
  users. (The app's code never touches signing.)

## 5. Publish an update (example: 1.0.1 → 1.0.2)

1. In `mobile_instructor/pubspec.yaml` change `version: 1.0.1+4` to `version: 1.0.2+5`.
   (For the very first release, `1.0.1+4`, skip this step.)
2. Build the signed release APK (in `mobile_instructor/`):
   ```bash
   flutter build apk --release
   ```
   Output: `build/app/outputs/flutter-apk/app-release.apk`.
3. Rename that file to **`ite-instructors.apk`**.
4. Create the GitHub Release `instructors-v1.0.2` with the APK attached — either route:

   **Recommended for now — GitHub website** (works without installing anything):
   1. Open https://github.com/0jieE/CDK_ITE_Event_Attendance_Portal/releases → **Draft a new release**.
   2. *Choose a tag* → type `instructors-v1.0.2` → **Create new tag on publish** (target `main`).
   3. Title e.g. `ITE Instructors 1.0.2`. In the description write the release notes — they are
      shown in the app's update dialog.
   4. Drag `ite-instructors.apk` into *Attach binaries*. Wait until the upload finishes.
   5. Leave **Set as a pre-release** unticked and click **Publish release**.

   **Alternative — GitHub CLI** (needs `gh` installed and a one-time `gh auth login`):
   ```bash
   gh release create instructors-v1.0.2 ite-instructors.apk \
     --repo 0jieE/CDK_ITE_Event_Attendance_Portal \
     --title "ITE Instructors 1.0.2" --notes "What changed..."
   ```
5. Done: phones with an older ITE Instructors find it the next time the app starts or returns
   to the foreground (at most every 6 h), or right away via **⋮ → Check for updates**.

Never commit APKs into git — they belong only in Releases.

## 6. What users see

- **Automatic check** after start-up and when the app returns to the foreground (at most every
  6 hours). If GitHub can't be reached or there is no newer version, nothing is shown.
- **Update available** dialog on the home screen (never over the sign-in screen, the scanner or
  another page): installed version, latest version, download size, release notes, **Update now** /
  **Later**. "Later" hides it for the rest of the session. On the sign-in screen a small
  *Update available* button appears instead.
- **⋮ → Check for updates** (the menu next to *Log out*) shows the installed version and checks
  immediately ("Checking for updates…"), then offers the update or says "You have the latest
  version." or why the check failed.
- **Download** with a progress bar, percentage and MB done / total; **Cancel** stops it. Slow or
  dropped connections, a full storage, HTTP errors and checksum mismatches show a clear message
  with **Try again**; partial or bad files are deleted.
- **Install**: the first time, Android requires the user to allow **Install unknown apps** for
  ITE Instructors — the app explains this and opens the right settings page. Then Android's own
  installer asks the user to confirm. The app is replaced in place; saved data stays.

## 7. Check that it works (on a phone)

1. Install the current build (with the updater) on a phone and sign in once.
2. Publish a release with a **higher** version and build number as in §5.
3. On the phone: *⋮ → Check for updates* → the dialog shows the new version.
4. *Update now* → progress → (first time) allow *Install unknown apps* → Android installer →
   *Update*. Reopen the app: *⋮* shows the new version and you are still signed in.

## 8. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "You have the latest version" although a release exists | Tag prefix or APK name doesn't match §1 exactly; release is a draft or pre-release; version not higher than the installed one. |
| "This update can't be verified" | GitHub gave no checksum for the file. Delete the asset, upload it again, re-check. |
| "didn't pass its security check" | The download was corrupted or the file was replaced. Try again; if it persists, re-upload the APK. |
| Android: "App not installed" / "package conflicts" | Signed with a different key than the installed app (see §4), or the build number isn't higher (§3). |
| "Too many update checks from this network" | GitHub's 60/hour limit for that network; wait an hour. |
| "The app's update page wasn't found on GitHub" | Repository renamed, moved or made private; fix `update_config.dart` or make it public. |
| Install button does nothing / permission screen keeps appearing | Allow *Install unknown apps* for ITE Instructors in Android settings (*Apps → Special app access*). |

## 9. Where the code is

| File | Role |
|---|---|
| `lib/config/update_config.dart` | Repository, tag prefix, APK name, check interval |
| `lib/update/app_version.dart` | Version parsing and comparison |
| `lib/update/github_releases.dart` | GitHub Releases API client, picks the right release and APK |
| `lib/update/update_service.dart` | Checks, throttling, "Later" per session |
| `lib/update/apk_downloader.dart` | Download with progress, cancel, SHA-256 check, clean-up |
| `lib/update/app_installer.dart` + `android/.../MainActivity.kt` | Installed version, update folder, "Install unknown apps", Android installer via `UpdateFileProvider` |
| `lib/update/update_ui.dart` | Checker, prompter, dialog, download progress, install flow, ⋮ menu (`UpdateMenuButton`), sign-in button |
| `android/app/src/main/AndroidManifest.xml`, `res/xml/update_paths.xml` | `REQUEST_INSTALL_PACKAGES`, the FileProvider |
| `test/update_test.dart` | Version comparison, release parsing, update detection, download verification |
| `test/update_ui_test.dart` | One dialog at a time, the ⋮ menu check, the sign-in button |
