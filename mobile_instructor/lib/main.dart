import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'models/user.dart';
import 'screens/instructor/instructor_home.dart';
import 'screens/login_screen.dart';
import 'services/api_service.dart';
import 'services/auth_provider.dart';
import 'services/connectivity_service.dart';
import 'services/offline_credentials.dart';
import 'services/offline_prefetch.dart';
import 'services/offline_scan_service.dart';
import 'theme/app_theme.dart';
import 'update/update_service.dart';
import 'update/update_ui.dart';
import 'widgets/logout_action.dart';
import 'widgets/state_message.dart';

void main() {
  runApp(const IteInstructorsApp());
}

class IteInstructorsApp extends StatelessWidget {
  const IteInstructorsApp({super.key});

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
        // Offline scanning queue, switched to whichever instructor signs in.
        ChangeNotifierProxyProvider2<AuthProvider, ConnectivityService,
            OfflineScanService>(
          create: (ctx) => OfflineScanService(
            api: ctx.read<AuthProvider>().api,
            connectivity: ctx.read<ConnectivityService>(),
          ),
          update: (_, auth, _, offline) {
            final user = auth.user;
            final id = user != null && user.isInstructor ? user.id : null;
            // After this build: attach() notifies listeners.
            Future.microtask(() => offline!.attach(id));
            return offline!;
          },
        ),
        // In-app updates from GitHub Releases (see AUTO_UPDATE_SETUP.md).
        ChangeNotifierProvider(create: (_) => UpdateService()),
      ],
      // Downloads the instructor's data for offline use whenever online.
      child: OfflinePrefetcher(
        // Checks GitHub for a newer release after start-up and on resume.
        child: UpdateChecker(
          child: MaterialApp(
            title: 'ITE Instructors',
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

/// Routes by auth state, then by role once authenticated: instructors only.
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

  Widget _homeForRole(User user) =>
      user.isInstructor ? const InstructorHome() : const _UnsupportedRoleScreen();
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

/// Shown when a logged-in account isn't an instructor: students have their
/// own app (ITE Students) and Department Advisers use the web portal.
class _UnsupportedRoleScreen extends StatelessWidget {
  const _UnsupportedRoleScreen();

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().user;
    return Scaffold(
      appBar: AppBar(
        title: const Text('ITE Instructors'),
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
                title: 'This app is for instructors',
                subtitle: 'Students use the ITE Students app. '
                    'Department Advisers use the web portal.',
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
