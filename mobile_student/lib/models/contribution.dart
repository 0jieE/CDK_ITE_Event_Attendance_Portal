/// One cash payment toward a contribution.
class ContributionPayment {
  final int id;
  final String amount;
  final DateTime? paidAt;
  final String note; // e.g. an OR number

  const ContributionPayment({
    required this.id,
    required this.amount,
    required this.paidAt,
    required this.note,
  });

  factory ContributionPayment.fromJson(Map<String, dynamic> json) {
    return ContributionPayment(
      id: json['id'] as int,
      amount: '${json['amount'] ?? '0.00'}',
      paidAt: json['paid_at'] != null
          ? DateTime.tryParse(json['paid_at'] as String)
          : null,
      note: json['note'] as String? ?? '',
    );
  }
}

/// A department contribution every student owes for a semester (from
/// `GET /api/student/contributions/`). Read-only: payments are recorded by
/// the adviser, partial payments add up.
class Contribution {
  final int id;
  final String name;
  final String description;
  final int semester;
  final String semesterName;
  final bool isActiveSemester;
  final String amount;
  final DateTime? dueDate;
  final String owed; // "0.00" when exempt
  final String paid;
  final String balance;
  final String status; // PAID | PARTIAL | UNPAID | EXEMPT
  final String statusDisplay;
  final bool exempt;
  final String exemptionReason;
  final List<ContributionPayment> payments; // newest first

  const Contribution({
    required this.id,
    required this.name,
    required this.description,
    required this.semester,
    required this.semesterName,
    required this.isActiveSemester,
    required this.amount,
    required this.dueDate,
    required this.owed,
    required this.paid,
    required this.balance,
    required this.status,
    required this.statusDisplay,
    required this.exempt,
    required this.exemptionReason,
    required this.payments,
  });

  factory Contribution.fromJson(Map<String, dynamic> json) {
    return Contribution(
      id: json['id'] as int,
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      semester: json['semester'] as int? ?? 0,
      semesterName: json['semester_name'] as String? ?? '',
      isActiveSemester: json['is_active_semester'] as bool? ?? false,
      amount: '${json['amount'] ?? '0.00'}',
      dueDate: json['due_date'] != null
          ? DateTime.tryParse(json['due_date'] as String)
          : null,
      owed: '${json['owed'] ?? '0.00'}',
      paid: '${json['paid'] ?? '0.00'}',
      balance: '${json['balance'] ?? '0.00'}',
      status: json['status'] as String? ?? 'UNPAID',
      statusDisplay: json['status_display'] as String? ?? '',
      exempt: json['exempt'] as bool? ?? false,
      exemptionReason: json['exemption_reason'] as String? ?? '',
      payments: (json['payments'] as List<dynamic>? ?? [])
          .map((e) => ContributionPayment.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
