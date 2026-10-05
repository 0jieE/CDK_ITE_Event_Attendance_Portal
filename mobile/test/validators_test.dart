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
  email: 'juan@example.com',
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

  test('validateEmail', () {
    expect(validateEmail(''), isNotNull);
    expect(validateEmail('nope'), isNotNull);
    expect(validateEmail('a@b'), isNotNull);
    expect(validateEmail('a b@c.com'), isNotNull);
    expect(validateEmail(' juan@example.com '), isNull);
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
      String email = 'juan@example.com',
      String username = 'jcruz',
    }) =>
        changedProfileFields(profile,
            firstName: first,
            middleName: middle,
            lastName: last,
            email: email,
            username: username);

    test('nothing changed (whitespace ignored)', () {
      expect(diff(), isEmpty);
      expect(diff(first: '  Juan ', email: ' juan@example.com'), isEmpty);
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
    expect(e.forField('email', 'jcruz'), isNull);
    e.clear();
    expect(e.forField('username', 'jcruz'), isNull);
  });
}
