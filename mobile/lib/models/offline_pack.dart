import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'event.dart';

/// SHA-256 hex of a QR token - how the offline pack names a code (the server
/// never sends raw tokens).
String hashToken(String token) => sha256.convert(utf8.encode(token)).toString();

/// One student QR from the offline pack.
class OfflineCode {
  final int eventId;
  final String studentName;
  final String studentNumber;

  /// Slots already recorded for this student today (as of the download).
  final Set<String> credited;

  const OfflineCode({
    required this.eventId,
    required this.studentName,
    required this.studentNumber,
    required this.credited,
  });
}

/// What an instructor needs to keep scanning with no connection
/// (`GET /api/instructor/offline-pack/`): today's events and their windows,
/// and today's student QR codes by hash.
class OfflinePack {
  /// The day the pack is for (Manila date, components only).
  final DateTime date;

  /// Server clock minus phone clock at download, so offline scan times are
  /// right even when the phone's clock is off.
  final Duration clockOffset;

  final List<Event> events;
  final Map<String, OfflineCode> codes;

  /// The response as received plus when it arrived (for persisting).
  final Map<String, dynamic> raw;
  final DateTime receivedAt;

  OfflinePack._(this.date, this.clockOffset, this.events, this.codes, this.raw,
      this.receivedAt);

  factory OfflinePack.fromJson(Map<String, dynamic> json, DateTime receivedAt) {
    final server = DateTime.tryParse('${json['server_time']}');
    final date = DateTime.parse(json['date'] as String);
    return OfflinePack._(
      DateTime(date.year, date.month, date.day),
      server == null ? Duration.zero : server.difference(receivedAt),
      [
        for (final e in json['events'] as List? ?? const [])
          Event.fromJson(e as Map<String, dynamic>),
      ],
      {
        for (final c in json['codes'] as List? ?? const [])
          '${c['hash']}': OfflineCode(
            eventId: c['event'] as int,
            studentName: '${c['student_name'] ?? ''}',
            studentNumber: '${c['student_number'] ?? ''}',
            credited: {
              for (final s in c['credited'] as List? ?? const []) '$s',
            },
          ),
      },
      json,
      receivedAt,
    );
  }

  Event? eventById(int id) => events.where((e) => e.id == id).firstOrNull;

  Map<String, dynamic> toStore() =>
      {'pack': raw, 'received_at': receivedAt.toUtc().toIso8601String()};

  static OfflinePack? fromStore(dynamic stored) {
    if (stored is! Map) return null;
    try {
      return OfflinePack.fromJson(
        Map<String, dynamic>.from(stored['pack'] as Map),
        DateTime.parse(stored['received_at'] as String),
      );
    } catch (_) {
      return null;
    }
  }
}

/// A scan taken with no connection, waiting to be sent to the server.
class QueuedScan {
  final String token;

  /// When it was scanned (clock-corrected instant).
  final DateTime scannedAt;

  /// Known only when the code was in the offline pack.
  final String? studentName;
  final String? studentNumber;
  final int? eventId;

  /// The slot it was taken for, as the phone judged it (for de-duplication).
  final String? slot;

  const QueuedScan({
    required this.token,
    required this.scannedAt,
    this.studentName,
    this.studentNumber,
    this.eventId,
    this.slot,
  });

  /// "Name (number)" or a placeholder for an unknown code.
  String get label => studentName == null
      ? 'Unknown student'
      : '$studentName ($studentNumber)';

  Map<String, dynamic> toJson() => {
        'token': token,
        'scanned_at': scannedAt.toUtc().toIso8601String(),
        'student_name': studentName,
        'student_number': studentNumber,
        'event': eventId,
        'slot': slot,
      };

  factory QueuedScan.fromJson(Map<String, dynamic> json) => QueuedScan(
        token: json['token'] as String,
        scannedAt: DateTime.parse(json['scanned_at'] as String),
        studentName: json['student_name'] as String?,
        studentNumber: json['student_number'] as String?,
        eventId: json['event'] as int?,
        slot: json['slot'] as String?,
      );
}
