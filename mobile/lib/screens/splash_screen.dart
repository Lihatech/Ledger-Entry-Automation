import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../providers/inspection_provider.dart';
import '../providers/company_provider.dart';
import '../services/persistence_service.dart';
import 'login_screen.dart';
import 'app_home_screen.dart';
import 'operator_home_screen.dart';
import 'messaging/messages_screen.dart';

/// SplashScreen — shown at app startup.
///
/// Responsibilities (in order):
///   1. Show MMPL branding briefly while checking auth.
///   2. Try to validate existing JWT token (attempt silent refresh if needed).
///   3. If valid → route to correct home screen (Operator / Inspector / Supervisor).
///   4. If invalid → route to LoginScreen.
///
/// This screen does NOT change any business logic. It only reads the auth
/// state that AuthProvider.checkLoginStatus() already manages.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _pulseAnim = Tween<double>(
      begin: 0.85,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    // Defer navigation until after first frame so providers are ready.
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkAndRoute());
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  Future<void> _checkAndRoute() async {
    // Refresh latest company metadata on startup so splash screen has live data
    Provider.of<CompanyProvider>(context, listen: false).fetchCompanyDetails();

    // Give the splash a minimum display time so it doesn't flash.
    await Future.delayed(const Duration(milliseconds: 1400));

    if (!mounted) return;

    final auth = Provider.of<AuthProvider>(context, listen: false);

    // AuthProvider constructor already called checkLoginStatus().
    // Wait up to 30 seconds for it to complete (increased from 10s to handle
    // cold-start backend delays without falsely forcing re-login).
    int retries = 0;
    while (auth.isLoading && retries < 300) {
      await Future.delayed(const Duration(milliseconds: 100));
      retries++;
    }

    if (!mounted) return;

    if (auth.isAuthenticated) {
      // Only operator and inspector accounts are approved for the mobile app.
      // Do not fall through to the supervisor-style home for dashboard roles.
      if (!auth.isMobileRole) {
        await auth.logout();
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const LoginScreen()),
        );
        return;
      }

      // Fetch company details now that we have valid tokens.
      Provider.of<CompanyProvider>(
        context,
        listen: false,
      ).fetchCompanyDetails();

      Widget home = const AppHomeScreen();

      // Restore saved inspection state for both operators AND inspectors.
      // Supervisors are excluded — they don't use the inspection flow.
      if ((auth.isOperator || auth.isInspector) && auth.userId != null) {
        final provider = Provider.of<InspectionProvider>(
          context,
          listen: false,
        );
        provider.currentUserId = auth.userId!; // Set so future saves work

        // Start clean on every app launch. Previously this displayed a
        // blocking “Resume Session?” dialog for locally cached inspections.
        await PersistenceService.clearState();
      }

      // Preserve a browser deep link after authentication. Flutter web keeps
      // the hash in the URL, but the splash flow must explicitly honor it
      // because it replaces the startup route after auth is restored.
      final startupUri = Uri.parse(Uri.base.fragment);
      if (startupUri.path == '/messages') {
        home = MessagesScreen(
          initialConversationId: startupUri.queryParameters['conversation'],
        );
      }

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => home),
      );
    } else {
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080C18),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Animated MMPL Logo
            ScaleTransition(
              scale: _pulseAnim,
              child: Container(
                width: 110,
                height: 110,
                decoration: BoxDecoration(
                  color: const Color(0xFF0D1424),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF2563EB), width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF2563EB).withValues(alpha: 0.35),
                      blurRadius: 30,
                      spreadRadius: 6,
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.all(18.0),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Consumer<CompanyProvider>(
                      builder: (context, company, child) {
                        final customLogo = company.logoUrl.trim();
                        if (customLogo.isNotEmpty) {
                          return Image.network(
                            customLogo,
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stackTrace) =>
                                Image.network(
                                  'apple-touch-icon.png',
                                  fit: BoxFit.contain,
                                  errorBuilder: (context, error, stackTrace) =>
                                      Image.asset(
                                        'assets/images/app_logo.png',
                                        fit: BoxFit.contain,
                                      ),
                                ),
                          );
                        }
                        return kIsWeb
                            ? Image.network(
                                'apple-touch-icon.png',
                                fit: BoxFit.contain,
                                errorBuilder: (context, error, stackTrace) =>
                                    Image.asset(
                                      'assets/images/app_logo.png',
                                      fit: BoxFit.contain,
                                    ),
                              )
                            : Image.asset(
                                'assets/images/app_logo.png',
                                fit: BoxFit.contain,
                                errorBuilder: (context, error, stackTrace) =>
                                    Image.network(
                                      'apple-touch-icon.png',
                                      fit: BoxFit.contain,
                                    ),
                              );
                      },
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 28),
            Consumer<CompanyProvider>(
              builder: (context, company, child) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0),
                  child: Text(
                    company.companyName.toUpperCase(),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 2.0,
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 6),
            const Text(
              'Voice Inspection System',
              style: TextStyle(
                color: Color(0xFF64748B),
                fontSize: 14,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 48),
            // Loading indicator
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: const Color(0xFF2563EB).withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Checking session…',
              style: TextStyle(color: Color(0xFF475569), fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
