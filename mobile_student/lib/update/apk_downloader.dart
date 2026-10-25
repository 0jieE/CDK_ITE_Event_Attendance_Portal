import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'github_releases.dart';

/// Bytes received so far, and the total when known.
class DownloadProgress {
  final int received;
  final int? total;
  const DownloadProgress(this.received, this.total);

  /// 0..1, or null when the size is unknown.
  double? get fraction =>
      (total == null || total! <= 0) ? null : (received / total!).clamp(0, 1);
}

/// Lets the user stop a download; the partial file is deleted.
class CancelToken {
  bool _cancelled = false;
  void Function()? _onCancel;

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _onCancel?.call();
  }
}

class DownloadCancelled implements Exception {
  const DownloadCancelled();
}

/// A download that failed or couldn't be verified; [message] is for the user.
class UpdateDownloadException implements Exception {
  final String message;
  const UpdateDownloadException(this.message);

  @override
  String toString() => message;
}

/// Downloads a release APK into [dir] (the app's private cache), checking
/// it against GitHub's SHA-256 digest before handing it over. A file that is
/// incomplete, the wrong size or the wrong checksum is deleted, never
/// returned.
class ApkDownloader {
  final http.Client Function() _newClient;

  /// Give up when no bytes arrive for this long.
  final Duration stallTimeout;

  ApkDownloader({
    http.Client Function()? newClient,
    this.stallTimeout = const Duration(seconds: 30),
  }) : _newClient = newClient ?? http.Client.new;

  Future<File> download(
    ReleaseAsset asset, {
    required Directory dir,
    required void Function(DownloadProgress) onProgress,
    CancelToken? cancel,
  }) async {
    final expected = asset.sha256;
    if (expected == null || expected.length != 64) {
      throw const UpdateDownloadException(
          "This update can't be verified (GitHub gave no checksum for it), so "
          "it won't be installed. Ask the administrator to publish it again.");
    }

    await dir.create(recursive: true);
    await _clearOldDownloads(dir);
    final part = File('${dir.path}/${asset.name}.part');
    final client = _newClient();
    cancel?._onCancel = client.close;
    var ok = false;
    try {
      final request = http.Request('GET', Uri.parse(asset.downloadUrl))
        ..headers['Accept'] = 'application/octet-stream';
      final response = await client.send(request).timeout(stallTimeout);
      if (response.statusCode != 200) {
        throw UpdateDownloadException(
            'The download failed (HTTP ${response.statusCode}). Try again later.');
      }
      final total = (response.contentLength != null && response.contentLength! > 0)
          ? response.contentLength
          : (asset.size > 0 ? asset.size : null);

      final digest = _DigestSink();
      final hasher = sha256.startChunkedConversion(digest);
      final sink = part.openWrite();
      var received = 0;
      onProgress(DownloadProgress(0, total));
      try {
        await for (final chunk in response.stream.timeout(stallTimeout)) {
          if (cancel?.isCancelled ?? false) throw const DownloadCancelled();
          sink.add(chunk);
          hasher.add(chunk);
          received += chunk.length;
          onProgress(DownloadProgress(received, total));
        }
      } finally {
        await sink.close();
      }
      hasher.close();
      if (cancel?.isCancelled ?? false) throw const DownloadCancelled();

      if (asset.size > 0 && received != asset.size) {
        throw const UpdateDownloadException(
            'The download was incomplete. Try again.');
      }
      if (digest.value.toString() != expected.toLowerCase()) {
        throw const UpdateDownloadException(
            "The downloaded file didn't pass its security check, so it won't "
            'be installed. Try again.');
      }
      final apk = await part.rename('${dir.path}/${asset.name}');
      ok = true;
      return apk;
    } on DownloadCancelled {
      rethrow;
    } on UpdateDownloadException {
      rethrow;
    } on TimeoutException {
      throw const UpdateDownloadException(
          'The connection is too slow or stopped responding. Try again on a '
          'better connection.');
    } on FileSystemException catch (e) {
      throw UpdateDownloadException(_isNoSpace(e)
          ? 'Not enough free storage for the update. Free some space and try '
              'again.'
          : "The update couldn't be saved on this phone.");
    } catch (e) {
      if (cancel?.isCancelled ?? false) throw const DownloadCancelled();
      throw const UpdateDownloadException(
          'The connection was lost during the download. Try again.');
    } finally {
      client.close();
      if (!ok && await part.exists()) {
        await part.delete().catchError((_) => part);
      }
    }
  }

  static bool _isNoSpace(FileSystemException e) {
    final code = e.osError?.errorCode;
    return code == 28 /* ENOSPC */ || code == 112 /* Windows */ ||
        (e.osError?.message.toLowerCase().contains('space') ?? false);
  }

  /// Old or unfinished APKs from earlier attempts.
  static Future<void> _clearOldDownloads(Directory dir) async {
    try {
      await for (final f in dir.list()) {
        if (f is File && (f.path.endsWith('.apk') || f.path.endsWith('.part'))) {
          await f.delete();
        }
      }
    } catch (_) {/* best effort */}
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? _value;
  Digest get value => _value!;

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
}
