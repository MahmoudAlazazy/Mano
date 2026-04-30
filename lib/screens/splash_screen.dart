import 'package:flutter/material.dart';
import 'package:mano/providers/supabase_provider.dart';
import '../theme/app_theme.dart';
import 'package:provider/provider.dart';
import '../main.dart' show AppRoutes;
import '../services/supabase_service.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeAnim;
  late final Animation<double> _scaleAnim;

  bool _redirected = false;

  @override
  void initState() {
    super.initState();

    Future.microtask(() {
      context.read<AuthProvider>().initializeAuthState();
    });

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );

    _fadeAnim = CurvedAnimation(parent: _controller, curve: Curves.easeOut);

    _scaleAnim = Tween<double>(
      begin: 0.85,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));

    Future.delayed(const Duration(milliseconds: 250), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onGetStarted() {
    Navigator.pushReplacementNamed(context, AppRoutes.login);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, authProvider, child) {
        if (authProvider.isInitialized && !_redirected) {
          _redirected = true; // Prevent multiple redirects
          // Navigate based on auth state after a delay
          Future.delayed(const Duration(milliseconds: 1500), () async {
            if (!mounted) return;
            final hasSession = SupabaseService().getSession() != null;
            if (authProvider.isAuthenticated && hasSession) {
              final userId =
                  authProvider.user?.id ?? SupabaseService().currentUserId;
              if (userId != null) {
                await context.read<ProfileProvider>().loadProfile(userId);
              }
              Navigator.pushReplacementNamed(context, AppRoutes.home);
            } else {
              Navigator.pushReplacementNamed(context, AppRoutes.login);
            }
          });
        }

        final size = MediaQuery.of(context).size;

        return Scaffold(
          backgroundColor: AppColors.background, // warm beige
          body: Stack(
            children: [
              // ── Main centered content ────────────────────────────
              SafeArea(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // ── Logo emblem ────────────────────────────
                        FadeTransition(
                          opacity: _fadeAnim,
                          child: ScaleTransition(
                            scale: _scaleAnim,
                            child: Image.asset(
                              'assets/images/logo.png',
                              width: size.width * 0.55,
                              height: size.width * 0.55,
                              fit: BoxFit.contain,
                            ),
                          ),
                        ),

                        const SizedBox(height: 24),

                        // ── App title ──────────────────────────────
                        FadeTransition(
                          opacity: _fadeAnim,
                          child: Text(
                            'OUTFIT ADVISOR',
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                              color: AppColors.primary,
                              letterSpacing: 3.5,
                              fontStyle: FontStyle.italic,
                              height: 1.2,
                            ),
                          ),
                        ),

                        const SizedBox(height: 10),

                        // ── Subtitle ───────────────────────────────
                        FadeTransition(
                          opacity: _fadeAnim,
                          child: Text(
                            'Your Smart personal stylist',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: const Color(0xFF7A6B55),
                              letterSpacing: 2.8,
                              height: 1.4,
                            ),
                          ),
                        ),

                        const SizedBox(height: 48),

                        // ── GET STARTED pill button ────────────────
                        // This button is now effectively replaced by the auto-redirect logic
                        // but we can keep it for the visual effect or as a fallback.
                        // For a pure splash screen, this can be removed.
                        FadeTransition(
                          opacity: _fadeAnim,
                          child: authProvider.isAuthenticated
                              ? const SizedBox(height: 74) // Match button height to avoid layout jump
                              : _GradientPillButton(
                                  label: 'GET STARTED',
                                  onPressed: _onGetStarted,
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // ── Decorative golden leaves (bottom-right) ──────────
              Positioned(
                bottom: -15,
                right: -25,
                child: FadeTransition(
                  opacity: _fadeAnim,
                  child: Image.asset(
                    'assets/images/leaf_decoration.png',
                    width: size.width * 0.28,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// Gradient pill button — deep brown gradient, gold text, soft shadow
// ─────────────────────────────────────────────────────────────────
class _GradientPillButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  const _GradientPillButton({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(40), // pill shape
        gradient: const LinearGradient(
          colors: [
            Color(0xFF6B2D2D), // deep burgundy-brown
            Color(0xFF8B2635), // burgundy
            Color(0xFF5C2020), // darker brown
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF8B2635).withValues(alpha: 0.35),
            blurRadius: 18,
            offset: const Offset(0, 8),
            spreadRadius: 0,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 6,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(40),
          splashColor: Colors.white.withValues(alpha: 0.10),
          highlightColor: Colors.white.withValues(alpha: 0.05),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 18),
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Color(0xFFD4AA6D), // gold text
                letterSpacing: 2.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
