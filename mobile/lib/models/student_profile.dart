/// Student's own profile (from `GET /api/student/profile/`).
class StudentProfile {
  final int id;
  final String studentNumber;
  final String fullName;
  final String email;
  final String yearLevel;
  final String yearLevelDisplay;
  final String section;
  final String yearSection;
  final String? profileImage; // 256px photo URL, if set

  const StudentProfile({
    required this.id,
    required this.studentNumber,
    required this.fullName,
    required this.email,
    required this.yearLevel,
    required this.yearLevelDisplay,
    required this.section,
    required this.yearSection,
    this.profileImage,
  });

  factory StudentProfile.fromJson(Map<String, dynamic> json) {
    return StudentProfile(
      id: json['id'] as int,
      studentNumber: json['student_number'] as String? ?? '',
      fullName: json['full_name'] as String? ?? '',
      email: json['email'] as String? ?? '',
      yearLevel: json['year_level'] as String? ?? '',
      yearLevelDisplay: json['year_level_display'] as String? ?? '',
      section: json['section'] as String? ?? '',
      yearSection: json['year_section'] as String? ?? '',
      profileImage: json['profile_image'] as String?,
    );
  }
}
