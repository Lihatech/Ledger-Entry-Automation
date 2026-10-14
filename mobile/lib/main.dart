import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'providers/auth_provider.dart';
import 'providers/inspection_provider.dart';
import 'providers/task_provider.dart';
import 'providers/company_provider.dart';
import 'providers/messaging_provider.dart';
import 'providers/notification_provider.dart';
import 'screens/splash_screen.dart';
import 'screens/messaging/messages_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final sentryDsn = const String.fromEnvironment('SENTRY_DSN');
  await SentryFlutter.init(
    (options) {
      if (sentryDsn.isNotEmpty) {
        options.dsn = sentryDsn;
      }
      options.environment = const String.fromEnvironment('APP_ENV', defaultValue: 'production');
      options.tracesSampleRate = 0.1;
    },
    appRunner: () => runApp(const VoiceInspectionApp()),
  );
}

class VoiceInspectionApp extends StatelessWidget {
  const VoiceInspectionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => InspectionProvider()),
        ChangeNotifierProvider(create: (_) => TaskProvider()),
        ChangeNotifierProvider(create: (_) => CompanyProvider()),
        ChangeNotifierProvider(create: (_) => MessagingProvider()),
        ChangeNotifierProxyProvider<AuthProvider, NotificationProvider>(
          create: (_) => NotificationProvider(),
          update: (_, auth, notifications) {
            final provider = notifications ?? NotificationProvider();
            if (auth.isAuthenticated) {
              provider.initializeForUser(userId: auth.userId);
            } else if (!auth.isLoading) {
              provider.resetForLogout();
            }
            return provider;
          },
        ),
      ],
      child: _AppLifecycleHandler(
        child: MaterialApp(
          title: 'Inspection Hub',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: Brightness.light,
            scaffoldBackgroundColor: Colors.grey[50],
            primaryColor: Colors.blueAccent,
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.blueAccent,
              brightness: Brightness.light,
              surface: Colors.white,
            ),
            textTheme: GoogleFonts.interTextTheme(ThemeData.light().textTheme),
            useMaterial3: true,
          ),
          routes: {
            '/messages': (context) {
              final auth = context.read<AuthProvider>();
              if (auth.isLoading ||
                  !auth.isAuthenticated ||
                  !auth.isMobileRole) {
                return const SplashScreen();
              }
              return MessagesScreen(
                initialConversationId:
                    ModalRoute.of(context)?.settings.arguments as String?,
              );
            },
          },
          home: const SplashScreen(),
        ),
      ),
    );
  }
}

class _AppLifecycleHandler extends StatefulWidget {
  const _AppLifecycleHandler({required this.child});

  final Widget child;

  @override
  State<_AppLifecycleHandler> createState() => _AppLifecycleHandlerState();
}

class _AppLifecycleHandlerState extends State<_AppLifecycleHandler>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      context.read<CompanyProvider>().fetchCompanyDetails();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
