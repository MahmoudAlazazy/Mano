
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mano/providers/supabase_provider.dart';
import 'package:provider/provider.dart';

import '../theme/app_theme.dart';
import '../models/user_profile.dart';
import '../services/admin_access_service.dart';
import '../services/supabase_service.dart';
import '../widgets/bottom_nav_bar.dart';
import '../../../main.dart' as app;

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with SingleTickerProviderStateMixin {

  // ── Local Edit State ──────────────────────────────────────────
  late UserProfile _editProfile;
  bool             _isEditing     = false;
  bool             _isSaving      = false;
  bool             _isSaved       = false;
  bool             _isUploadingImg = false;   // ← NEW: spinner for image upload
  String?          _errorMessage;

  // ── Text Controllers ──────────────────────────────────────────
  late final TextEditingController _nameCtrl;
  late final TextEditingController _heightCtrl;
  late final TextEditingController _weightCtrl;

  // ── Animation ─────────────────────────────────────────────────
  late final AnimationController _controller;
  late final Animation<double>   _fadeAnim;
  late final Animation<Offset>   _slideAnim;

  @override
  void initState() {
    super.initState();

    final provider = context.read<ProfileProvider>();
    _editProfile = provider.profile ?? UserProfile(
      name:             'User',
      height:           170,
      weight:           65,
      skinTone:         'Medium',
      bodyType:         'Regular',
      stylePersonality: 'Classic',
      favoriteColors:   [],
      occasions:        ['Casual'],
      createdAt:        DateTime.now(),
      updatedAt:        DateTime.now(),
    );

    _nameCtrl   = TextEditingController(text: _editProfile.name);
    _heightCtrl = TextEditingController(text: _editProfile.height.toStringAsFixed(0));
    _weightCtrl = TextEditingController(text: _editProfile.weight.toStringAsFixed(0));

    _controller = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 500),
    );
    _fadeAnim  = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.05),
      end:   Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    Future.delayed(
      const Duration(milliseconds: 80),
      () { if (mounted) _controller.forward(); },
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _nameCtrl.dispose();
    _heightCtrl.dispose();
    _weightCtrl.dispose();
    super.dispose();
  }

  // ── Helpers ───────────────────────────────────────────────────

  void _toggleEditMode() {
    if (_isEditing) {
      final provider = context.read<ProfileProvider>();
      setState(() {
        _isEditing       = false;
        _editProfile     = provider.profile ?? _editProfile;
        _nameCtrl.text   = _editProfile.name;
        _heightCtrl.text = _editProfile.height.toStringAsFixed(0);
        _weightCtrl.text = _editProfile.weight.toStringAsFixed(0);
        _errorMessage    = null;
      });
    } else {
      setState(() => _isEditing = true);
    }
  }

  void _toggleColor(String name) {
    if (!_isEditing) return;
    final current = List<String>.from(_editProfile.favoriteColors);
    current.contains(name) ? current.remove(name) : current.add(name);
    setState(() => _editProfile = _editProfile.copyWith(favoriteColors: current));
  }

  void _toggleOccasion(String name) {
    if (!_isEditing) return;
    final current = List<String>.from(_editProfile.occasions);
    current.contains(name) ? current.remove(name) : current.add(name);
    setState(() => _editProfile = _editProfile.copyWith(occasions: current));
  }

  // ── Pick & Upload Image ───────────────────────────────────────
  Future<void> _pickImage() async {
    if (!_isEditing) return;

    // Show bottom sheet: camera or gallery
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Change Profile Photo',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFEEF2FF),
                  child: Icon(Icons.photo_library_rounded, color: AppColors.primary),
                ),
                title: const Text('Choose from Gallery',
                    style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                onTap: () => Navigator.pop(context, ImageSource.gallery),
              ),
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFEEF2FF),
                  child: Icon(Icons.camera_alt_rounded, color: AppColors.primary),
                ),
                title: const Text('Take a Photo',
                    style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                onTap: () => Navigator.pop(context, ImageSource.camera),
              ),
              if (_editProfile.imagePath != null) ...[
                const Divider(),
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFFFEEEE),
                    child: Icon(Icons.delete_rounded, color: Colors.red),
                  ),
                  title: const Text('Remove Photo',
                      style: TextStyle(fontWeight: FontWeight.w600, color: Colors.red)),
                  onTap: () => Navigator.pop(context, null),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    // User dismissed without picking
    if (!mounted) return;
    if (source == null && _editProfile.imagePath == null) return;

    // Remove photo
    if (source == null && _editProfile.imagePath != null) {
      setState(() => _editProfile = _editProfile.copyWith(imagePath: null));
      return;
    }

    // Pick image
    final picker = ImagePicker();
    final XFile? picked = await picker.pickImage(
      source:       source!,
      imageQuality: 80,
      maxWidth:     512,
      maxHeight:    512,
    );

    if (picked == null || !mounted) return;

    setState(() => _isUploadingImg = true);

    try {
      final supabase = SupabaseService();
      final userId   = supabase.currentUserId;
      if (userId == null) throw Exception('User not authenticated');

      // Upload to Supabase Storage → returns public URL
      final url = await supabase.uploadAvatar(userId, picked.path);

      if (url != null) {
        setState(() => _editProfile = _editProfile.copyWith(imagePath: url));
        _showSuccess('Profile photo updated!');
      }
    } catch (e) {
      _showError('Failed to upload photo: ${e.toString()}');
    } finally {
      if (mounted) setState(() => _isUploadingImg = false);
    }
  }

  // ── Save Profile ──────────────────────────────────────────────
  Future<void> _onSave() async {
    FocusScope.of(context).unfocus();

    final h = double.tryParse(_heightCtrl.text);
    final w = double.tryParse(_weightCtrl.text);
    final n = _nameCtrl.text.trim();

    if (h == null || w == null || n.isEmpty) {
      _showError('Please enter valid name, height and weight');
      return;
    }

    setState(() {
      _isSaving     = true;
      _isSaved      = false;
      _errorMessage = null;
    });

    try {
      final supabase = SupabaseService();
      final userId   = supabase.currentUserId;
      if (userId == null) {
        _showError('User not authenticated');
        return;
      }

      _editProfile = _editProfile.copyWith(name: n, height: h, weight: w);
      await context.read<ProfileProvider>().updateProfile(userId, _editProfile);

      setState(() {
        _isSaving  = false;
        _isSaved   = true;
        _isEditing = false;
      });

      _showSuccess('Profile saved successfully!');

      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) setState(() => _isSaved = false);
      });
    } catch (e) {
      _showError('Failed to save profile: ${e.toString()}');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _showError(String message) {
    setState(() => _errorMessage = message);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(children: [
          const Icon(Icons.error_outline, color: Colors.white),
          SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(message)),
        ]),
        backgroundColor: AppColors.error,
        behavior:        SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
      ),
    );
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(children: [
          const Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
          SizedBox(width: AppSpacing.sm),
          Text(message),
        ]),
        backgroundColor: AppColors.primary,
        behavior:        SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final globalProfile = context.watch<ProfileProvider>().profile;
    final authUser = context.watch<AuthProvider>().user;
    final isAdmin = AdminAccessService.isAdmin(authUser);

    if (!_isEditing && !_isSaving && globalProfile != null) {
      _editProfile = globalProfile;
      if (_nameCtrl.text != _editProfile.name) _nameCtrl.text = _editProfile.name;
      final hStr = _editProfile.height.toStringAsFixed(0);
      if (_heightCtrl.text != hStr) _heightCtrl.text = hStr;
      final wStr = _editProfile.weight.toStringAsFixed(0);
      if (_weightCtrl.text != wStr) _weightCtrl.text = wStr;
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        automaticallyImplyLeading: false,
        centerTitle: false,
        titleSpacing: AppSpacing.md,
        title: const Text(
          'Body Profile',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppColors.textPrimary),
        ),
        actions: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: _isSaved
                ? Container(
                    key: const ValueKey('saved'),
                    margin: const EdgeInsets.only(right: AppSpacing.md),
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8F5E9),
                      borderRadius: BorderRadius.circular(AppRadius.full),
                      border: Border.all(color: const Color(0xFFB8DEC0)),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check_rounded, color: Colors.green, size: 14),
                        SizedBox(width: 4),
                        Text(
                          'Saved',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.green),
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(key: ValueKey('empty')),
          ),
        ],
      ),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: SlideTransition(
          position: _slideAnim,
          child: FadeTransition(
            opacity: _fadeAnim,
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.md,
                AppSpacing.md,
                AppSpacing.xxl + AppSpacing.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_errorMessage != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.md),
                      child: Container(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        decoration: BoxDecoration(
                          color: AppColors.error.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(AppRadius.md),
                          border: Border.all(color: AppColors.error),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.error_outline, color: AppColors.error),
                            SizedBox(width: AppSpacing.sm),
                            Expanded(
                              child: Text(
                                _errorMessage!,
                                style: TextStyle(color: AppColors.error, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  _AvatarBanner(
                    profile: _editProfile,
                    isEditing: _isEditing,
                    isUploadingImg: _isUploadingImg,
                    nameController: _nameCtrl,
                    onPickImage: _pickImage,
                    onToggleEdit: _toggleEditMode,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _ProfileHighlights(
                    isEditing: _isEditing,
                    colorsCount: _editProfile.favoriteColors.length,
                    occasionsCount: _editProfile.occasions.length,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _SectionCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _SectionHeader(
                          icon: Icons.straighten_rounded,
                          title: 'Measurements',
                          subtitle: 'Use your latest body measurements',
                        ),
                        const SizedBox(height: AppSpacing.md),
                        Row(
                          children: [
                            Expanded(
                              child: _MeasurementField(
                                label: 'Height',
                                controller: _heightCtrl,
                                hint: '170',
                                unit: 'cm',
                                enabled: _isEditing,
                              ),
                            ),
                            const SizedBox(width: AppSpacing.md),
                            Expanded(
                              child: _MeasurementField(
                                label: 'Weight',
                                controller: _weightCtrl,
                                hint: '65',
                                unit: 'kg',
                                enabled: _isEditing,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _SectionCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _SectionHeader(
                          icon: Icons.accessibility_new_rounded,
                          title: 'Body Type',
                          subtitle: 'Choose what feels closest to you',
                        ),
                        const SizedBox(height: AppSpacing.md),
                        _horizontalScroller(
                          UserProfile.bodyTypeOptions.map((type) {
                            return _ChipSelector(
                              label: type,
                              isSelected: type == _editProfile.bodyType,
                              isEnabled: _isEditing,
                              onTap: () => setState(
                                () => _editProfile = _editProfile.copyWith(bodyType: type),
                              ),
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _SectionCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _SectionHeader(
                          icon: Icons.wb_sunny_outlined,
                          title: 'Skin Tone',
                          subtitle: 'Helps improve outfit and color matching',
                        ),
                        const SizedBox(height: AppSpacing.md),
                        _horizontalScroller(
                          UserProfile.skinTones.map((tone) {
                            return _ChipSelector(
                              label: tone,
                              isSelected: tone == _editProfile.skinTone,
                              isEnabled: _isEditing,
                              onTap: () => setState(
                                () => _editProfile = _editProfile.copyWith(skinTone: tone),
                              ),
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _SectionCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Expanded(
                              child: _SectionHeader(
                                icon: Icons.palette_outlined,
                                title: 'Favorite Colors',
                                subtitle: 'Pick shades you wear most often',
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.sm,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.primarySoft,
                                borderRadius: BorderRadius.circular(AppRadius.full),
                              ),
                              child: Text(
                                '${_editProfile.favoriteColors.length} selected',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.primary,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.md),
                        _horizontalScroller(
                          UserProfile.colorSwatches.map((swatch) {
                            return _ColorSwatchButton(
                              swatch: swatch,
                              isSelected: _editProfile.favoriteColors.contains(swatch.name),
                              isEnabled: _isEditing,
                              onTap: () => _toggleColor(swatch.name),
                            );
                          }).toList(),
                          gap: AppSpacing.md,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _SectionCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _SectionHeader(
                          icon: Icons.event_available_rounded,
                          title: 'Occasion',
                          subtitle: 'Tell us where you usually dress for',
                        ),
                        const SizedBox(height: AppSpacing.md),
                        Wrap(
                          spacing: AppSpacing.sm,
                          runSpacing: AppSpacing.sm,
                          children: UserProfile.occasionOptions.map((occ) {
                            return _ChipSelector(
                              label: occ,
                              isSelected: _editProfile.occasions.contains(occ),
                              isEnabled: _isEditing,
                              onTap: () => _toggleOccasion(occ),
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _SectionCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _SectionHeader(
                          icon: Icons.style_outlined,
                          title: 'Style Personality',
                          subtitle: 'Select the vibe that represents your style',
                        ),
                        const SizedBox(height: AppSpacing.md),
                        Wrap(
                          spacing: AppSpacing.sm,
                          runSpacing: AppSpacing.sm,
                          children: UserProfile.styleOptions.map((style) {
                            return _ChipSelector(
                              label: style,
                              isSelected: style == _editProfile.stylePersonality,
                              isEnabled: _isEditing,
                              onTap: () => setState(
                                () => _editProfile = _editProfile.copyWith(stylePersonality: style),
                              ),
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  if (_isEditing)
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: ElevatedButton(
                        onPressed: _isSaving ? null : _onSave,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          disabledBackgroundColor: AppColors.primary.withValues(alpha: 0.6),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(AppRadius.md),
                          ),
                          elevation: 0,
                        ),
                        child: _isSaving
                            ? const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      color: Colors.white,
                                    ),
                                  ),
                                  SizedBox(width: AppSpacing.sm),
                                  Text(
                                    'Saving...',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              )
                            : const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.save_rounded, color: Colors.white, size: 20),
                                  SizedBox(width: AppSpacing.sm),
                                  Text(
                                    'Save Profile',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  const SizedBox(height: AppSpacing.xxl),
                  if (isAdmin)
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.pushNamed(context, app.AppRoutes.adminDashboard);
                        },
                        icon: const Icon(Icons.admin_panel_settings_rounded),
                        label: const Text(
                          'Open Admin Dashboard',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  if (isAdmin) const SizedBox(height: AppSpacing.md),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        await context.read<AuthProvider>().signOut();
                        context.read<ProfileProvider>().clear();
                        if (mounted) {
                          Navigator.pushReplacementNamed(context, app.AppRoutes.login);
                        }
                      },
                      icon: const Icon(Icons.logout_rounded, color: Colors.white, size: 20),
                      label: const Text(
                        'Logout',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        disabledBackgroundColor: Colors.red.withValues(alpha: 0.6),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadius.md),
                        ),
                        elevation: 0,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: const AppBottomNavBar(currentIndex: 4),
    );
  }

  Widget _horizontalScroller(List<Widget> items, {double gap = AppSpacing.sm}) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
        children: [
          for (int i = 0; i < items.length; i++)
            Padding(
              padding: EdgeInsets.only(right: i == items.length - 1 ? 0 : gap),
              child: items[i],
            ),
        ],
      ),
    );
  }
}
// ─────────────────────────────────────────────────────────────────
// Section Card
// ─────────────────────────────────────────────────────────────────
class _SectionCard extends StatelessWidget {
  final Widget child;
  const _SectionCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.border.withValues(alpha: 0.75)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.035),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// Chip Selector
// ─────────────────────────────────────────────────────────────────
class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: AppColors.primarySoft,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Icon(icon, size: 18, color: AppColors.primary),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ProfileHighlights extends StatelessWidget {
  final bool isEditing;
  final int colorsCount;
  final int occasionsCount;

  const _ProfileHighlights({
    required this.isEditing,
    required this.colorsCount,
    required this.occasionsCount,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _HighlightChip(
            icon: Icons.palette_outlined,
            value: '$colorsCount colors',
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: _HighlightChip(
            icon: Icons.event_available_rounded,
            value: '$occasionsCount occasions',
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: _HighlightChip(
            icon: isEditing ? Icons.edit_rounded : Icons.verified_rounded,
            value: isEditing ? 'Edit mode' : 'Ready',
          ),
        ),
      ],
    );
  }
}

class _HighlightChip extends StatelessWidget {
  final IconData icon;
  final String value;

  const _HighlightChip({
    required this.icon,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppColors.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              value,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChipSelector extends StatelessWidget {
  final String       label;
  final bool         isSelected;
  final bool         isEnabled;
  final VoidCallback onTap;

  const _ChipSelector({
    required this.label,
    required this.isSelected,
    required this.isEnabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isEnabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          color: isSelected
              ? (isEnabled ? AppColors.primary : AppColors.primary.withValues(alpha: 0.7))
              : AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(
            color: isSelected ? AppColors.primary : AppColors.border,
            width: 1.5,
          ),
          boxShadow: isSelected && isEnabled
              ? [BoxShadow(color: AppColors.primary.withValues(alpha: 0.3), blurRadius: 8, offset: const Offset(0, 2))]
              : [],
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
            color: isSelected
                ? Colors.white
                : AppColors.textPrimary.withValues(alpha: isEnabled ? 1 : 0.5),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// Measurement Field
// ─────────────────────────────────────────────────────────────────
class _MeasurementField extends StatelessWidget {
  final String                label;
  final TextEditingController controller;
  final String                hint;
  final String                unit;
  final bool                  enabled;

  const _MeasurementField({
    required this.label,
    required this.controller,
    required this.hint,
    required this.unit,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
        const SizedBox(height: AppSpacing.xs + 2),
        TextFormField(
          controller:      controller,
          enabled:         enabled,
          keyboardType:    const TextInputType.numberWithOptions(decimal: true),
          textAlign:       TextAlign.center,
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d{0,3}\.?\d{0,1}'))],
          style: TextStyle(
            fontSize:   18,
            fontWeight: FontWeight.w700,
            color:      AppColors.textPrimary.withValues(alpha: enabled ? 1 : 0.5),
          ),
          decoration: InputDecoration(
            hintText:  hint,
            hintStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.textHint),
            filled:    true,
            fillColor: enabled ? AppColors.surfaceAlt : AppColors.surfaceAlt.withValues(alpha: 0.5),
            suffixText: unit,
            suffixStyle: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppColors.primary.withValues(alpha: enabled ? 0.95 : 0.5),
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
              borderSide: const BorderSide(color: AppColors.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
              borderSide: const BorderSide(color: AppColors.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
              borderSide: const BorderSide(color: AppColors.primary, width: 1.6),
            ),
            disabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
              borderSide: BorderSide(color: AppColors.border.withValues(alpha: 0.5)),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.md),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// Color Swatch Button
// ─────────────────────────────────────────────────────────────────
class _ColorSwatchButton extends StatelessWidget {
  final AppColorSwatch swatch;
  final bool           isSelected;
  final bool           isEnabled;
  final VoidCallback   onTap;

  const _ColorSwatchButton({
    required this.swatch,
    required this.isSelected,
    required this.isEnabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isEnabled ? onTap : null,
      child: Opacity(
        opacity: isEnabled ? 1.0 : 0.6,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width:  46,
              height: 46,
              decoration: BoxDecoration(
                color:  swatch.color,
                shape:  BoxShape.circle,
                border: Border.all(
                  color: isSelected
                      ? AppColors.primary
                      : swatch.hasBorder ? AppColors.border : Colors.transparent,
                  width: isSelected ? 3.0 : 1.5,
                ),
                boxShadow: isSelected && isEnabled
                    ? [BoxShadow(color: AppColors.primary.withValues(alpha: 0.35), blurRadius: 10, spreadRadius: 1, offset: const Offset(0, 2))]
                    : [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 6, offset: const Offset(0, 2))],
              ),
              child: isSelected
                  ? Icon(Icons.check_rounded, size: 20,
                      color: swatch.hasBorder ? AppColors.primary : Colors.white)
                  : null,
            ),
            const SizedBox(height: 4),
            Text(
              swatch.name,
              style: TextStyle(
                fontSize:   9.5,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
                color: isSelected ? AppColors.primary : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// Avatar Banner  ← UPDATED: real image display + upload spinner
// ─────────────────────────────────────────────────────────────────
class _AvatarBanner extends StatelessWidget {
  final UserProfile            profile;
  final bool                   isEditing;
  final bool                   isUploadingImg;   // ← NEW
  final TextEditingController  nameController;
  final VoidCallback           onPickImage;
  final VoidCallback           onToggleEdit;

  const _AvatarBanner({
    required this.profile,
    required this.isEditing,
    required this.isUploadingImg,
    required this.nameController,
    required this.onPickImage,
    required this.onToggleEdit,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [AppColors.primaryLight, AppColors.primary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
        boxShadow: [
          BoxShadow(color: AppColors.primary.withValues(alpha: 0.3), blurRadius: 20, offset: const Offset(0, 6)),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // ── Avatar ──────────────────────────────────────
          GestureDetector(
            onTap: onPickImage,
            child: Stack(
              alignment: Alignment.bottomRight,
              children: [
                Container(
                  width:  72,
                  height: 72,
                  decoration: BoxDecoration(
                    color:  Colors.white.withValues(alpha: 0.2),
                    shape:  BoxShape.circle,
                    border: Border.all(color: Colors.white.withValues(alpha: 0.4), width: 2),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: isUploadingImg
                      // ── Uploading spinner ──────────────
                      ? const Center(
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color:       Colors.white,
                          ),
                        )
                      : profile.imagePath != null
                          // ── Network image ───────────────
                          ? Image.network(
                              profile.imagePath!,
                              fit:    BoxFit.cover,
                              width:  72,
                              height: 72,
                              errorBuilder: (_, _, _) =>
                                  const Icon(Icons.person_rounded, size: 40, color: Colors.white),
                              loadingBuilder: (_, child, progress) => progress == null
                                  ? child
                                  : const Center(
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color:       Colors.white,
                                      ),
                                    ),
                            )
                          // ── Placeholder ─────────────────
                          : const Icon(Icons.person_rounded, size: 40, color: Colors.white),
                ),
                // Camera badge (edit mode only)
                if (isEditing && !isUploadingImg)
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                    child: const Icon(Icons.camera_alt_rounded, size: 14, color: AppColors.primary),
                  ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),

          // ── Name + stats ─────────────────────────────────
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isEditing)
                  SizedBox(
                    height: 38,
                    child: TextFormField(
                      controller: nameController,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white),
                      decoration: const InputDecoration(
                        hintText:     'Your Name',
                        hintStyle:    TextStyle(color: Colors.white54),
                        border:        UnderlineInputBorder(borderSide: BorderSide(color: Colors.white)),
                        enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white54)),
                        focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white, width: 2)),
                        contentPadding: EdgeInsets.only(bottom: 6),
                      ),
                    ),
                  )
                else
                  Text(
                    profile.name,
                    style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '${profile.height.toStringAsFixed(0)} cm  •  ${profile.weight.toStringAsFixed(0)} kg',
                  style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.85)),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '${profile.skinTone}  •  ${profile.bodyType}',
                  style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.75)),
                ),
              ],
            ),
          ),

          // ── Edit / Close icon ────────────────────────────
          GestureDetector(
            onTap: onToggleEdit,
            child: Container(
              padding: const EdgeInsets.all(8),
              margin:  const EdgeInsets.only(left: 8),
              decoration: BoxDecoration(
                color: isEditing
                    ? Colors.white.withValues(alpha: 0.3)
                    : Colors.white.withValues(alpha: 0.15),
                border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Icon(
                isEditing ? Icons.close_rounded : Icons.edit_rounded,
                size:  18,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

