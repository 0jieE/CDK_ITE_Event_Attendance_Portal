/// A student's fine for an event (from `GET /api/student/fines/`).
class Fine {
  final int id;
  final int event;
  final String eventName;
  final int missedSlots;
  final String amount;
  final String status; // UNPAID | PAID
  final DateTime? paidAt;

  const Fine({
    required this.id,
    required this.event,
    required this.eventName,
    required this.missedSlots,
    required this.amount,
    required this.status,
    required this.paidAt,
  });

  factory Fine.fromJson(Map<String, dynamic> json) {
    return Fine(
      id: json['id'] as int,
      event: json['event'] as int,
      eventName: json['event_name'] as String? ?? '',
      missedSlots: json['missed_slots'] as int? ?? 0,
      amount: '${json['amount'] ?? '0.00'}',
      status: json['status'] as String? ?? 'UNPAID',
      paidAt: json['paid_at'] != null
          ? DateTime.tryParse(json['paid_at'] as String)
          : null,
    );
  }

  bool get isPaid => status == 'PAID';
}

/// Aggregated balance (from `GET /api/student/balance/`).
class Balance {
  final String totalFines;
  final String totalPaid;
  final String outstanding;

  const Balance({
    required this.totalFines,
    required this.totalPaid,
    required this.outstanding,
  });

  factory Balance.fromJson(Map<String, dynamic> json) {
    return Balance(
      totalFines: '${json['total_fines'] ?? '0.00'}',
      totalPaid: '${json['total_paid'] ?? '0.00'}',
      outstanding: '${json['outstanding'] ?? '0.00'}',
    );
  }
}
