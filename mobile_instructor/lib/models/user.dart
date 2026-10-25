/// Authenticated user identity (from `GET /api/me/`).
class User {
  final int id;
  final String username;
  final String fullName;
  final bool isAdmin;
  final bool isInstructor;
  final bool isStudent;
  final String role;
  final String? profileImage; // 256px photo URL, if set

  /// Changes whenever the password changes (from `/api/me/`, when the server
  /// provides it): a stored offline sign-in with another value is stale.
  final String? passwordVersion;

  const User({
    required this.id,
    required this.username,
    required this.fullName,
    required this.isAdmin,
    required this.isInstructor,
    required this.isStudent,
    required this.role,
    this.profileImage,
    this.passwordVersion,
  });

  /// The `/api/me/` shape, so the user can be cached for offline start-up.
  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'full_name': fullName,
        'is_admin': isAdmin,
        'is_instructor': isInstructor,
        'is_student': isStudent,
        'role': role,
        'profile_image': profileImage,
        'password_version': passwordVersion,
      };

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] as int,
      username: json['username'] as String? ?? '',
      fullName: (json['full_name'] as String?)?.trim().isNotEmpty == true
          ? json['full_name'] as String
          : json['username'] as String? ?? '',
      isAdmin: json['is_admin'] as bool? ?? false,
      isInstructor: json['is_instructor'] as bool? ?? false,
      isStudent: json['is_student'] as bool? ?? false,
      role: json['role'] as String? ?? 'user',
      profileImage: json['profile_image'] as String?,
      passwordVersion: json['password_version'] as String?,
    );
  }
}
