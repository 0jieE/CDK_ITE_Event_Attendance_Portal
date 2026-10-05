import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Soft pill badge for a status: Present = green tint, Late = amber tint,
/// Absent = red tint (PAID/UNPAID follow green/red).
class StatusChip extends StatelessWidget {
  final String status;
  final String? label;
  const StatusChip(this.status, {super.key, this.label});

  @override
  Widget build(BuildContext context) {
    final c = context.brand.badge(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label ?? titleCase(status),
        style: TextStyle(
          color: c.fg,
          fontWeight: FontWeight.w700,
          fontSize: 12,
          height: 1.2,
        ),
      ),
    );
  }

  static String titleCase(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).toLowerCase();
}
