/// Authenticated user identity (from `GET /api/me/`).
class User {
  final int id;
  final String username;
  final String fullName;
  final String email;
  final bool isAdmin;
  final bool isInstructor;
  final bool isStudent;
  final String role;
  final String? profileImage; // 256px photo URL, if set

  const User({
    required this.id,
    required this.username,
    required this.fullName,
    required this.email,
    required this.isAdmin,
    required this.isInstructor,
    required this.isStudent,
    required this.role,
    this.profileImage,
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] as int,
      username: json['username'] as String? ?? '',
      fullName: (json['full_name'] as String?)?.trim().isNotEmpty == true
          ? json['full_name'] as String
          : json['username'] as String? ?? '',
      email: json['email'] as String? ?? '',
      isAdmin: json['is_admin'] as bool? ?? false,
      isInstructor: json['is_instructor'] as bool? ?? false,
      isStudent: json['is_student'] as bool? ?? false,
      role: json['role'] as String? ?? 'user',
      profileImage: json['profile_image'] as String?,
    );
  }
}
