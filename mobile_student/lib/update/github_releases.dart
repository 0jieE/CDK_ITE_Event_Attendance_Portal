import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/update_config.dart';
import '../utils/errors.dart' show isNetworkError;
import 'app_version.dart';

/// The APK attached to a release.
class ReleaseAsset {
  final String name;
  final String downloadUrl;
  final int size;

  /// Lower-case hex SHA-256 from GitHub's asset `digest` (null if GitHub
  /// gave none - such an asset is never installed).
  final String? sha256;

  const ReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
    required this.sha256,
  });
}

/// A published release of this app that carries its APK.
class AppRelease {
  final String tag;
  final AppVersion version;
  final String title;
  final String notes;
  final DateTime? publishedAt;
  final ReleaseAsset apk;

  const AppRelease({
    required this.tag,
    required this.version,
    required this.title,
    required this.notes,
    required this.publishedAt,
    required this.apk,
  });
}

enum UpdateCheckFailure { network, rateLimited, notFound, server, badResponse }

/// Why an update check failed, with a message fit for the user.
class UpdateCheckException implements Exception {
  final UpdateCheckFailure kind;
  final String message;
  const UpdateCheckException(this.kind, this.message);

  @override
  String toString() => message;
}

/// Reads this app's newest release from GitHub's public REST API (no token:
/// a public repository, 60 requests/hour per IP - plenty for a few checks a
/// day).
class GitHubReleaseClient {
  final http.Client _client;
  final String owner;
  final String repo;
  final String tagPrefix;
  final String apkAsset;

  GitHubReleaseClient({
    http.Client? client,
    this.owner = UpdateConfig.owner,
    this.repo = UpdateConfig.repo,
    this.tagPrefix = UpdateConfig.tagPrefix,
    this.apkAsset = UpdateConfig.apkAsset,
  }) : _client = client ?? http.Client();

  /// This app's newest stable release with an APK, or null when there is none.
  /// Throws [UpdateCheckException].
  Future<AppRelease?> latestRelease() async {
    final uri = Uri.https(
        'api.github.com', '/repos/$owner/$repo/releases', {'per_page': '30'});
    final http.Response res;
    try {
      res = await _client.get(uri, headers: const {
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      }).timeout(const Duration(seconds: 15));
    } catch (e) {
      if (isNetworkError(e)) {
        throw const UpdateCheckException(UpdateCheckFailure.network,
            "Couldn't reach GitHub to check for updates. Check your connection.");
      }
      rethrow;
    }

    final status = res.statusCode;
    if (status == 200) {
      final dynamic body;
      try {
        body = jsonDecode(res.body);
      } on FormatException {
        throw const UpdateCheckException(UpdateCheckFailure.badResponse,
            'GitHub sent an unexpected reply. Try again later.');
      }
      if (body is! List) {
        throw const UpdateCheckException(UpdateCheckFailure.badResponse,
            'GitHub sent an unexpected reply. Try again later.');
      }
      return pickLatest(body, tagPrefix: tagPrefix, apkAsset: apkAsset);
    }
    if (status == 429 ||
        (status == 403 && res.headers['x-ratelimit-remaining'] == '0')) {
      throw const UpdateCheckException(UpdateCheckFailure.rateLimited,
          'Too many update checks from this network for now. Try again in an hour.');
    }
    if (status == 404) {
      throw const UpdateCheckException(UpdateCheckFailure.notFound,
          "The app's update page wasn't found on GitHub.");
    }
    throw UpdateCheckException(UpdateCheckFailure.server,
        'GitHub had a problem (HTTP $status). Try again later.');
  }

  /// From GitHub's release list: the highest-versioned release that is
  /// published (not a draft or pre-release), tagged `<tagPrefix><version>`
  /// with a valid version, and carries [apkAsset]. Anything else is skipped.
  static AppRelease? pickLatest(
    List<dynamic> releases, {
    required String tagPrefix,
    required String apkAsset,
  }) {
    AppRelease? best;
    for (final r in releases) {
      if (r is! Map) continue;
      if (r['draft'] == true || r['prerelease'] == true) continue;
      final tag = r['tag_name'];
      if (tag is! String || !tag.startsWith(tagPrefix)) continue;
      final version = AppVersion.tryParse(tag.substring(tagPrefix.length));
      if (version == null || version.isPreRelease) continue;
      final asset = _apkOf(r['assets'], apkAsset);
      if (asset == null) continue;
      if (best != null && !(version > best.version)) continue;
      best = AppRelease(
        tag: tag,
        version: version,
        title: '${r['name'] ?? ''}'.trim().isEmpty ? tag : '${r['name']}',
        notes: '${r['body'] ?? ''}'.trim(),
        publishedAt: DateTime.tryParse('${r['published_at']}'),
        apk: asset,
      );
    }
    return best;
  }

  static ReleaseAsset? _apkOf(dynamic assets, String name) {
    if (assets is! List) return null;
    for (final a in assets) {
      if (a is! Map) continue;
      if ('${a['name']}'.toLowerCase() != name.toLowerCase()) continue;
      final url = a['browser_download_url'];
      if (url is! String || !url.startsWith('https://')) continue;
      final digest = '${a['digest'] ?? ''}';
      return ReleaseAsset(
        name: '${a['name']}',
        downloadUrl: url,
        size: (a['size'] as num?)?.toInt() ?? 0,
        sha256: digest.startsWith('sha256:')
            ? digest.substring(7).toLowerCase()
            : null,
      );
    }
    return null;
  }

  void close() => _client.close();
}
