import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'models/user.dart';
import 'screens/instructor/instructor_home.dart';
import 'screens/login_screen.dart';
import 'screens/student/student_home.dart';
import 'services/api_service.dart';
import 'services/auth_provider.dart';
import 'theme/app_theme.dart';
import 'widgets/logout_action.dart';
import 'widgets/state_message.dart';

void main() {
  runApp(const IteAttendanceApp());
}

class IteAttendanceApp extends StatelessWidget {
  const IteAttendanceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()..bootstrap()),
        // Expose the authenticated HTTP client to screens.
        ProxyProvider<AuthProvider, ApiService>(
          update: (_, auth, _) => auth.api,
        ),
      ],
      child: MaterialApp(
        title: 'ITE Attendance',
        debugShowCheckedModeBanner: false,
        // Always the light + green look, even when the phone is in dark mode.
        theme: AppTheme.light,
        themeMode: AppTheme.themeMode,
        home: const RootRouter(),
      ),
    );
  }
}

/// Routes by auth state, then by role once authenticated.
class RootRouter extends StatelessWidget {
  const RootRouter({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    switch (auth.status) {
      case AuthStatus.unknown:
        return const _SplashScreen();
      case AuthStatus.unauthenticated:
        return const LoginScreen();
      case AuthStatus.authenticated:
        return _homeForRole(auth.user!);
    }
  }

  Widget _homeForRole(User user) {
    if (user.isInstructor) return const InstructorHome();
    if (user.isStudent) return const StudentHome();
    return const _UnsupportedRoleScreen();
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppTheme.green,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.qr_code_2, size: 72, color: AppTheme.onGreen),
            SizedBox(height: 20),
            CircularProgressIndicator(color: AppTheme.onGreen),
          ],
        ),
      ),
    );
  }
}

/// Shown when a logged-in account is neither instructor nor student
/// (e.g. an admin — they use the web portal, not this app).
class _UnsupportedRoleScreen extends StatelessWidget {
  const _UnsupportedRoleScreen();

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().user;
    return Scaffold(
      appBar: AppBar(
        title: const Text('ITE Attendance'),
        actions: const [LogoutAction()],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const StateMessage(
                icon: Icons.info_outline,
                title: 'This app is for instructors and students',
                subtitle: 'Department Advisers use the web portal.',
              ),
              Text('Signed in as ${user?.fullName ?? ''}',
                  style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
      ),
    );
  }
}
