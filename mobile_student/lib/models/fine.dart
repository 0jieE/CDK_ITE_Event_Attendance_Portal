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

/// Aggregated balance (from `GET /api/student/balance/`). [totalFines],
/// [totalPaid] and [outstanding] are fines only; the contribution keys and
/// [totalOutstanding] (fines + contributions) came later, so a response saved
/// offline by an older server may lack them.
class Balance {
  final String totalFines;
  final String totalPaid;
  final String outstanding;
  final String contributionsTotal;
  final String contributionsPaid;
  final String contributionsOutstanding;
  final String totalOutstanding;

  const Balance({
    required this.totalFines,
    required this.totalPaid,
    required this.outstanding,
    this.contributionsTotal = '0.00',
    this.contributionsPaid = '0.00',
    this.contributionsOutstanding = '0.00',
    String? totalOutstanding,
  }) : totalOutstanding = totalOutstanding ?? outstanding;

  factory Balance.fromJson(Map<String, dynamic> json) {
    final outstanding = '${json['outstanding'] ?? '0.00'}';
    return Balance(
      totalFines: '${json['total_fines'] ?? '0.00'}',
      totalPaid: '${json['total_paid'] ?? '0.00'}',
      outstanding: outstanding,
      contributionsTotal: '${json['contributions_total'] ?? '0.00'}',
      contributionsPaid: '${json['contributions_paid'] ?? '0.00'}',
      contributionsOutstanding:
          '${json['contributions_outstanding'] ?? '0.00'}',
      totalOutstanding: '${json['total_outstanding'] ?? outstanding}',
    );
  }
}
