/// A student's **daily** QR code (from the student QR endpoints).
///
/// The [token] is all the app needs to render the QR (drawn on the phone,
/// so it shows offline too); the instructor's scan resolves the student, day
/// and slot server-side (slot is chosen by scan time).
class QrSlot {
  final int? id;
  final String token;
  final int event;
  final DateTime date;
  final String? imageUrl;

  const QrSlot({
    required this.id,
    required this.token,
    required this.event,
    required this.date,
    required this.imageUrl,
  });

  factory QrSlot.fromJson(Map<String, dynamic> json) {
    return QrSlot(
      id: json['id'] as int?,
      token: json['token'] as String,
      event: json['event'] as int,
      date: DateTime.parse(json['date'] as String),
      imageUrl: json['image_url'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'token': token,
        'event': event,
        'date': '${date.year.toString().padLeft(4, '0')}-'
            '${date.month.toString().padLeft(2, '0')}-'
            '${date.day.toString().padLeft(2, '0')}',
        'image_url': imageUrl,
      };
}
