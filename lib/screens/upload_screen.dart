import 'package:flutter/material.dart';
import 'dart:io';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import '../theme/app_theme.dart';
import '../widgets/bottom_nav_bar.dart';
import '../widgets/category_card.dart';
import '../providers/supabase_provider.dart';
import '../services/supabase_service.dart';
import '../main.dart' show AppRoutes;

class UploadScreen extends StatefulWidget {
  const UploadScreen({super.key});

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen>
    with SingleTickerProviderStateMixin {

  // ── State ────────────────────────────────────────────────────
  int     _selectedCategoryIndex = 0;
  bool    _isUploading           = false;
  String? _errorMessage;
  final TextEditingController _itemNameController = TextEditingController();

  // Image picker
  final ImagePicker _imagePicker = ImagePicker();

  // ── Animation ────────────────────────────────────────────────
  late final AnimationController _controller;
  late final Animation<double>    _fadeAnim;
  late final Animation<Offset>    _slideAnim;

  // ── Category definitions ─────────────────────────────────────
  static const List<_CategoryDef> _categories = [
    _CategoryDef(emoji: '👕', label: 'Tops'),
    _CategoryDef(emoji: '👖', label: 'Bottoms'),
    _CategoryDef(emoji: '👟', label: 'Shoes'),
    _CategoryDef(emoji: '🧥', label: 'Jackets'),
    _CategoryDef(emoji: '👗', label: 'Dresses'),
    _CategoryDef(emoji: '⌚', label: 'Accessories'),
  ];

  @override
  void initState() {
    super.initState();

    // ── Animation setup ──────────────────────────────────────
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

    // ── Load wardrobe on open ────────────────────────────────
    // FIX: بدون ده الـ items list هتبقى فاضية دايمًا
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final userId = SupabaseService().currentUserId;
      if (userId != null && mounted) {
        context.read<WardrobeProvider>().loadWardrobe(userId);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _itemNameController.dispose();
    super.dispose();
  }

  void _handleBackTap() {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
      return;
    }
    navigator.pushReplacementNamed(AppRoutes.home);
  }

  // ── Helpers ──────────────────────────────────────────────────

  /// Items sorted newest-first for the "Recently Added" section
  List<Map<String, dynamic>> get _recentItems {
    final items = context.watch<WardrobeProvider>().items;
    final sorted = [...items]
      ..sort((a, b) {
        final aDate = DateTime.parse(
            a['added_at'] as String? ?? DateTime.now().toIso8601String());
        final bDate = DateTime.parse(
            b['added_at'] as String? ?? DateTime.now().toIso8601String());
        return bDate.compareTo(aDate);
      });
    return sorted.take(5).toList();
  }

  Map<String, int> get _counts {
    final items = context.watch<WardrobeProvider>().items;
    final counts = <String, int>{};
    for (final item in items) {
      final category = item['category'] as String? ?? 'Accessories';
      counts[category] = (counts[category] ?? 0) + 1;
    }
    return counts;
  }

  /// Pick image from camera
  Future<void> _handleTakePhoto() async {
    try {
      final name = _itemNameController.text.trim();
      if (name.isEmpty) {
        _showError('Please enter the item name first');
        return;
      }
      final photo =
          await _imagePicker.pickImage(source: ImageSource.camera);
      if (photo != null) {
        await _handleAddItem(imagePath: photo.path, isCamera: true);
      }
    } catch (e) {
      _showError('Failed to take photo: ${e.toString()}');
    }
  }

  /// Pick image from gallery
  Future<void> _handleUploadImage() async {
    try {
      final name = _itemNameController.text.trim();
      if (name.isEmpty) {
        _showError('Please enter the item name first');
        return;
      }
      final image =
          await _imagePicker.pickImage(source: ImageSource.gallery);
      if (image != null) {
        await _handleAddItem(imagePath: image.path, isCamera: false);
      }
    } catch (e) {
      _showError('Failed to upload image: ${e.toString()}');
    }
  }

  /// Add clothing item to wardrobe
  Future<void> _handleAddItem({
    required String imagePath,
    required bool   isCamera,
  }) async {
    // Read provider before async gap
    final wardrobeProvider = context.read<WardrobeProvider>();

    setState(() {
      _isUploading  = true;
      _errorMessage = null;
    });

    try {
      final supabase = SupabaseService();
      final userId   = supabase.currentUserId;

      if (userId == null) {
        _showError('User not authenticated');
        return;
      }

      final category = _categories[_selectedCategoryIndex].label;
      final emoji    = _categories[_selectedCategoryIndex].emoji;
      final itemName = _itemNameController.text.trim();

      // Upload image to Supabase Storage
      final imageUrl = await supabase.uploadImage(
        userId:   userId,
        imagePath: imagePath,
        bucket:  'clothing_images',
      );

      // Add item → provider internally calls loadWardrobe after insert
      await wardrobeProvider.addItem(
        userId:   userId,
        name:     itemName.isNotEmpty
            ? itemName
            : '${isCamera ? 'Camera' : 'Uploaded'} $category',
        category: category,
        emoji:    emoji,
        color:    null,
        imageUrl: imageUrl,
      );

      if (!mounted) return;

      setState(() => _isUploading = false);
      _itemNameController.clear();
      _showSuccess('✅ Item added to $category!');
    } catch (e) {
      _showError('Failed to add item: ${e.toString()}');
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  /// Delete clothing item
  Future<void> _handleDelete(Map<String, dynamic> item) async {
    // Confirm before deleting
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg)),
        title: const Text('Remove Item',
            style: TextStyle(
                fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
        content: Text(
          'Remove "${item['name']}" from your wardrobe?',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Remove',
                style: TextStyle(
                    color: AppColors.error, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      final wardrobeProvider = context.read<WardrobeProvider>();
      final userId           = SupabaseService().currentUserId;

      if (userId != null) {
        await wardrobeProvider.deleteItem(userId, item['id'] as String);

        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${item['name']} removed'),
            backgroundColor: AppColors.textSecondary,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.sm)),
          ),
        );
      }
    } catch (e) {
      _showError('Failed to delete item: ${e.toString()}');
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
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm)),
      ),
    );
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content:         Text(message),
        backgroundColor: AppColors.primary,
        behavior:        SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm)),
      ),
    );
  }

  // ── Build ────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final isLoadingWardrobe = context.watch<WardrobeProvider>().isLoading;

    return Scaffold(
      backgroundColor: AppColors.background,

      // ── AppBar ───────────────────────────────────────────────
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation:       0,
        leading: GestureDetector(
          onTap: _handleBackTap,
          child: Container(
            margin: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color:        AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              boxShadow: [
                BoxShadow(
                  color:      Colors.black.withValues(alpha: 0.05),
                  blurRadius: 8,
                  offset:     const Offset(0, 2),
                ),
              ],
            ),
            child: const Icon(Icons.arrow_back_ios_new_rounded,
                size: 18, color: AppColors.textPrimary),
          ),
        ),
        title: const Text(
          'Upload Clothes',
          style: TextStyle(
              fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
        ),
      ),

      // ── Body ─────────────────────────────────────────────────
      body: SlideTransition(
        position: _slideAnim,
        child: FadeTransition(
          opacity: _fadeAnim,
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: AppSpacing.md),

                // ── Error banner ──────────────────────────────
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
                        Expanded(
                          child: Text(_errorMessage!,
                              style: TextStyle(
                                  color: AppColors.error, fontSize: 13)),
                        ),
                      ]),
                    ),
                  ),

                // ── Item name input ────────────────────────────
                const _SectionHeader(title: 'Item Name'),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: _itemNameController,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    hintText: 'e.g. White Linen Shirt',
                    filled: true,
                    fillColor: AppColors.surface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      borderSide: BorderSide(color: AppColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      borderSide: BorderSide(color: AppColors.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      borderSide: BorderSide(color: AppColors.primary, width: 1.5),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),

                // ── Upload area card ──────────────────────────
                _UploadAreaCard(
                  isUploading: _isUploading,
                  onTakePhoto: _isUploading ? null : _handleTakePhoto,
                  onUpload:    _isUploading ? null : _handleUploadImage,
                ),
                const SizedBox(height: AppSpacing.lg),

                // ── Categories section ────────────────────────
                const _SectionHeader(title: 'Categories'),
                const SizedBox(height: AppSpacing.sm + 2),
                SizedBox(
                  height: 118,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    physics:         const BouncingScrollPhysics(),
                    itemCount:       _categories.length,
                    itemBuilder: (context, i) {
                      final cat = _categories[i];
                      return CategoryCard(
                        emoji:      cat.emoji,
                        label:      cat.label,
                        itemCount:  _counts[cat.label] ?? 0,
                        isSelected: i == _selectedCategoryIndex,
                        onTap: () =>
                            setState(() => _selectedCategoryIndex = i),
                      );
                    },
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),

                // ── Recently Added section ────────────────────
                _SectionHeader(
                  title: 'Recently Added',
                  trailing: Text(
                    '${_recentItems.length} items',
                    style: AppTextStyles.bodySmall,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm + 2),

                // Loading state
                if (isLoadingWardrobe)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Center(
                      child: CircularProgressIndicator(
                          color: AppColors.primary, strokeWidth: 2.5),
                    ),
                  )
                else if (_recentItems.isEmpty)
                  _EmptyRecentState()
                else
                  ListView.builder(
                    shrinkWrap: true,
                    physics:    const NeverScrollableScrollPhysics(),
                    itemCount:  _recentItems.length,
                    itemBuilder: (context, i) {
                      final item = _recentItems[i];
                      return Container(
                        margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                        padding: const EdgeInsets.all(AppSpacing.md),
                        decoration: BoxDecoration(
                          color:        AppColors.surface,
                          borderRadius: BorderRadius.circular(AppRadius.md),
                          boxShadow: [
                            BoxShadow(
                              color:      Colors.black.withValues(alpha: 0.03),
                              blurRadius: 8,
                              offset:     const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            // Image thumbnail (fallback to emoji)
                            _RecentItemThumb(item: item),
                            const SizedBox(width: AppSpacing.md),

                            // Name + category
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item['name'] as String? ?? 'Item',
                                    style: const TextStyle(
                                      fontSize:   14,
                                      fontWeight: FontWeight.w600,
                                      color:      AppColors.textPrimary,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    item['category'] as String? ?? 'Unknown',
                                    style: AppTextStyles.bodySmall,
                                  ),
                                ],
                              ),
                            ),

                            // Delete button
                            GestureDetector(
                              onTap: () => _handleDelete(item),
                              child: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color:        AppColors.error.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(AppRadius.sm),
                                ),
                                child: Icon(Icons.delete_outline_rounded,
                                    size: 18, color: AppColors.error),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),

                const SizedBox(height: AppSpacing.xxl),
              ],
            ),
          ),
        ),
      ),

      // ── Bottom Navigation Bar ─────────────────────────────────
      bottomNavigationBar: const AppBottomNavBar(currentIndex: 1),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// Upload Area Card
// ─────────────────────────────────────────────────────────────────
class _UploadAreaCard extends StatelessWidget {
  final bool          isUploading;
  final VoidCallback? onTakePhoto;
  final VoidCallback? onUpload;

  const _UploadAreaCard({
    required this.isUploading,
    required this.onTakePhoto,
    required this.onUpload,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width:   double.infinity,
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color:        AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border:       Border.all(color: AppColors.border, width: 1.5),
        boxShadow: [
          BoxShadow(
            color:      Colors.black.withValues(alpha: 0.04),
            blurRadius: 12,
            offset:     const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          // Icon
          Container(
            width:  68,
            height: 68,
            decoration: BoxDecoration(
              color:        AppColors.primarySoft,
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            child: isUploading
                ? const Center(
                    child: SizedBox(
                      width:  28,
                      height: 28,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.5, color: AppColors.primary),
                    ),
                  )
                : const Icon(Icons.add_photo_alternate_outlined,
                    size: 34, color: AppColors.primary),
          ),
          const SizedBox(height: AppSpacing.md),

          // Caption
          Text(
            isUploading
                ? 'Processing your item…'
                : 'Add a new clothing item to your wardrobe',
            style: const TextStyle(
              fontSize:   13,
              color:      AppColors.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.md),

          // Buttons
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 46,
                  child: ElevatedButton.icon(
                    onPressed: onTakePhoto,
                    icon:  const Icon(Icons.camera_alt_outlined, size: 18),
                    label: const Text('Take Photo'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor:         AppColors.primary,
                      disabledBackgroundColor: AppColors.primary.withValues(alpha: 0.6),
                      foregroundColor:         Colors.white,
                      textStyle: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadius.md)),
                      elevation: 0,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: SizedBox(
                  height: 46,
                  child: OutlinedButton.icon(
                    onPressed: onUpload,
                    icon:  const Icon(Icons.upload_rounded, size: 18),
                    label: const Text('Upload'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor:         AppColors.primary,
                      disabledForegroundColor: AppColors.primary.withValues(alpha: 0.6),
                      side: BorderSide(
                        color: AppColors.primary.withValues(
                            alpha: onUpload == null ? 0.6 : 1),
                        width: 1.5,
                      ),
                      textStyle: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadius.md)),
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

// ─────────────────────────────────────────────────────────────────
// Section Header
// ─────────────────────────────────────────────────────────────────
class _SectionHeader extends StatelessWidget {
  final String  title;
  final Widget? trailing;
  const _SectionHeader({required this.title, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(title,
            style: const TextStyle(
                fontSize:   17,
                fontWeight: FontWeight.w700,
                color:      AppColors.textPrimary)),
        ?trailing,
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// Empty state
// ─────────────────────────────────────────────────────────────────
class _EmptyRecentState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width:   double.infinity,
      padding: const EdgeInsets.all(AppSpacing.xl),
      decoration: BoxDecoration(
        color:        AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color:        AppColors.primarySoft,
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            child: const Icon(Icons.checkroom_outlined,
                size: 36, color: AppColors.primary),
          ),
          const SizedBox(height: AppSpacing.md),
          const Text('No items yet',
              style: TextStyle(
                  fontSize:   15,
                  fontWeight: FontWeight.w600,
                  color:      AppColors.textPrimary)),
          const SizedBox(height: 4),
          const Text(
            'Take a photo or upload an image\nto add your first item',
            style:     AppTextStyles.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// Category definition model
// ─────────────────────────────────────────────────────────────────
class _CategoryDef {
  final String emoji;
  final String label;
  const _CategoryDef({required this.emoji, required this.label});
}

// Recently added thumbnail
class _RecentItemThumb extends StatelessWidget {
  final Map<String, dynamic> item;
  const _RecentItemThumb({required this.item});

  @override
  Widget build(BuildContext context) {
    final imageUrl = item['image_url'] as String?;
    final imagePath = item['image_path'] as String?;
    final emoji = item['emoji'] as String? ?? '👕';

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        width: 44,
        height: 44,
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
