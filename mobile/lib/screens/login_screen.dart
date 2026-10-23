import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../providers/inspection_provider.dart';
import '../providers/company_provider.dart';
import '../services/persistence_service.dart';
import 'app_home_screen.dart';
import 'forgot_password_screen.dart';
import 'supervisor_info_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Header Logo / Emblem
                Container(
                  width: 104,
                  height: 104,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
                        blurRadius: 20,
                        spreadRadius: 3,
                        offset: const Offset(0, 4),
                      ),
                      BoxShadow(
                        color: Colors.blue.withValues(alpha: 0.12),
                        blurRadius: 24,
                        spreadRadius: 4,
                      ),
                    ],
                  ),
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
                const SizedBox(height: 24),
                const Text(
                  'VOICE INSPECTION',
                  style: TextStyle(
                    color: Color(0xFF0F172A),
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 32),

                // Form Container
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 15,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Authentication',
                        style: TextStyle(
                          color: Color(0xFF0F172A),
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Username field
                      TextField(
                        controller: _usernameController,
                        style: const TextStyle(color: Color(0xFF0F172A)),
                        decoration: InputDecoration(
                          labelText: 'Employee ID / Username',
                          labelStyle: const TextStyle(color: Color(0xFF64748B)),
                          prefixIcon: const Icon(
                            Icons.person_outline,
                            color: Color(0xFF2563EB),
                          ),
                          filled: true,
                          fillColor: const Color(0xFFF1F5F9),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Password field
                      TextField(
                        controller: _passwordController,
                        obscureText: _obscurePassword,
                        style: const TextStyle(color: Color(0xFF0F172A)),
                        decoration: InputDecoration(
                          labelText: 'Password',
                          labelStyle: const TextStyle(color: Color(0xFF64748B)),
                          prefixIcon: const Icon(
                            Icons.lock_outline,
                            color: Color(0xFF2563EB),
                          ),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                              color: const Color(0xFF64748B),
                            ),
                            onPressed: () {
                              setState(() {
                                _obscurePassword = !_obscurePassword;
                              });
                            },
                          ),
                          filled: true,
                          fillColor: const Color(0xFFF1F5F9),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: auth.isLoading
                              ? null
                              : () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => const ForgotPasswordScreen(),
                                    ),
                                  );
                                },
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF2563EB),
                            padding: const EdgeInsets.symmetric(vertical: 4),
                          ),
                          child: const Text('Forgot Password?'),
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Login Button
                      ElevatedButton(
                        onPressed: auth.isLoading
                            ? null
                            : () async {
                                final username = _usernameController.text
                                    .trim();
                                final password = _passwordController.text
                                    .trim();

                                if (username.isEmpty || password.isEmpty) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Please enter username and password',
                                      ),
                                    ),
                                  );
                                  return;
                                }

                                final success = await auth.login(
                                  username,
                                  password,
                                );

                                if (context.mounted) {
                                  if (success) {
                                    if (!auth.isMobileRole) {
                                      final role =
                                          auth.userRole ?? 'dashboard-only';
                                      await auth.logout();
                                      if (!context.mounted) return;
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            'This account ($role) is for dashboard use only. '
                                            'Use an operator or inspector account on mobile.',
                                          ),
                                          backgroundColor:
                                              Colors.orange.shade800,
                                        ),
                                      );
                                      return;
                                    }

                                    // Refresh company schedule details (shifts, factory info)
                                    Provider.of<CompanyProvider>(
                                      context,
                                      listen: false,
                                    ).fetchCompanyDetails();
                                    Widget targetScreen = const AppHomeScreen();
                                    if (auth.userId != null) {
                                      final provider =
                                          Provider.of<InspectionProvider>(
                                            context,
                                            listen: false,
                                          );
                                      provider.currentUserId = auth.userId!;

                                      // Do not interrupt login with a resume
                                      // prompt; discard any stale local session.
                                      await PersistenceService.clearState();
                                    }

                                    if (!context.mounted) return;
                                    Navigator.pushReplacement(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => targetScreen,
                                      ),
                                    );
                                  } else {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          auth.lastErrorMessage ??
                                              'Login failed. Please check credentials.',
                                        ),
                                        backgroundColor: Colors.redAccent,
                                      ),
                                    );
                                  }
                                }
                              },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2563EB),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: auth.isLoading
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text(
                                'LOGIN TO CONSOLE',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

}
