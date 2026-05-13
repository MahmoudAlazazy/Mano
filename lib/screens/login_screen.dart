import 'package:flutter/material.dart';
import 'package:mano/providers/supabase_provider.dart';
import 'package:provider/provider.dart';
import 'dart:convert';
import '../theme/app_theme.dart';
import '../models/user_profile.dart';
import '../main.dart' show AppRoutes;
import 'admin_dashboard_screen.dart';

/// The login screen. Handles regular Supabase authentication and a
/// hard-coded local admin bypass for development/testing purposes.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  // Hard-coded admin credentials used to bypass Supabase auth in local mode.
  static const String _localAdminEmail = 'admin2002@gmail.com';
  static const String _localAdminPasswordCanonical = 'admin@2002';

  // ── Form ─────────────────────────────────────────────────────
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _passwordHidden = true;
  bool _isLoading = false;
  String? _errorMessage;

  // ── Animation ────────────────────────────────────────────────
  late final AnimationController _controller;
  late final Animation<double> _fadeAnim;
  late final Animation<Offset> _slideAnim;

  // ── Lifecycle ─────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();

    // Fade + slide-up entrance animation for the form.
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _fadeAnim = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    // Small delay so the first frame renders before the animation starts.
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

  // ── Metadata helpers ──────────────────────────────────────────
  // These helpers safely extract typed values from Supabase user metadata,
  // returning a [fallback] when the value is absent or unparseable.

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

  /// Parses a metadata value into a string list.
  /// Accepts a native [List], a JSON-encoded array string, or a comma-separated string.
  List<String> _metaStringList(dynamic value, List<String> fallback) {
    if (value is List) {
      return value
          .map((e) => e.toString())
          .where((s) => s.trim().isNotEmpty)
          .toList();
    }
    if (value is String && value.trim().isNotEmpty) {
      final trimmed = value.trim();
      // Try JSON array first, then fall back to comma-separated parsing.
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

  // ── Actions ───────────────────────────────────────────────────

  /// Validates the form and attempts sign-in.
  ///
  /// If the credentials match the local admin bypass, the user is routed
  /// directly to [AdminDashboardScreen] regardless of Supabase auth outcome.
  /// For regular users, sign-in is attempted via Supabase, the profile and
  /// wardrobe are loaded (creating a profile from metadata when absent),
  /// and the app navigates to the home screen on success.
  Future<void> _onSignIn() async {
    if (!_formKey.currentState!.validate()) return;

    final email = _emailCtrl.text.trim();
    final passwordRaw = _passwordCtrl.text;
    final authProvider = context.read<AuthProvider>();

    // ── Admin bypass ─────────────────────────────────────────
    if (_isLocalAdminCredentials(email: email, password: passwordRaw)) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });

      // Attempt a real Supabase sign-in for data access, but proceed even
      // if it fails (admin works in local mode with limited data).
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

    // ── Rate-limit guard ──────────────────────────────────────
    if (authProvider.remainingWaitSeconds > 0) {
      _showError('Rate limited. Wait ${authProvider.remainingWaitSeconds}s');
      return;
    }

    // Capture providers before the first await to avoid stale BuildContext.
    final profileProvider = context.read<ProfileProvider>();
    final wardrobeProvider = context.read<WardrobeProvider>();
    final statsProvider = context.read<StatsProvider>();

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final password = _passwordCtrl.text.trim();

      final success = await authProvider.signIn(
        email: email,
        password: password,
      );

      if (!success) {
        _showError(authProvider.error ?? 'Sign in failed');
        return;
      }

      final user = authProvider.user;
      if (user != null) {
        await profileProvider.loadProfile(user.id);

        // Profile may be absent during email-confirmation flows; build one
        // from the user metadata stored at registration time.
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

        await wardrobeProvider.loadWardrobe(user.id);
        await statsProvider.loadStats(user.id);
      }

      if (!mounted) return;

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

  /// Displays [message] as both an inline banner and a snackbar.
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

  /// Placeholder for the forgot-password flow (currently shows a snackbar).
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

  /// Navigates to the registration screen.
  void _onSignUp() {
    Navigator.pushNamed(context, AppRoutes.register);
  }

  // ── Validators ────────────────────────────────────────────────

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

  /// Returns `true` when [email] and [password] match the local admin credentials.
  /// Comparison is case-insensitive and ignores extra whitespace.
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

  // ── Build ─────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      // Dismiss keyboard when the user taps outside any field.
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
                      // ── Logo ────────────────────────────────
                      const SizedBox(height: AppSpacing.md),
                      Center(
                        child: ClipOval(
                          child: Image.asset(
                            'assets/images/logo.png',
                            width: 120,
                            height: 120,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.lg),

                      // ── App title with left accent bar ───────
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

                      // ── Subtitle ─────────────────────────────
                      const Center(
                        child: Text(
                          'Welcome back, stylist!',
                          style: AppTextStyles.bodyMedium,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xl + 4),

                      // ── Inline error banner ───────────────────
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

                      // ── Email field ───────────────────────────
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

                      // ── Password field ────────────────────────
                      const _FieldLabel(label: 'Password'),
                      const SizedBox(height: AppSpacing.sm),
                      TextFormField(
                        controller: _passwordCtrl,
                        obscureText: _passwordHidden,
                        textInputAction: TextInputAction.done,
                        // Submitting the keyboard triggers sign-in.
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

                      // ── Forgot password link ──────────────────
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

                      // ── Sign In button ────────────────────────
                      // Disabled during loading or while the rate-limit
                      // countdown is active; shows a timer label in that case.
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

                      // ── Sign Up prompt ────────────────────────
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

// ── Sub-widgets ───────────────────────────────────────────────────────────────

/// A small bold label rendered above each form field.
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
