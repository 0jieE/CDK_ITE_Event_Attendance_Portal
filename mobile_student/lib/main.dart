import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/login_screen.dart';
import 'screens/student/student_home.dart';
import 'services/api_service.dart';
import 'services/auth_provider.dart';
import 'services/connectivity_service.dart';
import 'services/offline_credentials.dart';
import 'services/offline_prefetch.dart';
import 'theme/app_theme.dart';
import 'update/update_service.dart';
import 'update/update_ui.dart';

void main() {
  runApp(const IteStudentsApp());
}

/// "ITE Students": the student app (QR, history, fines, profile).
/// Instructors scan with the separate "ITE Instructors" app; advisers use the
/// web portal.
class IteStudentsApp extends StatelessWidget {
  const IteStudentsApp({super.key});

  static const notAllowedMessage =
      'This app is for students. Instructors use the ITE Instructors app; '
      'advisers use the web portal.';

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ConnectivityService()),
        ChangeNotifierProvider(
          create: (ctx) {
            final connectivity = ctx.read<ConnectivityService>();
            final auth = AuthProvider(
              // Sign in offline with an account used online on this phone.
              offlineLogin: OfflineCredentials(),
              connectivity: connectivity,
              allowedUser: (u) => u.isStudent,
              notAllowedMessage: notAllowedMessage,
            );
            // Requests report reachability; known offline, screens read the
            // saved copies without trying the network.
            auth.api
              ..onReachable = connectivity.reportReachable
              ..onUnreachable = connectivity.reportUnreachable
              ..isKnownOffline = (() => !connectivity.isOnline);
            connectivity.probe = auth.api.ping;
            return auth..bootstrap();
          },
        ),
        // Expose the authenticated HTTP client to screens.
        ProxyProvider<AuthProvider, ApiService>(
          update: (_, auth, _) => auth.api,
        ),
        // In-app updates from GitHub Releases (see AUTO_UPDATE_SETUP.md).
        ChangeNotifierProvider(create: (_) => UpdateService()),
      ],
      // Downloads the student's data for offline use whenever online.
      child: OfflinePrefetcher(
        // Checks GitHub for a newer release after start-up and on resume.
        child: UpdateChecker(
          child: MaterialApp(
            title: 'ITE Students',
            debugShowCheckedModeBanner: false,
            // Always the light + green look, even when the phone is in dark mode.
            theme: AppTheme.light,
            themeMode: AppTheme.themeMode,
            home: const RootRouter(),
          ),
        ),
      ),
    );
  }
}

/// Routes by auth state. Only students get past sign-in (see
/// [AuthProvider.allowedUser]).
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
        return const StudentHome();
    }
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
            CircleAvatar(
              radius: 64,
              backgroundColor: Colors.white,
              child: Padding(
                padding: EdgeInsets.all(4),
                child: Image(image: AssetImage('assets/icon/ite_logo.png')),
              ),
            ),
            SizedBox(height: 20),
            CircularProgressIndicator(color: AppTheme.onGreen),
          ],
        ),
      ),
    );
  }
}
