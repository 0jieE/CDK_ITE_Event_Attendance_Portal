import 'package:flutter_test/flutter_test.dart';
import 'package:ite_attendance/models/student_profile.dart';
import 'package:ite_attendance/utils/validators.dart';

const profile = StudentProfile(
  id: 1,
  studentNumber: '2023-0001',
  fullName: 'Juan D. Cruz',
  firstName: 'Juan',
  middleName: 'D.',
  lastName: 'Cruz',
  username: 'jcruz',
  yearLevel: '3',
  yearLevelDisplay: '3rd Year',
  section: 'A',
  yearSection: '3A',
);

void main() {
  test('validateRequired trims', () {
    expect(validateRequired('  ', 'username'), 'Enter your username');
    expect(validateRequired(null, 'username'), isNotNull);
    expect(validateRequired(' ok ', 'username'), isNull);
  });

  group('sign-up validators', () {
    test('student number', () {
      expect(validateStudentNumber(' '), 'Enter your student number');
      expect(validateStudentNumber('12'), isNotNull);
      expect(validateStudentNumber(' 2024-0100 '), isNull);
    });

    test('username: required, no spaces, min length', () {
      expect(validateUsername(''), isNotNull);
      expect(validateUsername(null), isNotNull);
      expect(validateUsername('ab'), isNotNull);
      expect(validateUsername('ana reyes'), 'No spaces in a username');
      expect(validateUsername('ana\treyes'), isNotNull);
      expect(validateUsername(' ana.reyes '), isNull);
    });

    test('year level must be one of 1-4', () {
      expect(validateYearLevel(null), isNotNull);
      expect(validateYearLevel(''), isNotNull);
      expect(validateYearLevel('5'), isNotNull);
      for (final y in ['1', '2', '3', '4']) {
        expect(validateYearLevel(y), isNull);
      }
      expect(yearLevels['1'], '1st Year');
      expect(yearLevels['4'], '4th Year');
    });

    test('registration password: length and not all digits', () {
      expect(validateRegistrationPassword(''), isNotNull);
      expect(validateRegistrationPassword('short1'), isNotNull);
      expect(validateRegistrationPassword('12345678'), isNotNull);
      expect(validateRegistrationPassword('abcdefgh'), isNull);
      expect(validateRegistrationPassword('S3cure-pass!'), isNull);
    });
  });

  test('password checks', () {
    expect(validateNewPassword(''), isNotNull);
    expect(validateNewPassword('short1'), isNotNull);
    expect(validateNewPassword('longenough1'), isNull);
    expect(validateConfirm('', 'abc'), isNotNull);
    expect(validateConfirm('abd', 'abc'), 'Passwords do not match');
    expect(validateConfirm('abc', 'abc'), isNull);
  });

  group('changedProfileFields', () {
    Map<String, String> diff({
      String first = 'Juan',
      String middle = 'D.',
      String last = 'Cruz',
      String username = 'jcruz',
    }) =>
        changedProfileFields(profile,
            firstName: first,
            middleName: middle,
            lastName: last,
            username: username);

    test('nothing changed (whitespace ignored)', () {
      expect(diff(), isEmpty);
      expect(diff(first: '  Juan ', username: ' jcruz'), isEmpty);
    });

    test('sends only changed, trimmed fields', () {
      expect(diff(username: ' juan.cruz ', last: 'Santos'),
          {'username': 'juan.cruz', 'last_name': 'Santos'});
    });

    test('clearing the optional middle name is a change to empty', () {
      expect(diff(middle: ''), {'middle_name': ''});
    });
  });

  test('ServerFieldErrors vanish once the value changes', () {
    final e = ServerFieldErrors()..set({'username': 'taken'}, (f) => 'jcruz');
    expect(e.forField('username', 'jcruz'), 'taken');
    expect(e.forField('username', 'jcruz2'), isNull);
    expect(e.forField('first_name', 'jcruz'), isNull);
    e.clear();
    expect(e.forField('username', 'jcruz'), isNull);
  });
}
