import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:ite_attendance/screens/signup_screen.dart';
import 'package:ite_attendance/services/api_service.dart';
import 'package:ite_attendance/theme/app_theme.dart';
import 'package:provider/provider.dart';

import 'test_helpers.dart';

http.Response json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

const detail = 'Registration received. The Department Adviser must approve '
    'your account before you can sign in.';

/// A valid 1x1 PNG (so the avatar preview can decode it).
final tinyPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

class FakePicker extends ImagePicker {
  final Uint8List bytes;
  FakePicker(this.bytes);

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async =>
      XFile.fromData(bytes, name: 'p.png');
}

/// Pumps a launcher whose button opens the sign-up screen; the result of
/// the screen (the username) is written to [popped].
Future<void> pumpSignUp(
  WidgetTester tester,
  MockClientHandler handler, {
  ImagePicker? picker,
  List<String?>? popped,
}) async {
  tester.view.physicalSize = const Size(900, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    Provider<ApiService>.value(
      value: ApiService(tokens: FakeTokens(), client: MockClient(handler)),
      child: MaterialApp(
        theme: AppTheme.light,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  final r = await Navigator.of(context).push<String>(
                    MaterialPageRoute(
                        builder: (_) => SignUpScreen(picker: picker)),
                  );
                  popped?.add(r);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Finder field(String label) => find.widgetWithText(TextFormField, label);

Future<void> fillForm(
  WidgetTester tester, {
  String username = '  ana.reyes ',
  String password = 'S3cure-pass!',
  String confirm = 'S3cure-pass!',
}) async {
  await tester.enterText(field('Student number'), ' 2024-0100 ');
  await tester.enterText(field('First name'), ' Ana ');
  await tester.enterText(field('Last name'), 'Reyes');
  await tester.enterText(field('Username'), username);
  await tester.enterText(field('Password'), password);
  await tester.enterText(field('Confirm password'), confirm);
  await tester.tap(find.byType(DropdownButtonFormField<String>));
  await tester.pumpAndSettle();
  await tester.tap(find.text('3rd Year').last);
  await tester.pumpAndSettle();
}

Future<void> submit(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('empty form shows the required-field errors and sends nothing',
      (tester) async {
    var calls = 0;
    await pumpSignUp(tester, (req) async {
      calls++;
      return json({}, 201);
    });

    await submit(tester);

    expect(find.text('Enter your student number'), findsOneWidget);
    expect(find.text('Enter your first name'), findsOneWidget);
    expect(find.text('Enter your last name'), findsOneWidget);
    expect(find.text('Choose your year level'), findsOneWidget);
    expect(find.text('Choose a username'), findsOneWidget);
    expect(find.text('Choose a password'), findsOneWidget);
    expect(calls, 0);
  });

  testWidgets('username with spaces, short/numeric password and mismatch',
      (tester) async {
    await pumpSignUp(tester, (req) async => json({}, 201));

    await fillForm(tester,
        username: 'ana reyes', password: '12345678', confirm: '123456789');
    await submit(tester);

    expect(find.text('No spaces in a username'), findsOneWidget);
    expect(find.textContaining('numbers alone'), findsOneWidget);
    expect(find.text('Passwords do not match'), findsOneWidget);
  });

  testWidgets('password visibility toggles reveal the text', (tester) async {
    await pumpSignUp(tester, (req) async => json({}, 201));

    EditableText editable(String label) => tester.widget<EditableText>(
        find.descendant(
            of: field(label), matching: find.byType(EditableText)));
    expect(editable('Password').obscureText, isTrue);
    expect(editable('Confirm password').obscureText, isTrue);

    await tester.tap(find.byTooltip('Show password').first);
    await tester.pump();
    expect(editable('Password').obscureText, isFalse);
    expect(editable('Confirm password').obscureText, isTrue);
  });

  testWidgets('success: sends trimmed JSON (no auth) and shows the '
      'confirmation; Back to sign in returns the username', (tester) async {
    late http.Request seen;
    final popped = <String?>[];
    await pumpSignUp(tester, (req) async {
      seen = req;
      return json({'status': 'PENDING', 'detail': detail}, 201);
    }, popped: popped);

    await fillForm(tester);
    await submit(tester);

    expect(seen.url.path, endsWith('/auth/register/'));
    expect(seen.headers.containsKey('Authorization'), isFalse);
    expect(seen.headers['content-type'], startsWith('application/json'));
    expect(jsonDecode(seen.body), {
      'student_number': '2024-0100',
      'first_name': 'Ana',
      'last_name': 'Reyes',
      'username': 'ana.reyes',
      'password': 'S3cure-pass!',
      'year_level': '3',
    });

    expect(find.text('Registration submitted'), findsOneWidget);
    expect(find.text(detail), findsOneWidget);
    expect(find.text('What happens next'), findsOneWidget);
    expect(find.textContaining('Department Adviser reviews'), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing); // form is gone

    await tester.tap(find.text('Back to sign in'));
    await tester.pumpAndSettle();
    expect(find.byType(SignUpScreen), findsNothing);
    expect(popped, ['ana.reyes']);
  });

  testWidgets('400 field errors land under the right inputs; unknown keys go '
      'to the banner; editing a field clears its error', (tester) async {
    await pumpSignUp(tester, (req) async => json({
          'student_number': [
            'A student with that number is already registered.'
          ],
          'username': ['A user with that username already exists.'],
          'password': ['This password is too common.', 'Too short.'],
          'year_level': ['"9" is not a valid choice.'],
          'surprise': ['Something unexpected.'],
        }, 400));

    await fillForm(tester);
    await submit(tester);

    expect(find.text('A student with that number is already registered.'),
        findsOneWidget);
    expect(find.text('A user with that username already exists.'),
        findsOneWidget);
    expect(find.text('This password is too common. Too short.'),
        findsOneWidget);
    expect(find.text('"9" is not a valid choice.'), findsOneWidget);
    expect(find.text('Something unexpected.'), findsOneWidget); // banner
    expect(find.text('Registration submitted'), findsNothing);

    await tester.enterText(field('Username'), 'ana.reyes2');
    await tester.pumpAndSettle();
    expect(find.text('A user with that username already exists.'),
        findsNothing);
    expect(find.text('A student with that number is already registered.'),
        findsOneWidget); // untouched field keeps its error
  });

  testWidgets('known field errors only: banner asks to fix the fields',
      (tester) async {
    await pumpSignUp(tester, (req) async => json({
          'username': ['A user with that username already exists.'],
        }, 400));
    await fillForm(tester);
    await submit(tester);
    expect(find.text('Please fix the highlighted fields and try again.'),
        findsOneWidget);
  });

  testWidgets('429 shows a retry-able banner; Try again resubmits',
      (tester) async {
    var calls = 0;
    await pumpSignUp(tester, (req) async {
      calls++;
      if (calls == 1) {
        return json({'detail': 'Request was throttled.'}, 429);
      }
      return json({'status': 'PENDING', 'detail': detail}, 201);
    });

    await fillForm(tester);
    await submit(tester);

    expect(find.text('Too many attempts, try again later.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('Registration submitted'), findsOneWidget);
  });

  testWidgets('network failure shows a retry-able banner', (tester) async {
    await pumpSignUp(tester, (req) async {
      throw http.ClientException('no route to host');
    });
    await fillForm(tester);
    await submit(tester);

    expect(find.textContaining('Could not reach the server'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    // The form (and what was typed) is still there.
    expect(find.text('Registration submitted'), findsNothing);
    expect(tester.widget<TextFormField>(field('First name')).controller!.text,
        ' Ana ');
  });

  testWidgets('with a photo the request is multipart; photo can be removed',
      (tester) async {
    late http.Request seen;
    await pumpSignUp(tester, (req) async {
      seen = req;
      return json({'detail': detail}, 201);
    }, picker: FakePicker(Uint8List.fromList(tinyPng)));

    expect(find.text('Remove photo'), findsNothing);
    await tester.tap(find.text('Add photo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose from gallery'));
    await tester.pumpAndSettle();
    expect(find.text('Remove photo'), findsOneWidget);
    expect(find.text('Change photo'), findsOneWidget);

    await fillForm(tester);
    await submit(tester);

    final body = latin1.decode(seen.bodyBytes);
    expect(seen.headers['content-type'], startsWith('multipart/form-data'));
    expect(seen.headers.containsKey('Authorization'), isFalse);
    expect(body, contains('name="profile_image"'));
    expect(body, contains('filename="profile.png"'));
    expect(find.text('Registration submitted'), findsOneWidget);
  });

  testWidgets('removing the photo goes back to JSON', (tester) async {
    late http.Request seen;
    await pumpSignUp(tester, (req) async {
      seen = req;
      return json({'detail': detail}, 201);
    }, picker: FakePicker(Uint8List.fromList(tinyPng)));

    await tester.tap(find.text('Add photo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose from gallery'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove photo'));
    await tester.pumpAndSettle();
    expect(find.text('Add photo'), findsOneWidget);

    await fillForm(tester);
    await submit(tester);
    expect(seen.headers['content-type'], startsWith('application/json'));
  });

  testWidgets('an unsupported image type is rejected before upload',
      (tester) async {
    await pumpSignUp(tester, (req) async => json({}, 201),
        picker: FakePicker(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9])));

    await tester.tap(find.text('Add photo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose from gallery'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Unsupported image'), findsOneWidget);
    expect(find.text('Remove photo'), findsNothing);
  });

  testWidgets('a server photo error is shown by the photo', (tester) async {
    await pumpSignUp(tester, (req) async => json({
          'profile_image': ['Upload a valid image.'],
        }, 400), picker: FakePicker(Uint8List.fromList(tinyPng)));

    await tester.tap(find.text('Add photo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose from gallery'));
    await tester.pumpAndSettle();
    await fillForm(tester);
    await submit(tester);

    expect(find.text('Upload a valid image.'), findsOneWidget);
  });
}
