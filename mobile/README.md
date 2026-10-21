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
