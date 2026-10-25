/// Student's own profile (from `GET/PATCH /api/student/profile/`).
///
/// Name and username are editable by the student; student number,
/// year level and section are managed by the adviser (read-only in the app).
class StudentProfile {
  final int id;
  final String studentNumber;
  final String fullName;
  final String firstName;
  final String middleName;
  final String lastName;
  final String username;
  final String yearLevel;
  final String yearLevelDisplay;
  final String section;
  final String yearSection;
  final String? profileImage; // 256px photo URL, if set

  const StudentProfile({
    required this.id,
    required this.studentNumber,
    required this.fullName,
    this.firstName = '',
    this.middleName = '',
    this.lastName = '',
    this.username = '',
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
      firstName: json['first_name'] as String? ?? '',
      middleName: json['middle_name'] as String? ?? '',
      lastName: json['last_name'] as String? ?? '',
      username: json['username'] as String? ?? '',
      yearLevel: json['year_level'] as String? ?? '',
      yearLevelDisplay: json['year_level_display'] as String? ?? '',
      section: json['section'] as String? ?? '',
      yearSection: json['year_section'] as String? ?? '',
      profileImage: json['profile_image'] as String?,
    );
  }

  /// Copy with a new (or removed) photo URL.
  StudentProfile withPhoto(String? url) => StudentProfile(
        id: id,
        studentNumber: studentNumber,
        fullName: fullName,
        firstName: firstName,
        middleName: middleName,
        lastName: lastName,
        username: username,
        yearLevel: yearLevel,
        yearLevelDisplay: yearLevelDisplay,
        section: section,
        yearSection: yearSection,
        profileImage: url,
      );
}
