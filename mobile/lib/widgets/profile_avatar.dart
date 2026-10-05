import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Round profile photo with a graceful fallback: the person's initial is always
/// drawn underneath, and the network image fades in over it when it loads (so a
/// missing photo or a failed download never leaves a broken-image icon).
class ProfileAvatar extends StatelessWidget {
  final String? imageUrl;
  final String name;
  final double radius;

  const ProfileAvatar({
    super.key,
    required this.imageUrl,
    required this.name,
    this.radius = 28,
  });

  @override
  Widget build(BuildContext context) {
    final url = imageUrl;
    return CircleAvatar(
      radius: radius,
      backgroundColor: const Color(0xFFE6F4E1),
      foregroundImage: (url != null && url.isNotEmpty) ? NetworkImage(url) : null,
      onForegroundImageError: (url != null && url.isNotEmpty) ? (_, _) {} : null,
      child: Text(
        name.trim().isNotEmpty ? name.trim()[0].toUpperCase() : '?',
        style: TextStyle(
          color: AppTheme.violet,
          fontSize: radius * 0.85,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
