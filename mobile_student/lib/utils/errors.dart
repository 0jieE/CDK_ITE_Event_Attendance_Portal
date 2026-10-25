import 'dart:async';
import 'dart:io' show HandshakeException, SocketException;

import 'package:http/http.dart' as http;

import '../services/api_service.dart';

/// A short, human message for any error raised by a request.
String friendlyError(Object error) {
  if (error is ApiException) return error.message;
  if (error is OfflineDataMissing) return error.message;
  if (error is SessionExpired) {
    return 'Your session expired. Please sign in again.';
  }
  if (error is TimeoutException) {
    return 'The server took too long to respond. Please try again.';
  }
  return 'Could not reach the server. Check your connection and try again.';
}

/// True when [error] means the server couldn't be reached at all (no signal,
/// no internet, DNS/TLS failure, timeout) rather than the server saying no.
bool isNetworkError(Object error) =>
    error is OfflineDataMissing ||
    error is SocketException ||
    error is http.ClientException ||
    error is TimeoutException ||
    error is HandshakeException;

/// Per-field server errors (`{"username": ["..."]}`) from a 400 response, with
/// each field's messages joined. Empty when the error isn't field-shaped.
Map<String, String> fieldErrors(Object error) {
  if (error is! ApiException || error.data is! Map) return const {};
  final out = <String, String>{};
  (error.data as Map).forEach((k, v) {
    if (v is List && v.isNotEmpty) {
      out['$k'] = v.map((e) => '$e').join(' ');
    } else if (v is String && k != 'detail') {
      out['$k'] = v;
    }
  });
  return out;
}
