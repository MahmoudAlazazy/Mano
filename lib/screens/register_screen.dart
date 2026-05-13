import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:outfitadvisor/providers/supabase_provider.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../models/user_profile.dart';
import '../main.dart' show AppRoutes;
import '../services/supabase_service.dart';

/// Registration screen where a new user sets up their account credentials
/// and style profile (body type, skin tone, colors, occasions, etc.) in one flow.
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen>
    with SingleTickerProviderStateMixin {

  // ── Form ────────────────────────────────────────────────────
  final _formKey      = GlobalKey<FormState>();
  final _emailCtrl    = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _nameCtrl     = TextEditingController();
  final _heightCtrl   = TextEditingController(text: '170');
  final _weightCtrl   = TextEditingController(text: '65');

  bool    _passwordHidden = true;
  bool    _isLoading      = false;
  bool    _termsAccepted  = false;
  String? _errorMessage;

  // ── Profile defaults ────────────────────────────────────────
  // These are pre-selected values for the style profile fields.
  // The user can change them before submitting.
  String       _skinTone         = 'Medium';
  String       _bodyType         = 'Regular';
  String       _stylePersonality = 'Classic';
  List<String> _favoriteColors   = [];
  List<String> _occasions        = ['Casual'];

  // ── Animation ───────────────────────────────────────────────
  late final AnimationController _controller;
  late final Animation<double>   _fadeAnim;
  late final Animation<Offset>   _slideAnim;

  @override
  void initState() {
    super.initState();

    // Entrance animation: the form fades in and slides up from slightly below.
    _controller = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 700),
    );
    _fadeAnim  = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end:   Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    // Small delay so the animation starts after the first frame is painted.
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) _controller.forward();
    });

    // Clear any leftover auth error from a previous session.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AuthProvider>().clearError();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _nameCtrl.dispose();
    _heightCtrl.dispose();
    _weightCtrl.dispose();
    super.dispose();
  }

  // ── Register ──────────────────────────────────────────────────

  /// Handles the full registration flow:
  /// 1. Validates the form and checks rate-limit / terms acceptance.
  /// 2. Signs up via [AuthProvider], passing all profile fields as metadata.
  /// 3. If email confirmation is required, shows a dialog and stops.
  /// 4. Otherwise, creates the [UserProfile] in the database and navigates home.
  Future<void> _onRegister() async {
    if (!_formKey.currentState!.validate()) return;

    final authProvider = context.read<AuthProvider>();

    // Block the attempt if the user is still in a rate-limit cooldown.
    if (authProvider.remainingWaitSeconds > 0) {
      _showError('Please wait ${authProvider.remainingWaitSeconds}s before retrying');
      return;
    }

    if (!_termsAccepted) {
      _showError('Please accept Terms of Service and Privacy Policy');
      return;
    }

    setState(() { _isLoading = true; _errorMessage = null; });

    try {
      final email    = _emailCtrl.text.trim();
      final password = _passwordCtrl.text;
      final name     = _nameCtrl.text.trim();
      final height   = double.tryParse(_heightCtrl.text) ?? 170;
      final weight   = double.tryParse(_weightCtrl.text) ?? 65;

      final profileProvider = context.read<ProfileProvider>();

      // 1. Sign up — profile data is stored in auth.user_metadata so it
      //    survives even if the DB profile write fails immediately after.
      final success = await authProvider.signUp(
        email:    email,
        password: password,
        metadata: {
          'name':              name,
          'height':            height,
          'weight':            weight,
          'skin_tone':         _skinTone,
          'body_type':         _bodyType,
          'style_personality': _stylePersonality,
          'favorite_colors':   _favoriteColors,
          'occasions':         _occasions,
        },
      );

      if (!success) {
        _showError(authProvider.error ?? 'Registration failed');
        return;
      }

      // 2. Ensure we have an active session (email confirmation may be enabled).
      //    If there is no session, the user must verify their email first.
      final session = SupabaseService().getSession();
      if (session == null) {
        if (!mounted) return;
        setState(() => _isLoading = false);
        _showEmailConfirmationDialog(name, email);
        return;
      }

      // 3. Retrieve the userId now that the session is confirmed.
      final userId = authProvider.user?.id ?? SupabaseService().currentUserId;
      if (userId == null) {
        if (!mounted) return;
        setState(() => _isLoading = false);
        _showError('Please sign in after confirming your email');
        return;
      }

      // 4. Create the profile document in the database.
      final newProfile = UserProfile(
        name:             name,
        height:           height,
        weight:           weight,
        skinTone:         _skinTone,
        bodyType:         _bodyType,
        stylePersonality: _stylePersonality,
        favoriteColors:   _favoriteColors,
        occasions:        _occasions,
        createdAt:        DateTime.now(),
        updatedAt:        DateTime.now(),
      );

      await profileProvider.createProfile(userId, newProfile, email);

      if (!mounted) return;

      // 5. Navigate to the home screen on success.
      Navigator.pushReplacementNamed(context, AppRoutes.home);

      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Row(children: [
          const Icon(Icons.check_circle, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(child: Text('Welcome $name! Your profile is ready.')),
        ]),
        backgroundColor: Colors.green,
        duration:        const Duration(seconds: 3),
      ));

    } catch (e) {
      _showError(e.toString().replaceAll('Exception:', '').trim());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ── Email confirmation dialog ─────────────────────────────────

  /// Shown when Supabase requires email verification before the session is active.
  /// The dialog is non-dismissible to prevent the user from skipping the step.
  void _showEmailConfirmationDialog(String name, String email) {
    showDialog(
      context:            context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg)),
        title: const Row(children: [
          Icon(Icons.mark_email_unread_rounded, color: AppColors.primary),
          SizedBox(width: 8),
          Text('Confirm your email',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        ]),
        content: Column(
          mainAxisSize:        MainAxisSize.min,
          crossAxisAlignment:  CrossAxisAlignment.start,
          children: [
            const Text('We sent a confirmation link to:',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
            const SizedBox(height: 4),
            Text(email,
                style: const TextStyle(
                    fontWeight: FontWeight.w700, color: AppColors.primary)),
            const SizedBox(height: 12),
            const Text(
              'Check your inbox, click the link to activate your account, then sign in.',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context); // close dialog
              Navigator.pop(context); // back to login
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md)),
            ),
            child: const Text('Go to Sign In',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  /// Shows an error snack bar and stores the message for the inline banner.
  void _showError(String message) {
    setState(() => _errorMessage = message);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        const Icon(Icons.error_outline, color: Colors.white),
        const SizedBox(width: 8),
        Expanded(child: Text(message)),
      ]),
      backgroundColor: AppColors.error,
      duration:        const Duration(seconds: 4),
    ));
  }

  void _toggleTerms() => setState(() => _termsAccepted = !_termsAccepted);

  /// Adds or removes [color] from the favorite colors selection.
  void _toggleColor(String color) {
    final list = List<String>.from(_favoriteColors);
    list.contains(color) ? list.remove(color) : list.add(color);
    setState(() => _favoriteColors = list);
  }

  /// Adds or removes [occ] from the selected occasions list.
  void _toggleOccasion(String occ) {
    final list = List<String>.from(_occasions);
    list.contains(occ) ? list.remove(occ) : list.add(occ);
    setState(() => _occasions = list);
  }

  // ── Validators ───────────────────────────────────────────────

  String? _validateEmail(String? v) {
    if (v == null || v.trim().isEmpty) return 'Email required';
    return !RegExp(r'^[\w-.]+@([\w-]+\.)+[\w]{2,4}$').hasMatch(v.trim())
        ? 'Valid email required' : null;
  }

  /// Password must be at least 6 characters (Supabase minimum).
  String? _validatePassword(String? v) =>
      (v == null || v.length < 6) ? 'Password ≥ 6 chars' : null;

  String? _validateName(String? v) =>
      (v == null || v.trim().isEmpty) ? 'Name required' : null;

  // ── Build ────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final waitSecs   = context.watch<AuthProvider>().remainingWaitSeconds;
    // The form and all interactive controls are disabled while a request is
    // in-flight or during the rate-limit cooldown period.
    final isDisabled = _isLoading || waitSecs > 0;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: GestureDetector(
        // Dismiss the keyboard when tapping outside a text field.
        onTap: () => FocusScope.of(context).unfocus(),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg, vertical: AppSpacing.xl),
            child: SlideTransition(
              position: _slideAnim,
              child: FadeTransition(
                opacity: _fadeAnim,
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [

                      // Back button
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
                      ),
                      const SizedBox(height: AppSpacing.sm),

                      // App logo
                      Center(child: ClipOval(
                        child: Image.asset('assets/images/logo.png',
                          width: 100, height: 100, fit: BoxFit.cover),
                      )),
                      const SizedBox(height: AppSpacing.lg),

                      // Screen title and subtitle
                      const Center(child: Column(children: [
                        Text('Create Account',
                            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                        SizedBox(height: 4),
                        Text('Set up your style profile',
                            style: TextStyle(fontSize: 16, color: AppColors.textSecondary)),
                      ])),
                      const SizedBox(height: AppSpacing.xl),

                      // Inline error banner
                      if (_errorMessage != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: AppSpacing.md),
                          child: Container(
                            padding: const EdgeInsets.all(AppSpacing.md),
                            decoration: BoxDecoration(
                              color:        AppColors.error.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(AppRadius.md),
                              border:       Border.all(color: AppColors.error),
                            ),
                            child: Row(children: [
                              Icon(Icons.error_outline, color: AppColors.error),
                              SizedBox(width: AppSpacing.sm),
                              Expanded(child: Text(_errorMessage!,
                                  style: TextStyle(color: AppColors.error, fontSize: 13))),
                            ]),
                          ),
                        ),

                      // Rate-limit countdown banner
                      if (waitSecs > 0)
                        Padding(
                          padding: const EdgeInsets.only(bottom: AppSpacing.md),
                          child: Container(
                            padding: const EdgeInsets.all(AppSpacing.md),
                            decoration: BoxDecoration(
                              color:        Colors.orange.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(AppRadius.md),
                              border:       Border.all(color: Colors.orange),
                            ),
                            child: Row(children: [
                              const Icon(Icons.timer_outlined, color: Colors.orange),
                              const SizedBox(width: 8),
                              Text('Too many attempts. Please wait ${waitSecs}s',
                                  style: const TextStyle(color: Colors.orange, fontSize: 13)),
                            ]),
                          ),
                        ),

                      // ── Credentials ───────────────────────────────

                      // Email
                      const Text('Email', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      const SizedBox(height: AppSpacing.sm),
                      TextFormField(
                        controller: _emailCtrl, keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next, validator: _validateEmail,
                        enabled: !isDisabled,
                        decoration: InputDecoration(
                          hintText: 'you@example.com',
                          prefixIcon: const Icon(Icons.mail_outline, color: AppColors.textSecondary),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),

                      // Password
                      const Text('Password', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      const SizedBox(height: AppSpacing.sm),
                      TextFormField(
                        controller: _passwordCtrl, obscureText: _passwordHidden,
                        textInputAction: TextInputAction.next, validator: _validatePassword,
                        enabled: !isDisabled,
                        decoration: InputDecoration(
                          hintText: '••••••••',
                          prefixIcon: const Icon(Icons.lock_outline, color: AppColors.textSecondary),
                          // Toggle visibility icon button
                          suffixIcon: IconButton(
                            onPressed: () => setState(() => _passwordHidden = !_passwordHidden),
                            icon: Icon(_passwordHidden ? Icons.visibility : Icons.visibility_off),
                          ),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),

                      // Full name
                      const Text('Full Name', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      const SizedBox(height: AppSpacing.sm),
                      TextFormField(
                        controller: _nameCtrl, textInputAction: TextInputAction.next,
                        validator: _validateName, enabled: !isDisabled,
                        decoration: InputDecoration(
                          hintText: 'Sarah Johnson',
                          prefixIcon: const Icon(Icons.person_outline, color: AppColors.textSecondary),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.lg),

                      // ── Measurements ──────────────────────────────

                      Row(children: [
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          const Text('Height (cm)', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 8),
                          TextFormField(controller: _heightCtrl, keyboardType: TextInputType.number,
                            enabled: !isDisabled,
                            decoration: InputDecoration(hintText: '170',
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)))),
                        ])),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          const Text('Weight (kg)', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 8),
                          TextFormField(controller: _weightCtrl, keyboardType: TextInputType.number,
                            enabled: !isDisabled,
                            decoration: InputDecoration(hintText: '65',
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)))),
                        ])),
                      ]),
                      const SizedBox(height: AppSpacing.lg),

                      // ── Style Preferences ─────────────────────────

                      _ChipSection(title: 'Body Type', options: UserProfile.bodyTypeOptions,
                        selected: _bodyType, onChanged: (v) => setState(() => _bodyType = v), enabled: !isDisabled),
                      const SizedBox(height: AppSpacing.md),
                      _ChipSection(title: 'Skin Tone', options: UserProfile.skinTones,
                        selected: _skinTone, onChanged: (v) => setState(() => _skinTone = v), enabled: !isDisabled),
                      const SizedBox(height: AppSpacing.md),
                      _ChipSection(title: 'Style', options: UserProfile.styleOptions,
                        selected: _stylePersonality, onChanged: (v) => setState(() => _stylePersonality = v), enabled: !isDisabled),
                      const SizedBox(height: AppSpacing.lg),

                      // Favorite colors — horizontally scrollable swatch row
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('Favorite Colors', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                        const SizedBox(height: AppSpacing.sm),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(children: UserProfile.colorSwatches.map((swatch) =>
                            Padding(padding: const EdgeInsets.only(right: AppSpacing.sm),
                              child: _ColorChip(label: swatch.name, color: swatch.color,
                                isSelected: _favoriteColors.contains(swatch.name),
                                onTap: isDisabled ? null : () => _toggleColor(swatch.name)))).toList()),
                        ),
                      ]),
                      const SizedBox(height: AppSpacing.md),

                      // Occasions — wrapped chip grid (multi-select)
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('Occasions', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                        const SizedBox(height: AppSpacing.sm),
                        Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.sm,
                          children: UserProfile.occasionOptions.map((occ) =>
                            _Chip(label: occ, isSelected: _occasions.contains(occ),
                              onTap: isDisabled ? null : () => _toggleOccasion(occ))).toList()),
                      ]),
                      const SizedBox(height: AppSpacing.lg),

                      // Terms of Service & Privacy Policy checkbox
                      Row(children: [
                        Checkbox(value: _termsAccepted,
                          onChanged: isDisabled ? null : (_) => _toggleTerms(),
                          activeColor: AppColors.primary),
                        Expanded(child: RichText(text: TextSpan(style: AppTextStyles.bodySmall, children: [
                          const TextSpan(text: 'I agree to '),
                          TextSpan(text: 'Terms of Service',
                            style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.w600),
                            recognizer: TapGestureRecognizer()..onTap = () {}),
                          const TextSpan(text: ' & '),
                          TextSpan(text: 'Privacy Policy',
                            style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.w600),
                            recognizer: TapGestureRecognizer()..onTap = () {}),
                        ]))),
                      ]),
                      const SizedBox(height: AppSpacing.lg),

                      // Submit button — shows a spinner while loading or a countdown during rate-limit.
                      SizedBox(
                        width: double.infinity, height: 54,
                        child: ElevatedButton(
                          onPressed: isDisabled ? null : _onRegister,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            disabledBackgroundColor: AppColors.primary.withValues(alpha: 0.6),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
                          ),
                          child: isDisabled
                              ? Row(mainAxisSize: MainAxisSize.min, children: [
                                  if (_isLoading) ...[
                                    const SizedBox(width: 20, height: 20,
                                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)),
                                    const SizedBox(width: 8),
                                    const Text('Creating account…', style: TextStyle(color: Colors.white)),
                                  ],
                                  if (waitSecs > 0 && !_isLoading) ...[
                                    const Icon(Icons.timer_outlined, color: Colors.white, size: 16),
                                    const SizedBox(width: 6),
                                    Text('Wait ${waitSecs}s', style: const TextStyle(color: Colors.white)),
                                  ],
                                ])
                              : const Text('Create Account',
                                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),

                      // Link back to the login screen
                      Center(child: TextButton(
                        onPressed: isDisabled ? null : () => Navigator.pop(context),
                        child: const Text.rich(TextSpan(text: 'Already have account? ', children: [
                          TextSpan(text: 'Sign In',
                            style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w700)),
                        ])),
                      )),
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
// Chip Section  — a labelled horizontal scrollable row of single-select chips
// ─────────────────────────────────────────────────────────────────
class _ChipSection extends StatelessWidget {
  final String title;
  final List<String> options;
  final String selected;
  final Function(String) onChanged;
  final bool enabled;

  const _ChipSection({
    required this.title,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      const SizedBox(height: AppSpacing.sm),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: options.map((opt) => Padding(
          padding: const EdgeInsets.only(right: AppSpacing.sm),
          child: ChoiceChip(
            label: Text(opt),
            selected: opt == selected,
            onSelected: enabled ? (_) => onChanged(opt) : null,
            selectedColor: AppColors.primary.withValues(alpha: 0.1),
            labelStyle: TextStyle(
              color: opt == selected ? AppColors.primary : AppColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
        )).toList()),
      ),
    ]);
  }
}

/// A toggleable text chip used for multi-select fields such as Occasions.
class _Chip extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback? onTap;

  const _Chip({required this.label, required this.isSelected, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.primary.withValues(alpha: isSelected ? 0 : 0.3)),
        ),
        child: Text(label, style: TextStyle(
          color: isSelected ? Colors.white : AppColors.primary,
          fontWeight: FontWeight.w600,
        )),
      ),
    );
  }
}

/// A circular color swatch chip used for the Favorite Colors selector.
/// Shows a check mark when selected.
class _ColorChip extends StatelessWidget {
  final String label;
  final Color color;
  final bool isSelected;
  final VoidCallback? onTap;

  const _ColorChip({
    required this.label,
    required this.color,
    required this.isSelected,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(children: [
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: isSelected ? AppColors.primary : Colors.white,
              width: isSelected ? 3 : 2,
            ),
          ),
          child: isSelected
              ? const Icon(Icons.check, color: Colors.white, size: 20)
              : null,
        ),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
      ]),
    );
  }
}
