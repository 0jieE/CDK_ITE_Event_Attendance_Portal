import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ite_attendance/models/offline_pack.dart';
import 'package:ite_attendance/models/qr_slot.dart';
import 'package:ite_attendance/screens/instructor/scanner_screen.dart';
import 'package:ite_attendance/services/api_service.dart';
import 'package:ite_attendance/services/connectivity_service.dart';
import 'package:ite_attendance/services/offline_scan_service.dart';
import 'package:ite_attendance/theme/app_theme.dart';

import 'test_helpers.dart';

http.Response json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

/// Oct 8 2026, [hour]:[minute] in Manila (UTC+8) as an instant.
DateTime manila(int hour, [int minute = 0]) =>
    DateTime.utc(2026, 10, 8, hour, minute).subtract(const Duration(hours: 8));

/// Pack for Oct 8: one event (AM-In 07:00-08:00, AM-Out 11:30-12:00), Maria
/// with nothing recorded yet and Ana already in for AM-In.
Map<String, dynamic> packJson() => {
      'server_time': '2026-10-08T07:30:00+08:00',
      'date': '2026-10-08',
      'events': [eventJson(3, 'Tech Week', '2026-10-08', '2026-10-08')],
      'codes': [
        {
          'hash': hashToken('tok-maria'),
          'event': 3,
          'student_name': 'Maria Santos',
          'student_number': 'DEMO-001',
          'credited': [],
        },
        {
          'hash': hashToken('tok-ana'),
          'event': 3,
          'student_name': 'Ana Reyes',
          'student_number': 'DEMO-003',
          'credited': ['AM_IN'],
        },
      ],
    };

/// A fake server: serves the pack and answers sync with [syncReply];
/// [offline] makes every request fail like a dead network.
class FakeServer {
  bool offline = false;

  /// An older server (no offline endpoints): the pack is a 404.
  bool noPack = false;
  List<Map<String, dynamic>> syncReply = const [];
  final syncBodies = <Map<String, dynamic>>[];

  late final client = MockClient((req) async {
    if (offline) throw http.ClientException('Network is unreachable');
    if (req.url.path.endsWith('/instructor/offline-pack/')) {
      return noPack ? json({'detail': 'Not found.'}, 404) : json(packJson());
    }
    if (req.url.path.endsWith('/instructor/events/')) {
      return json({'results': [eventJson(4, 'Plain list', '2026-10-08', '2026-10-08')]});
    }
    if (req.url.path.endsWith('/instructor/scans/sync/')) {
      syncBodies.add(jsonDecode(req.body) as Map<String, dynamic>);
      return json({'results': syncReply});
    }
    return json({'detail': 'unexpected'}, 404);
  });
}

void main() {
  late FakeServer server;
  late DateTime clock;

  late ConnectivityService connectivity;

  OfflineScanService service() => OfflineScanService(
        api: ApiService(tokens: FakeTokens(), client: server.client),
        connectivity: connectivity,
        clock: () => clock,
      );

  setUp(() {
    connectivity = ConnectivityService(listen: false);
    server = FakeServer();
    clock = manila(7, 30);
  });

  test('known codes are judged on the phone: name, slot and duplicates', () async {
    final svc = service();
    await svc.attach(1);
    await svc.refreshPack();
    server.offline = true;

    final first = await svc.scanOffline('tok-maria');
    expect(first.ok && first.created && first.offline, isTrue);
    expect(first.unverified, isFalse);
    expect(first.studentName, 'Maria Santos');
    expect(first.attendanceTypeDisplay, 'AM Time-In');
    expect(first.eventName, 'Tech Week');
    expect(svc.pendingCount, 1);

    // Same student, same slot: not queued twice.
    final again = await svc.scanOffline('tok-maria');
    expect(again.ok, isTrue);
    expect(again.created, isFalse);
    // Already recorded on the server before the pack was downloaded.
    final ana = await svc.scanOffline('tok-ana');
    expect(ana.created, isFalse);
    expect(svc.pendingCount, 1);
    svc.dispose();
  });

  test('a code missing from the pack is queued unverified', () async {
    final svc = service();
    await svc.attach(1);
    await svc.refreshPack();
    final r = await svc.scanOffline('tok-generated-later');
    expect(r.ok && r.created && r.unverified, isTrue);
    expect(r.studentName, isNull);
    expect(svc.queue.single.slot, 'AM_IN');
    expect((await svc.scanOffline('tok-generated-later')).created, isFalse);
    expect(svc.pendingCount, 1);
    svc.dispose();
  });

  test('with no pack at all, scans are still queued', () async {
    final svc = service();
    await svc.attach(1);
    final r = await svc.scanOffline('tok-maria');
    expect(r.ok && r.unverified, isTrue);
    expect(svc.pendingCount, 1);
    svc.dispose();
  });

  test('outside every scan window nothing is queued', () async {
    final svc = service();
    await svc.attach(1);
    await svc.refreshPack();
    clock = manila(10);
    for (final token in ['tok-maria', 'tok-unknown']) {
      final r = await svc.scanOffline(token);
      expect(r.ok, isFalse);
      expect(r.code, 'OUTSIDE_WINDOW');
    }
    expect(svc.pendingCount, 0);
    svc.dispose();
  });

  test('the phone clock is corrected by the server time from the pack', () async {
    clock = manila(7, 20); // phone is 10 minutes slow (server says 07:30)
    final svc = service();
    await svc.attach(1);
    await svc.refreshPack();
    clock = manila(7, 25);
    await svc.scanOffline('tok-maria');
    expect(svc.queue.single.scannedAt, manila(7, 35));
    svc.dispose();
  });

  test('sync uploads the queue and reports each outcome', () async {
    final svc = service();
    await svc.attach(1);
    await svc.refreshPack();
    await svc.scanOffline('tok-maria');
    await svc.scanOffline('tok-bogus');
    server.syncReply = [
      {'http_status': 201, 'detail': 'Attendance recorded.'},
      {'http_status': 404, 'code': 'INVALID_TOKEN', 'detail': 'Invalid QR code.'},
    ];

    final report = await svc.sync();
    expect(server.syncBodies.single['scans'], [
      {'token': 'tok-maria', 'scanned_at': '2026-10-07T23:30:00.000Z'},
      {'token': 'tok-bogus', 'scanned_at': '2026-10-07T23:30:00.000Z'},
    ]);
    expect(report!.recorded, 1);
    expect(report.alreadyRecorded, 0);
    expect(report.rejected.single.label, 'Unknown student');
    expect(report.rejected.single.reason, 'Invalid QR code.');
    expect(svc.pendingCount, 0);
    svc.dispose();
  });

  test('a failed sync keeps the queue, which survives a restart', () async {
    final svc = service();
    await svc.attach(1);
    await svc.refreshPack();
    await svc.scanOffline('tok-maria');
    server.offline = true;
    expect(await svc.sync(), isNull);
    expect(svc.pendingCount, 1);
    expect(svc.syncError, contains('offline'));
    svc.dispose();

    // A fresh start (app restarted) for the same instructor finds it again;
    // another instructor does not see it.
    final other = service();
    await other.attach(2);
    expect(other.pendingCount, 0);
    await other.attach(1);
    expect(other.pendingCount, 1);
    expect(other.queue.single.studentName, 'Maria Santos');
    expect(other.pack, isNotNull);
    other.dispose();
  });

  test('loadEvents falls back to the downloaded pack when offline', () async {
    final svc = service();
    await svc.attach(1);
    server.offline = true;
    // Nothing saved yet: a clear message, not an empty list.
    await expectLater(
        svc.loadEvents(),
        throwsA(isA<OfflineDataMissing>().having(
            (e) => e.message, 'message', contains("aren't saved on this phone"))));
    expect(connectivity.isOnline, isFalse);

    server.offline = false;
    connectivity.reportReachable();
    expect((await svc.loadEvents()).single.name, 'Tech Week');

    // Known offline: the saved pack, without even trying the network.
    server.offline = true;
    connectivity.reportUnreachable();
    expect((await svc.loadEvents()).single.name, 'Tech Week');

    // The pack is for one day only.
    clock = manila(7, 30).add(const Duration(days: 1));
    await expectLater(
        svc.loadEvents(),
        throwsA(isA<OfflineDataMissing>()
            .having((e) => e.message, 'message', contains('from Oct 8'))));
    svc.dispose();
  });

  test('cold start offline: events wait for the saved pack to load', () async {
    final first = service();
    await first.attach(1);
    await first.refreshPack(); // saved on the phone
    first.dispose();

    // App restarted with no connection: the Scan tab asks before attach().
    server.offline = true;
    connectivity.reportUnreachable();
    final svc = service();
    final events = svc.loadEvents();
    await svc.attach(1);
    expect((await events).single.name, 'Tech Week');
    svc.dispose();
  });

  test('a server without the offline pack still lists the events', () async {
    server.noPack = true;
    final svc = service();
    await svc.attach(1);
    expect((await svc.loadEvents()).single.name, 'Plain list');
    expect(svc.pack, isNull);
    svc.dispose();
  });

  testWidgets('result card: saved offline vs not verified', (tester) async {
    Future<void> show(ScanResult r) => tester.pumpWidget(MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(body: ScanResultCard(result: r, onDismiss: () {})),
        ));

    await show(ScanResult(
      ok: true,
      created: true,
      offline: true,
      detail: 'Saved on this phone.',
      studentName: 'Maria Santos',
      studentNumber: 'DEMO-001',
      eventName: 'Tech Week',
      attendanceTypeDisplay: 'AM Time-In',
      scannedAt: manila(7, 30),
    ));
    expect(find.text('Saved offline'), findsOneWidget);
    expect(find.text('Maria Santos (DEMO-001)'), findsOneWidget);
    expect(find.text('AM Time-In · Tech Week'), findsOneWidget);

    await show(ScanResult(
      ok: true,
      created: true,
      offline: true,
      unverified: true,
      detail: 'Saved on this phone.',
      attendanceTypeDisplay: 'AM Time-In',
    ));
    expect(find.text('Saved offline (not verified yet)'), findsOneWidget);
    expect(find.text('Unknown student'), findsOneWidget);
    expect(find.text('AM Time-In'), findsOneWidget);
  });
}
