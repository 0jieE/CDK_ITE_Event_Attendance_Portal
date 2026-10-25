import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ite_students/update/apk_downloader.dart';
import 'package:ite_students/update/app_installer.dart';
import 'package:ite_students/update/app_version.dart';
import 'package:ite_students/update/github_releases.dart';
import 'package:ite_students/update/update_service.dart';

AppVersion v(String s) => AppVersion.tryParse(s)!;

/// The digest every [release] asset carries unless told otherwise.
const testHex = 'abababababababababababababababababababababababababababababababab';

/// A GitHub release object as the REST API returns it.
Map<String, dynamic> release(
  String tag, {
  bool draft = false,
  bool prerelease = false,
  String asset = 'ite-students.apk',
  String? digest = 'sha256:abababababababababababababababababababababababababababababababab',
  int size = 1234,
  String notes = 'Bug fixes',
}) =>
    {
      'tag_name': tag,
      'name': 'ITE Students $tag',
      'body': notes,
      'draft': draft,
      'prerelease': prerelease,
      'published_at': '2026-10-20T08:00:00Z',
      'assets': [
        {
          'name': asset,
          'size': size,
          'browser_download_url':
              'https://github.com/o/r/releases/download/$tag/$asset',
          'digest': ?digest,
        },
      ],
    };

AppRelease? pick(List<dynamic> releases) => GitHubReleaseClient.pickLatest(
    releases, tagPrefix: 'students-v', apkAsset: 'ite-students.apk');

/// Android side faked: a fixed installed version.
class FakeInstaller extends AppInstaller {
  final String versionName;
  const FakeInstaller(this.versionName);
  @override
  bool get supported => true;
  @override
  Future<InstalledApp> installedApp() async => InstalledApp(versionName, 5);
}

void main() {
  group('AppVersion', () {
    test('compares the way the spec requires', () {
      expect(v('1.0.1') > v('1.0.0'), isTrue); // update
      expect(v('1.0.10') > v('1.0.9'), isTrue); // numeric, not text
      expect(v('1.1.9') > v('1.2.0'), isFalse); // older: no update
      expect(v('2.0.0') > v('2.0.0'), isFalse); // same: no update
      expect(v('2.0.0') == v('2.0.0'), isTrue);
    });

    test('parses tags and Flutter versions', () {
      expect(v('v1.2.3').toString(), '1.2.3');
      expect(v('1.0.0+5') == v('1.0.0'), isTrue); // build number ignored
      expect(v('1.2') == v('1.2.0'), isTrue);
      expect(v('1.2').hashCode, v('1.2.0').hashCode);
      for (final bad in ['', 'latest', '1.x.0', 'v', '1..2', 'students-v1.0.0']) {
        expect(AppVersion.tryParse(bad), isNull, reason: bad);
      }
    });

    test('pre-releases come before their release', () {
      expect(v('1.0.0-beta') < v('1.0.0'), isTrue);
      expect(v('1.0.0-beta.2') < v('1.0.0-beta.10'), isTrue);
      expect(v('1.0.0-alpha') < v('1.0.0-beta'), isTrue);
      expect(v('1.0.0-rc.1').isPreRelease, isTrue);
    });
  });

  group('picking the release', () {
    test('the highest stable release of this app with its APK', () {
      final r = pick([
        release('students-v1.0.9'),
        release('students-v1.0.10', notes: 'New QR screen'),
        release('students-v1.0.2'),
      ])!;
      expect(r.tag, 'students-v1.0.10');
      expect(r.version.toString(), '1.0.10');
      expect(r.notes, 'New QR screen');
      expect(r.apk.size, 1234);
      expect(r.apk.sha256, testHex);
      expect(r.apk.downloadUrl, endsWith('/students-v1.0.10/ite-students.apk'));
    });

    test('skips drafts, pre-releases, other apps, bad tags and missing APKs', () {
      expect(
        pick([
          release('students-v9.0.0', draft: true),
          release('students-v8.0.0', prerelease: true),
          release('students-v7.0.0-beta.1'),
          release('instructors-v6.0.0', asset: 'ite-instructors.apk'),
          release('v5.0.0'),
          release('students-vlatest'),
          release('students-v4.0.0', asset: 'app-release.apk'),
          {
            'tag_name': 'students-v3.0.0',
            'draft': false,
            'prerelease': false,
            'assets': [],
          },
          release('students-v1.0.0'),
        ])!.tag,
        'students-v1.0.0',
      );
    });

    test('nothing usable: null', () {
      expect(pick([]), isNull);
      expect(pick([release('students-v2.0.0', asset: 'other.apk')]), isNull);
      expect(pick(['junk', 42]), isNull);
    });

    test('an asset without a digest is still found, but has no checksum', () {
      expect(pick([release('students-v1.0.1', digest: null)])!.apk.sha256, isNull);
    });
  });

  group('GitHubReleaseClient', () {
    GitHubReleaseClient client(http.Client c) => GitHubReleaseClient(
        client: c, owner: 'o', repo: 'r', tagPrefix: 'students-v',
        apkAsset: 'ite-students.apk');

    test('reads the public releases list (no token)', () async {
      late http.Request seen;
      final c = client(MockClient((req) async {
        seen = req;
        return http.Response(jsonEncode([release('students-v1.0.1')]), 200);
      }));
      expect((await c.latestRelease())!.tag, 'students-v1.0.1');
      expect(seen.url.toString(),
          'https://api.github.com/repos/o/r/releases?per_page=30');
      expect(seen.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('authorization')));
    });

    Future<UpdateCheckFailure> failure(http.Client mock) async {
      try {
        await client(mock).latestRelease();
      } on UpdateCheckException catch (e) {
        return e.kind;
      }
      fail('expected an UpdateCheckException');
    }

    test('rate limits, missing repo, server errors, bad JSON, no network', () async {
      expect(
          await failure(MockClient((_) async => http.Response('{}', 403,
              headers: {'x-ratelimit-remaining': '0'}))),
          UpdateCheckFailure.rateLimited);
      expect(await failure(MockClient((_) async => http.Response('', 429))),
          UpdateCheckFailure.rateLimited);
      expect(await failure(MockClient((_) async => http.Response('{}', 404))),
          UpdateCheckFailure.notFound);
      expect(await failure(MockClient((_) async => http.Response('', 502))),
          UpdateCheckFailure.server);
      expect(await failure(MockClient((_) async => http.Response('<html>', 200))),
          UpdateCheckFailure.badResponse);
      expect(
          await failure(MockClient(
              (_) async => throw const SocketException('no network'))),
          UpdateCheckFailure.network);
    });
  });

  group('UpdateService', () {
    late DateTime now;
    late List<Map<String, dynamic>> releases;
    late int requests;
    late bool offline;

    UpdateService service(String installed) => UpdateService(
          installer: FakeInstaller(installed),
          clock: () => now,
          releases: GitHubReleaseClient(
            client: MockClient((_) async {
              requests++;
              if (offline) throw const SocketException('offline');
              return http.Response(jsonEncode(releases), 200);
            }),
          ),
        );

    setUp(() {
      now = DateTime(2026, 10, 25, 9);
      releases = [release('students-v1.0.10')];
      requests = 0;
      offline = false;
    });

    test('a newer release is available; same or older is not', () async {
      final s = service('1.0.9');
      expect(await s.check(), UpdateStatus.available);
      expect(s.available!.version.toString(), '1.0.10');
      expect(s.shouldPrompt, isTrue);

      expect(await service('1.0.10').check(), UpdateStatus.upToDate);
      // Never a downgrade.
      final newer = service('1.2.0');
      expect(await newer.check(), UpdateStatus.upToDate);
      expect(newer.available, isNull);
    });

    test('no releases yet: up to date', () async {
      releases = [];
      expect(await service('1.0.0').check(), UpdateStatus.upToDate);
    });

    test('automatic checks are throttled; manual ones are not', () async {
      final s = service('1.0.0');
      await s.check();
      await s.check();
      expect(requests, 1);
      now = now.add(const Duration(hours: 7));
      await s.check();
      expect(requests, 2);
      await s.check(manual: true);
      expect(requests, 3);
    });

    test('"Later" is remembered for the session', () async {
      final s = service('1.0.0');
      await s.check();
      s.dismiss(s.available!);
      expect(s.shouldPrompt, isFalse);
      expect(s.available, isNotNull); // still offered from Profile
    });

    test('GitHub unreachable: failed quietly, with a message', () async {
      offline = true;
      final s = service('1.0.0');
      expect(await s.check(), UpdateStatus.failed);
      expect(s.error, contains("Couldn't reach GitHub"));
      expect(s.shouldPrompt, isFalse);
    });

    test('an unreadable installed version never offers an update', () async {
      expect(await service('dev').check(), UpdateStatus.failed);
    });
  });

  group('ApkDownloader', () {
    late Directory dir;
    final bytes = List<int>.generate(10000, (i) => i % 251);
    final goodDigest = sha256.convert(bytes).toString();

    setUp(() async => dir = await Directory.systemTemp.createTemp('upd'));
    tearDown(() async => dir.delete(recursive: true));

    ReleaseAsset asset({String? digest, int? size}) => ReleaseAsset(
          name: 'ite-students.apk',
          downloadUrl: 'https://github.com/o/r/releases/download/x/ite-students.apk',
          size: size ?? bytes.length,
          sha256: digest,
        );

    ApkDownloader downloader(
            Future<http.StreamedResponse> Function(http.BaseRequest) handler) =>
        ApkDownloader(
          newClient: () =>
              MockClient.streaming((req, _) => handler(req)),
        );

    http.StreamedResponse ok() => http.StreamedResponse(
        Stream.fromIterable([bytes.sublist(0, 4000), bytes.sublist(4000)]),
        200,
        contentLength: bytes.length);

    List<String> filesLeft() =>
        dir.listSync().map((f) => f.path.split(Platform.pathSeparator).last).toList();

    test('downloads with progress and verifies the SHA-256', () async {
      final progress = <DownloadProgress>[];
      final apk = await downloader((_) async => ok()).download(
        asset(digest: goodDigest),
        dir: dir,
        onProgress: progress.add,
      );
      expect(await apk.readAsBytes(), bytes);
      expect(filesLeft(), ['ite-students.apk']);
      expect(progress.last.received, bytes.length);
      expect(progress.last.fraction, 1.0);
      expect(progress.map((p) => p.received), [0, 4000, 10000]);
    });

    Future<String> failure(ApkDownloader d, ReleaseAsset a) async {
      try {
        await d.download(a, dir: dir, onProgress: (_) {});
      } on UpdateDownloadException catch (e) {
        return e.message;
      }
      fail('expected an UpdateDownloadException');
    }

    test('a wrong checksum is refused and the file deleted', () async {
      expect(
          await failure(downloader((_) async => ok()), asset(digest: 'cd' * 32)),
          contains('security check'));
      expect(filesLeft(), isEmpty);
    });

    test('no checksum from GitHub: refused before downloading', () async {
      var requested = false;
      final d = downloader((_) async {
        requested = true;
        return ok();
      });
      expect(await failure(d, asset()), contains("can't be verified"));
      expect(requested, isFalse);
    });

    test('incomplete download and HTTP errors are refused', () async {
      expect(
          await failure(downloader((_) async => ok()),
              asset(digest: goodDigest, size: bytes.length + 1)),
          contains('incomplete'));
      expect(
          await failure(
              downloader((_) async =>
                  http.StreamedResponse(const Stream.empty(), 404)),
              asset(digest: goodDigest)),
          contains('HTTP 404'));
      expect(filesLeft(), isEmpty);
    });

    test('cancelling stops and cleans up', () async {
      final cancel = CancelToken();
      final rest = Completer<void>();
      final d = downloader((_) async => http.StreamedResponse(
            () async* {
              yield bytes.sublist(0, 4000);
              await rest.future;
              yield bytes.sublist(4000);
            }(),
            200,
            contentLength: bytes.length,
          ));
      final run = d.download(asset(digest: goodDigest),
          dir: dir, cancel: cancel, onProgress: (p) {
        if (p.received == 4000) {
          cancel.cancel();
          rest.complete();
        }
      });
      await expectLater(run, throwsA(isA<DownloadCancelled>()));
      expect(filesLeft(), isEmpty);
    });

    test('old downloads are cleared before a new one', () async {
      await File('${dir.path}/old.apk').writeAsString('x');
      await File('${dir.path}/ite-students.apk.part').writeAsString('x');
      await downloader((_) async => ok())
          .download(asset(digest: goodDigest), dir: dir, onProgress: (_) {});
      expect(filesLeft(), ['ite-students.apk']);
    });
  });
}
