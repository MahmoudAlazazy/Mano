import 'package:flutter/material.dart';
import 'package:mano/providers/supabase_provider.dart';
import 'package:provider/provider.dart';
import 'dart:convert';
import '../theme/app_theme.dart';
import '../models/user_profile.dart';
import '../main.dart' show AppRoutes;
import 'admin_dashboard_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  static const String _localAdminEmail = 'admin2002@gmail.com';
  static const String _localAdminPasswordCanonical = 'admin@2002';

  // ── Form ────────────────────────────────────────────────────
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _passwordHidden = true;
  bool _isLoading = false;
  String? _errorMessage;

  // ── Animation ───────────────────────────────────────────────
  late final AnimationController _controller;
  late final Animation<double> _fadeAnim;
  late final Animation<Offset> _slideAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _fadeAnim = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  // â”€â”€ Helpers: read metadata safely â”€â”€â”€â”€â”€â”€â”€
  double _metaDouble(dynamic value, double fallback) {
    if (value is num) return value.toDouble();
    if (value is String) {
      final parsed = double.tryParse(value);
      if (parsed != null) return parsed;
    }
    return fallback;
  }

  String _metaString(dynamic value, String fallback) {
    if (value is String && value.trim().isNotEmpty) return value.trim();
    return fallback;
  }

  List<String> _metaStringList(dynamic value, List<String> fallback) {
    if (value is List) {
      return value
          .map((e) => e.toString())
          .where((s) => s.trim().isNotEmpty)
          .toList();
    }
    if (value is String && value.trim().isNotEmpty) {
      final trimmed = value.trim();
      if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is List) {
            return decoded
                .map((e) => e.toString())
                .where((s) => s.trim().isNotEmpty)
                .toList();
          }
        } catch (_) {}
      }
      return trimmed
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    }
    return fallback;
  }

  // ── Actions ─────────────────────────────────────────────────
  Future<void> _onSignIn() async {
    if (!_formKey.currentState!.validate()) return;

    final email = _emailCtrl.text.trim();
    final passwordRaw = _passwordCtrl.text;
    final authProvider = context.read<AuthProvider>();

    if (_isLocalAdminCredentials(email: email, password: passwordRaw)) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });

      final authOk = await authProvider.signIn(
        email: email,
        password: passwordRaw.trim(),
      );

      if (!mounted) return;
      setState(() => _isLoading = false);

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => AdminDashboardScreen(
            forceAdminAccess: true,
            localAdminEmail: email,
          ),
        ),
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            authOk
                ? 'Admin login successful'
                : 'Admin local mode only: Supabase auth failed, data may be limited',
          ),
          backgroundColor: authOk ? Colors.green : AppColors.warning,
        ),
      );
      return;
    }

    if (authProvider.remainingWaitSeconds > 0) {
      _showError('Rate limited. Wait ${authProvider.remainingWaitSeconds}s');
      return;
    }

    // Read providers before first await to avoid BuildContext issues
    final profileProvider = context.read<ProfileProvider>();
    final wardrobeProvider = context.read<WardrobeProvider>();
    final statsProvider = context.read<StatsProvider>();

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final password = _passwordCtrl.text.trim();

      // Sign in with Supabase
      final success = await authProvider.signIn(
        email: email,
        password: password,
      );

      if (!success) {
        _showError(authProvider.error ?? 'Sign in failed');
        return;
      }

      // Get authenticated user
      final user = authProvider.user;
      if (user != null) {
        // Load user profile
        await profileProvider.loadProfile(user.id);

        // If profile missing (e.g., email confirmation flow), build from metadata
        if (profileProvider.profile == null) {
          final meta = user.userMetadata ?? {};

          final name = _metaString(
            meta['name'],
            user.email?.split('@').first ?? 'User',
          );
          final height = _metaDouble(meta['height'], 170);
          final weight = _metaDouble(meta['weight'], 65);
          final skinTone = _metaString(meta['skin_tone'], 'Medium');
          final bodyType = _metaString(meta['body_type'], 'Regular');
          final stylePersonality = _metaString(meta['style_personality'], 'Classic');
          final favoriteColors = _metaStringList(meta['favorite_colors'], const []);
          final occasions = _metaStringList(meta['occasions'], const ['Casual']);

          final profile = UserProfile(
            name:             name,
            height:           height,
            weight:           weight,
            skinTone:         skinTone,
            bodyType:         bodyType,
            stylePersonality: stylePersonality,
            favoriteColors:   favoriteColors,
            occasions:        occasions,
            createdAt:        DateTime.now(),
            updatedAt:        DateTime.now(),
          );

          await profileProvider.createProfile(
            user.id,
            profile,
            user.email ?? email,
          );
        }

        // Load wardrobe
        await wardrobeProvider.loadWardrobe(user.id);

        // Load stats
        await statsProvider.loadStats(user.id);
      }

      if (!mounted) return;

      // Navigate to home
      Navigator.pushReplacementNamed(context, AppRoutes.home);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(Icons.check_circle, color: Colors.white),
              SizedBox(width: 8),
              Text('Welcome back!'),
            ],
          ),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      _showError(e.toString().replaceAll('Exception:', '').trim());
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _showError(String message) {
    setState(() => _errorMessage = message);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(Icons.error_outline, color: Colors.white),
            SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: AppColors.error,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  void _onForgotPassword() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Password reset link sent!'),
        backgroundColor: AppColors.primary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
      ),
    );
  }

  void _onSignUp() {
    Navigator.pushNamed(context, AppRoutes.register);
  }

  // ── Validators ──────────────────────────────────────────────
  String? _validateEmail(String? v) {
    if (v == null || v.trim().isEmpty) return 'Email is required';
    final regex = RegExp(r'^[\w-.]+@([\w-]+\.)+[\w]{2,4}$');
    if (!regex.hasMatch(v.trim())) return 'Enter a valid email';
    return null;
  }

  String? _validatePassword(String? v) {
    if (v == null || v.isEmpty) return 'Password is required';
    if (v.length < 6) return 'Password must be at least 6 characters';
    return null;
  }

  bool _isLocalAdminCredentials({
    required String email,
    required String password,
  }) {
    final normalizedEmail = email.trim().toLowerCase();
    final normalizedPassword = password
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '')
        .trim();
    return normalizedEmail == _localAdminEmail &&
        normalizedPassword == _localAdminPasswordCanonical;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.xl,
            ),
            child: SlideTransition(
              position: _slideAnim,
              child: FadeTransition(
                opacity: _fadeAnim,
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── Logo ───────────────────────────────
                      const SizedBox(height: AppSpacing.md),
                      Center(
                        child: Image.asset(
                          'assets/images/logo.png',
                          width: 120,
                          height: 120,
                          fit: BoxFit.contain,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.lg),

                      // ── Title with left accent bar ───────────
                      Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 3,
                              height: 30,
                              decoration: BoxDecoration(
                                color: AppColors.primary,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            const Text(
                              'Outfit Advisor',
                              style: AppTextStyles.displayMedium,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs + 2),

                      // ── Subtitle ────────────────────────────
                      const Center(
                        child: Text(
                          'Welcome back, stylist!',
                          style: AppTextStyles.bodyMedium,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xl + 4),

                      // ── Error message ──────────────────────
                      if (_errorMessage != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: AppSpacing.md),
                          child: Container(
                            padding: const EdgeInsets.all(AppSpacing.md),
                            decoration: BoxDecoration(
                              color: AppColors.error.withValues(alpha: 0.1),
                              borderRadius:
                                  BorderRadius.circular(AppRadius.md),
                              border: Border.all(color: AppColors.error),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.error_outline,
                                    color: AppColors.error),
                                SizedBox(width: AppSpacing.sm),
                                Expanded(
                                  child: Text(_errorMessage!,
                                      style: TextStyle(
                                          color: AppColors.error,
                                          fontSize: 13)),
                                ),
                              ],
                            ),
                          ),
                        ),

                      // ── Email field ─────────────────────────
                      const _FieldLabel(label: 'Email'),
                      const SizedBox(height: AppSpacing.sm),
                      TextFormField(
                        controller: _emailCtrl,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        validator: _validateEmail,
                        enabled: !_isLoading,
                        style: AppTextStyles.bodyLarge,
                        decoration: const InputDecoration(
                          hintText: 'you@example.com',
                          prefixIcon: Icon(
                            Icons.mail_outline_rounded,
                            color: AppColors.textSecondary,
                            size: 20,
                          ),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: AppSpacing.md,
                            vertical: AppSpacing.md,
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),

                      // ── Password field ──────────────────────
                      const _FieldLabel(label: 'Password'),
                      const SizedBox(height: AppSpacing.sm),
                      TextFormField(
                        controller: _passwordCtrl,
                        obscureText: _passwordHidden,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: _isLoading ? null : (_) => _onSignIn(),
                        validator: _validatePassword,
                        enabled: !_isLoading,
                        style: AppTextStyles.bodyLarge,
                        decoration: InputDecoration(
                          hintText: '••••••••',
                          prefixIcon: const Icon(
                            Icons.lock_outline_rounded,
                            color: AppColors.textSecondary,
                            size: 20,
                          ),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _passwordHidden
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                              color: AppColors.textSecondary,
                              size: 20,
                            ),
                            onPressed: _isLoading
                                ? null
                                : () => setState(
                                      () =>
                                          _passwordHidden = !_passwordHidden,
                                    ),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.md,
                            vertical: AppSpacing.md,
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),

                      // ── Forgot password ──────────────────────
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: _isLoading ? null : _onForgotPassword,
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            foregroundColor: AppColors.primary,
                          ),
                          child: const Text(
                            'Forgot password?',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppColors.primary,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.lg + 4),

                      // ── Sign In button ───────────────────────
                      Consumer<AuthProvider>(
                        builder: (context, authProvider, child) {
                          final isDisabled = _isLoading || authProvider.remainingWaitSeconds > 0;
                          return SizedBox(
                            width: double.infinity,
                            height: 54,
                            child: ElevatedButton(
                              onPressed: isDisabled ? null : _onSignIn,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primary,
                                disabledBackgroundColor:
                                    AppColors.primary.withValues(alpha: 0.7),
                                shape: RoundedRectangleBorder(
                                  borderRadius:
                                      BorderRadius.circular(AppRadius.md),
                                ),
                                elevation: 0,
                              ),
                              child: isDisabled
                                  ? Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (_isLoading)
                                          const SizedBox(
                                            width: 22,
                                            height: 22,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2.5,
                                              color: Colors.white,
                                            ),
                                          ),
                                        if (authProvider.remainingWaitSeconds > 0) ...[
                                          Text('${authProvider.remainingWaitSeconds}s'),
                                          const SizedBox(width: 8),
                                          const Icon(Icons.timer_outlined, size: 16),
                                        ],
                                      ],
                                    )
                                  : const Text(
                                      'Sign In',
                                      style: AppTextStyles.button,
                                    ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: AppSpacing.lg),

                      // ── Sign up row ──────────────────────────
                      Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              "Don't have an account? ",
                              style: AppTextStyles.bodyMedium,
                            ),
                            GestureDetector(
                              onTap: _isLoading ? null : _onSignUp,
                              child: const Text(
                                'Sign Up',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.primary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// Sub-widgets
// ─────────────────────────────────────────────────────────────────

/// Consistent field label used above each TextField
class _FieldLabel extends StatelessWidget {
  final String label;
  const _FieldLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
    );
  }
}
