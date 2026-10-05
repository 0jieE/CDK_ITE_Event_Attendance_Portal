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

  /// Copy with edited identity fields. Pass [clearPhoto] to drop the photo
  /// (a plain `profileImage: null` means "keep the current one").
  User copyWith({
    String? username,
    String? fullName,
    String? email,
    String? profileImage,
    bool clearPhoto = false,
  }) {
    return User(
      id: id,
      username: username ?? this.username,
      fullName: fullName ?? this.fullName,
      email: email ?? this.email,
      isAdmin: isAdmin,
      isInstructor: isInstructor,
      isStudent: isStudent,
      role: role,
      profileImage: clearPhoto ? null : (profileImage ?? this.profileImage),
    );
  }

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
