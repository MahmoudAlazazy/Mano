import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../main.dart' show AppRoutes;
import '../providers/supabase_provider.dart';
import '../services/supabase_service.dart';
import '../theme/app_theme.dart';
import '../widgets/bottom_nav_bar.dart';
import '../widgets/category_card.dart';

class UploadScreen extends StatefulWidget {
  const UploadScreen({super.key});

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen>
    with SingleTickerProviderStateMixin {
  int _selectedCategoryIndex = 0;
  bool _isUploading = false;
  String? _errorMessage;

  final TextEditingController _itemNameController = TextEditingController();
  final ImagePicker _imagePicker = ImagePicker();

  late final AnimationController _controller;
  late final Animation<double> _fadeAnim;
  late final Animation<Offset> _slideAnim;

  static const List<_CategoryDef> _categories = [
    _CategoryDef(emoji: '\u{1F455}', label: 'Tops'),
    _CategoryDef(emoji: '\u{1F456}', label: 'Bottoms'),
    _CategoryDef(emoji: '\u{1F45F}', label: 'Shoes'),
    _CategoryDef(emoji: '\u{1F9E5}', label: 'Jackets'),
    _CategoryDef(emoji: '\u{1F457}', label: 'Dresses'),
    _CategoryDef(emoji: '\u{231A}', label: 'Accessories'),
  ];

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );
    _fadeAnim = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.04),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

    Future.delayed(const Duration(milliseconds: 90), () {
      if (mounted) _controller.forward();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshWardrobe();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _itemNameController.dispose();
    super.dispose();
  }

  String get _selectedCategory => _categories[_selectedCategoryIndex].label;

  String get _selectedEmoji => _categories[_selectedCategoryIndex].emoji;

  List<Map<String, dynamic>> get _recentItems {
    final items = context.watch<WardrobeProvider>().items;
    final sorted = [...items]
      ..sort((a, b) => _addedAtOf(b).compareTo(_addedAtOf(a)));
    return sorted.take(6).toList();
  }

  Map<String, int> get _counts {
    final items = context.watch<WardrobeProvider>().items;
    final counts = <String, int>{};
    for (final item in items) {
      final category = item['category']?.toString().trim();
      final key =
          (category == null || category.isEmpty) ? 'Accessories' : category;
      counts[key] = (counts[key] ?? 0) + 1;
    }
    return counts;
  }

  DateTime _addedAtOf(Map<String, dynamic> item) {
    final raw = item['added_at'];
    if (raw is String) {
      final parsed = DateTime.tryParse(raw);
      if (parsed != null) return parsed;
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  Future<void> _refreshWardrobe() async {
    final userId = SupabaseService().currentUserId;
    if (userId == null || !mounted) return;
    await context.read<WardrobeProvider>().loadWardrobe(userId);
  }

  void _handleBackTap() {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
      return;
    }
    navigator.pushReplacementNamed(AppRoutes.home);
  }

  bool _ensureItemName() {
    final name = _itemNameController.text.trim();
    if (name.isNotEmpty) return true;
    _showError('Please enter item name first.');
    return false;
  }

  Future<void> _handleTakePhoto() async {
    if (!_ensureItemName()) return;
    try {
      final photo = await _imagePicker.pickImage(
        source: ImageSource.camera,
        imageQuality: 88,
      );
      if (photo != null) {
        await _handleAddItem(imagePath: photo.path, isCamera: true);
      }
    } catch (e) {
      _showError('Failed to take photo: $e');
    }
  }

  Future<void> _handleUploadImage() async {
    if (!_ensureItemName()) return;
    try {
      final image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 88,
      );
      if (image != null) {
        await _handleAddItem(imagePath: image.path, isCamera: false);
      }
    } catch (e) {
      _showError('Failed to upload image: $e');
    }
  }

  Future<void> _handleAddItem({
    required String imagePath,
    required bool isCamera,
  }) async {
    final wardrobeProvider = context.read<WardrobeProvider>();
    setState(() {
      _isUploading = true;
      _errorMessage = null;
    });

    try {
      final supabase = SupabaseService();
      final userId = supabase.currentUserId;
      final itemName = _itemNameController.text.trim();

      if (userId == null) {
        _showError('User not authenticated.');
        return;
      }

      final imageUrl = await supabase.uploadImage(
        userId: userId,
        imagePath: imagePath,
        bucket: 'clothing_images',
      );

      await wardrobeProvider.addItem(
        userId: userId,
        name: itemName.isNotEmpty
            ? itemName
            : '${isCamera ? 'Camera' : 'Upload'} $_selectedCategory',
        category: _selectedCategory,
        emoji: _selectedEmoji,
        color: null,
        imageUrl: imageUrl,
      );

      if (!mounted) return;
      _itemNameController.clear();
      _showSuccess('Item added to $_selectedCategory.');
    } catch (e) {
      _showError('Failed to add item: $e');
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  Future<void> _handleDelete(Map<String, dynamic> item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        title: const Text(
          'Remove Item',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        content: Text(
          'Remove "${item['name']}" from your wardrobe?',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'Remove',
              style: TextStyle(
                color: AppColors.error,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      final userId = SupabaseService().currentUserId;
      if (userId == null) return;

      await context
          .read<WardrobeProvider>()
          .deleteItem(userId, item['id'] as String);

      if (!mounted) return;
      _showSuccess('${item['name']} removed.');
    } catch (e) {
      _showError('Failed to delete item: $e');
    }
  }

  void _showError(String message) {
    if (mounted) {
      setState(() => _errorMessage = message);
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          content: Row(
            children: [
              const Icon(Icons.error_outline_rounded, color: Colors.white),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: Text(message)),
            ],
          ),
        ),
      );
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: AppColors.primary,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final wardrobe = context.watch<WardrobeProvider>();
    final isBusy = _isUploading;
    final totalItems = wardrobe.items.length;
    final selectedCount = _counts[_selectedCategory] ?? 0;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        leading: Padding(
          padding: const EdgeInsets.all(AppSpacing.xs),
          child: Material(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: InkWell(
              onTap: _handleBackTap,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  border: Border.all(
                    color: AppColors.border.withValues(alpha: 0.8),
                  ),
                ),
                child: const Icon(
                  Icons.arrow_back_ios_new_rounded,
                  size: 18,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ),
        ),
        title: const Text(
          'Add Clothes',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.md),
            child: _CountPill(label: '$totalItems items'),
          ),
        ],
      ),
      body: SlideTransition(
        position: _slideAnim,
        child: FadeTransition(
          opacity: _fadeAnim,
          child: RefreshIndicator(
            color: AppColors.primary,
            onRefresh: _refreshWardrobe,
            child: ListView(
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.md,
                AppSpacing.xxl,
              ),
              children: [
                _ComposerCard(
                  controller: _itemNameController,
                  isBusy: isBusy,
                  selectedCategory: _selectedCategory,
                  selectedCount: selectedCount,
                  onTakePhoto: isBusy ? null : _handleTakePhoto,
                  onUpload: isBusy ? null : _handleUploadImage,
                ),
                if (_errorMessage != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  _ErrorBanner(message: _errorMessage!),
                ],
                const SizedBox(height: AppSpacing.lg),
                _SectionHeader(
                  title: 'Categories',
                  trailing: Text(
                    _selectedCategory,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm + 2),
                SizedBox(
                  height: 118,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    itemCount: _categories.length,
                    itemBuilder: (context, index) {
                      final category = _categories[index];
                      return CategoryCard(
                        emoji: category.emoji,
                        label: category.label,
                        itemCount: _counts[category.label] ?? 0,
                        isSelected: index == _selectedCategoryIndex,
                        onTap: () => setState(() => _selectedCategoryIndex = index),
                      );
                    },
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                _SectionHeader(
                  title: 'Recently Added',
                  trailing: _CountPill(label: '${_recentItems.length} latest'),
                ),
                const SizedBox(height: AppSpacing.sm + 2),
                if (wardrobe.isLoading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                    child: Center(
                      child: CircularProgressIndicator(
                        color: AppColors.primary,
                        strokeWidth: 2.6,
                      ),
                    ),
                  )
                else if (_recentItems.isEmpty)
                  const _EmptyRecentState()
                else
                  ..._recentItems.map(
                    (item) => _RecentItemTile(
                      item: item,
                      onDelete: () => _handleDelete(item),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: const AppBottomNavBar(currentIndex: 1),
    );
  }
}

class _ComposerCard extends StatelessWidget {
  const _ComposerCard({
    required this.controller,
    required this.isBusy,
    required this.selectedCategory,
    required this.selectedCount,
    required this.onTakePhoto,
    required this.onUpload,
  });

  final TextEditingController controller;
  final bool isBusy;
  final String selectedCategory;
  final int selectedCount;
  final VoidCallback? onTakePhoto;
  final VoidCallback? onUpload;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFFFFFFFF),
            Color(0xFFFDF9F5),
          ],
        ),
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: AppColors.border.withValues(alpha: 0.85)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.primarySoft,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: isBusy
                    ? const Padding(
                        padding: EdgeInsets.all(11),
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: AppColors.primary,
                        ),
                      )
                    : const Icon(
                        Icons.checkroom_rounded,
                        color: AppColors.primary,
                        size: 24,
                      ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Add to your wardrobe',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$selectedCategory - $selectedCount items now',
                      style: AppTextStyles.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: controller,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              hintText: 'e.g. White linen shirt',
              prefixIcon: const Icon(
                Icons.drive_file_rename_outline_rounded,
                size: 18,
                color: AppColors.textSecondary,
              ),
              filled: true,
              fillColor: AppColors.surface,
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
                borderSide: const BorderSide(
                  color: AppColors.primary,
                  width: 1.5,
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 47,
                  child: ElevatedButton.icon(
                    onPressed: onTakePhoto,
                    icon: const Icon(Icons.camera_alt_outlined, size: 18),
                    label: const Text('Camera'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor:
                          AppColors.primary.withValues(alpha: 0.55),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                      elevation: 0,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: SizedBox(
                  height: 47,
                  child: OutlinedButton.icon(
                    onPressed: onUpload,
                    icon: const Icon(Icons.upload_rounded, size: 18),
                    label: const Text('Gallery'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.primary,
                      disabledForegroundColor:
                          AppColors.primary.withValues(alpha: 0.55),
                      side: BorderSide(
                        color: AppColors.primary.withValues(
                          alpha: onUpload == null ? 0.6 : 1,
                        ),
                        width: 1.4,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RecentItemTile extends StatelessWidget {
  const _RecentItemTile({
    required this.item,
    required this.onDelete,
  });

  final Map<String, dynamic> item;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final name = item['name']?.toString().trim();
    final category = item['category']?.toString().trim();

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border.withValues(alpha: 0.75)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.035),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          _RecentItemThumb(item: item),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (name == null || name.isEmpty) ? 'Item' : name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  (category == null || category.isEmpty) ? 'Unknown' : category,
                  style: AppTextStyles.bodySmall,
                ),
              ],
            ),
          ),
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              onTap: onDelete,
              child: Container(
                padding: const EdgeInsets.all(AppSpacing.sm),
                decoration: BoxDecoration(
                  color: AppColors.error.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: const Icon(
                  Icons.delete_outline_rounded,
                  size: 18,
                  color: AppColors.error,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecentItemThumb extends StatelessWidget {
  const _RecentItemThumb({required this.item});

  final Map<String, dynamic> item;

  @override
  Widget build(BuildContext context) {
    final imageUrl = item['image_url'] as String?;
    final imagePath = item['image_path'] as String?;
    final rawEmoji = item['emoji']?.toString().trim();
    final emoji = (rawEmoji == null || rawEmoji.isEmpty) ? '\u{1F455}' : rawEmoji;

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        width: 46,
        height: 46,
        color: AppColors.primarySoft,
        alignment: Alignment.center,
        child: _buildImage(imageUrl, imagePath, emoji),
      ),
    );
  }

  Widget _buildImage(String? imageUrl, String? imagePath, String emoji) {
    if (imageUrl != null && imageUrl.isNotEmpty) {
      return Image.network(
        imageUrl,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (_, _, _) => _emojiFallback(emoji),
      );
    }

    if (imagePath != null && imagePath.isNotEmpty) {
      if (imagePath.startsWith('http')) {
        return Image.network(
          imagePath,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          errorBuilder: (_, _, _) => _emojiFallback(emoji),
        );
      }
      return Image.file(
        File(imagePath),
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (_, _, _) => _emojiFallback(emoji),
      );
    }

    return _emojiFallback(emoji);
  }

  Widget _emojiFallback(String emoji) {
    return Text(
      emoji,
      style: const TextStyle(fontSize: 22),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    this.trailing,
  });

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
        ),
        ?trailing,
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: AppColors.error),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppColors.error,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyRecentState extends StatelessWidget {
  const _EmptyRecentState();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.xl),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.border.withValues(alpha: 0.8)),
      ),
      child: Column(
        children: [
          Container(
            width: 74,
            height: 74,
            decoration: BoxDecoration(
              color: AppColors.primarySoft,
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            child: const Icon(
              Icons.checkroom_outlined,
              size: 34,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          const Text(
            'No items yet',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          const Text(
            'Add your first item using camera,\ngallery, or online image search.',
            textAlign: TextAlign.center,
            style: AppTextStyles.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _CountPill extends StatelessWidget {
  const _CountPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs + 2,
      ),
      decoration: BoxDecoration(
        color: AppColors.primarySoft,
        borderRadius: BorderRadius.circular(AppRadius.full),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.18)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: AppColors.primary,
        ),
      ),
    );
  }
}

class _CategoryDef {
  const _CategoryDef({
    required this.emoji,
    required this.label,
  });

  final String emoji;
  final String label;
}
