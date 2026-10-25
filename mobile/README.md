> **This is the earlier combined app (instructor + student in one).** It has been split into two
> separate apps: [`../mobile_student`](../mobile_student) (**ITE Students**) and
> [`../mobile_instructor`](../mobile_instructor) (**ITE Instructors**, QR scanning). Use those for new
> installs; this folder is kept for reference and still works against the same API.

# ITE Attendance — Mobile App (Flutter)

Single Flutter app for the **Hybrid QR-Code Based Attendance & Financial
Management System**. After login it calls `GET /api/me/` and routes by role to
the **Instructor** or **Student** interface (one codebase, two interfaces).

## Stack
Flutter (stable) · `provider` (state) · `http` · `flutter_secure_storage`
(JWT) · `mobile_scanner` (instructor camera) · `qr_flutter` (student QR) ·
`intl`.

## Configure the backend URL
`lib/config/api_config.dart` -> `ApiConfig.baseUrl`. Pick by how the Django dev
server is bound and where the app runs:

| Server bind | App runs on | Use |
|-------------|-------------|-----|
| `runserver 0.0.0.0:8000` | Android emulator | `http://10.0.2.2:8000` |
| `runserver LAN_IP:8000` | emulator or real device (same Wi-Fi) | `http://LAN_IP:8000` |
| any | iOS simulator | `http://127.0.0.1:8000` |

Override without editing code:
```bash
flutter run --dart-define=API_BASE_URL=http://192.168.1.10:8000
```
The Django side must allow that host (`ALLOWED_HOSTS`). Debug/profile builds allow
plain HTTP; **release builds allow cleartext only if the baked-in `API_BASE_URL` is `http://`** (see below).

### Release APK against the deployed backend
```bash
flutter build apk --release --dart-define=API_BASE_URL=https://attendance.example.com
# plain-HTTP demo server (cleartext is allowed automatically for an http:// URL):
flutter build apk --release --dart-define=API_BASE_URL=http://192.168.1.20
```
Output: `build/app/outputs/flutter-apk/app-release.apk`. Details in the backend's
`DEPLOYMENT.md` (§7).

## Run
```bash
flutter pub get
flutter run            # device/emulator must reach the backend
```
Sign in with an **instructor** or **student** account. There is no self-registration: accounts
are issued by the Department Adviser, who gives each student a username and password. Admins are sent to a
"use the web portal" screen by design.

## Instructor features
- **Scan:** pick today's event and scan students' QR codes.
- **Attendance:** review attendance in **every** event (finished, running, upcoming): choose a day,
  see per-slot present/absent totals and each student's status (search + Missing/Complete filters).
- **Offline scanning:** opening the Scan tab or the scanner downloads an *offline pack* (today's
  events and today's student QR codes, hashed). With no connection a scan is checked on the phone
  (student name, open slot, duplicates) and saved with its scan time (corrected by the server
  clock), shown as a blue **Saved offline** card. A QR generated after the last download is still
  saved, as *not verified yet*. Saved scans upload automatically when the connection returns (or
  **Sync now**); the server judges each one at its original scan time, and the Scan tab lists any
  it rejected. The queue is per instructor and survives restarts and log-outs.

## Student features
- **QR:** one QR per event-day. Only today's date is selectable (other days of a multi-day event are
  muted); once generated it is shown inline with a full-screen view instead of the Generate button.
  **Offline:** generating needs a connection, but today's QR (and the event list) is kept on the
  phone, so a QR generated earlier still shows and can be scanned.
- **Offline start (both roles):** the app opens with the last signed-in account when there is no
  connection, with a "You're offline" strip under the app bar.

## Offline sign-in (instructors and students)
An account that has signed in **online** on a phone can later sign in on that phone with **no
connection** (also after a log-out or an app restart). The first sign-in on a phone must be online;
admin accounts are never remembered.
- **Storage:** after each online sign-in the password is kept only as a salted **PBKDF2-HMAC-SHA256**
  hash (100,000 rounds, random 16-byte salt per account, computed in a background isolate) together
  with the profile, in secure storage (Android Keystore / iOS Keychain), under a key derived from
  the username (`services/offline_credentials.dart`). The password itself is never stored.
- **Wrong passwords:** 5 tries, then a 30 s wait that doubles with each further miss (max 1 h).
- **Expiry:** offline sign-in is refused 30 days after the account's last online sign-in
  ("Connect to the internet to sign in again"), and the stored hash is deleted.
- **What it gives:** the existing offline features only (instructor: offline pack + scan queue;
  student: saved QR and events). There is no server session behind it; scans go straight to the
  offline queue.
- **Back online:** the session is re-checked. A still-valid server session (tokens kept from before)
  carries on online; otherwise the user goes to the login screen with their username filled in and a
  "sign in again" note. Offline scans stay queued and upload after that online sign-in, under the
  same instructor.
- **Stale passwords:** if the server refuses, online, the password this phone remembers (changed by
  the adviser, or the account disabled), the stored hash is deleted; a mere typo keeps it. If
  `/api/me/` returns a `password_version`, a mismatch on reconnect also deletes it and signs out.
  Changing the password in the app updates the stored hash.
- **Log-out** keeps offline sign-in; tick **Forget this phone** in the log-out dialog to remove it
  (that also deletes the account's saved screens; unsynced scans are kept).

## Offline data
Everything a screen shows is saved on the phone, per user, so it is there after going offline,
closing the app and reopening it:
- **Download up front:** right after an online sign-in (and whenever the app comes back online or
  to the foreground, at most every 2 min) `OfflinePrefetcher` downloads every screen's data,
  without waiting for tabs to be opened. Student: events (current + all), today's QR for each
  running event, attendance history, fines, balance, profile. Instructor: the offline pack,
  all events, and today's roster of each running event.
- **Read-through cache** (`ApiService`): each screen request is saved under
  `cache:<user id>:<path>?<sorted query>`. Known offline, the network isn't tried at all; on a
  network failure the saved copy is used. With nothing saved, the screen says so ("Open the app once
  with internet…") instead of showing an empty list. A history for one event falls back to the
  saved history of all events.
- **The offline strip** under the app bar says when the shown data was saved.
- **Reconnecting:** besides Wi-Fi / data changes, the app checks the server every 20 s while it is
  unreachable on an active connection (Wi-Fi without internet), so it notices when the internet
  returns.
- The student QR is drawn on the phone from its token, so it needs no image download.
- **History:** filter by event (defaults to the event closest to today), grouped by date.
- **Profile:** change photo (camera/gallery), name, username and password.
- **Theme:** Material 3 in the ITE brand green `#41B422` (light only).

## Structure
```
lib/
  config/api_config.dart    base URL
  models/                   User, Event, AttendanceLog, Fine, QrSlot,
                            ScanResult, StudentProfile, AttendanceType, Balance
  services/
    token_storage.dart      secure JWT storage
    api_service.dart        auth + typed endpoints; attaches JWT, refreshes
                            on 401, else SessionExpired
    auth_provider.dart      ChangeNotifier auth state
  widgets/                  AsyncListView, AsyncView, StatusChip, LogoutAction
  screens/
    login_screen.dart
    instructor/             instructor_home (events) + scanner_screen
    student/                student_home (bottom nav) + dashboard / generate_qr /
                            qr_display / history / fines tabs
  main.dart                 RootRouter: splash -> login -> role home
```

## Notes
- **Auth/refresh:** every request carries `Authorization: Bearer <access>`; a
  `401` triggers one silent refresh + retry, and on failure clears tokens and
  bounces to login.
- **Instructor scanner:** debounces repeated reads (same token within 3 s and
  `DetectionSpeed.noDuplicates`), pauses while a scan is in flight, and shows a
  color-coded result card (recorded / already-recorded / invalid / stale /
  inactive / **outside attendance time**) with haptic + click feedback. The
  recorded **slot is chosen server-side** from the scan time and the event's
  windows.
- **Student QR (per day):** the student picks an event + date and generates a
  single **daily** QR (no slot picker — the slot is decided when scanned). It's
  rendered fullscreen on white at high contrast, and shows the event's per-slot
  **scan windows** so the student knows when to present it.
- Loading / error (retry) / empty states and pull-to-refresh on every data screen.
- `minSdk` is pinned to 23 (required by `mobile_scanner` 7.x / CameraX).
