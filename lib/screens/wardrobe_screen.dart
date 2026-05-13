import 'dart:io';

import 'package:flutter/material.dart';
import 'package:outfitadvisor/providers/supabase_provider.dart';
import 'package:provider/provider.dart';

import '../main.dart' show AppRoutes;
import '../services/supabase_service.dart';
import '../theme/app_theme.dart';
import '../widgets/bottom_nav_bar.dart';

/// Displays the user's full wardrobe as a filterable grid.
/// Supports pull-to-refresh, category filtering, and tapping an item to
/// view its detail sheet where it can be worn or deleted.
class WardrobeScreen extends StatefulWidget {
  const WardrobeScreen({super.key});

  @override
  State<WardrobeScreen> createState() => _WardrobeScreenState();
}

class _WardrobeScreenState extends State<WardrobeScreen>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  /// The currently active category filter; 'All' shows every item.
  String _selectedFilter = 'All';

  // Animation controller for the screen's fade + slide entrance.
  late final AnimationController _controller;
  late final Animation<double> _fadeAnim;
  late final Animation<Offset> _slideAnim;

  /// Ordered list of category filter labels shown in the chip row.
  static const List<String> _categories = [
    'All',
    'Tops',
    'Bottoms',
    'Shoes',
    'Jackets',
    'Dresses',
    'Accessories',
  ];

  /// Maps each category label to its representative emoji icon.
  static const Map<String, String> _categoryIcons = {
    'All': '🧺',
    'Tops': '👕',
    'Bottoms': '👖',
    'Shoes': '👟',
    'Jackets': '🧥',
    'Dresses': '👗',
    'Accessories': '⌚',
  };

  /// Keep this tab alive in a [PageView] so scroll position is preserved.
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();

    // Set up a short fade + upward-slide entrance animation.
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _fadeAnim = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.05),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    // Small delay before starting the animation so the first frame settles.
    Future.delayed(
      const Duration(milliseconds: 80),
      () {
        if (mounted) _controller.forward();
      },
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Navigates back, falling back to the home route if the stack is empty.
  void _handleBackTap() {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
      return;
    }
    navigator.pushReplacementNamed(AppRoutes.home);
  }

  /// Opens a bottom sheet with full item details.
  ///
  /// The sheet exposes two actions:
  /// - **Wear Today** — records a wear event via [StatsProvider].
  /// - **Delete** — asks for confirmation then removes the item from the
  ///   wardrobe via [WardrobeProvider].
  Future<void> _showItemDetail(Map<String, dynamic> item) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ItemDetailSheet(
        item: item,
        onDelete: () async {
          // Ask the user to confirm before permanently deleting the item.
          final shouldDelete = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              title: const Text('Delete Item'),
              content: Text(
                'Are you sure you want to delete "${item['name']}"?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.error,
                  ),
                  child: const Text('Delete'),
                ),
              ],
            ),
          );

          if (shouldDelete != true) return;

          // Close the bottom sheet before performing the async delete.
          if (!context.mounted) return;
          Navigator.pop(context);

          final supabase = SupabaseService();
          final userId = supabase.currentUserId;
          if (userId == null) return;

          try {
            final wardrobeProvider = context.read<WardrobeProvider>();
            await wardrobeProvider.deleteItem(userId, item['id'] as String);

            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('${item['name']} removed'),
                backgroundColor: AppColors.primary,
                behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
              ),
            );
          } catch (e) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Failed to delete: $e'),
                backgroundColor: AppColors.error,
                behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
              ),
            );
          }
        },
        onWearToday: () async {
          // Close the sheet then record the wear event for stats tracking.
          Navigator.pop(context);

          final supabase = SupabaseService();
          final userId = supabase.currentUserId;
          if (userId == null) return;

          final statsProvider = context.read<StatsProvider>();
          await statsProvider.recordItemWear(
            userId: userId,
            clothingItemId: item['id'] as String,
          );

          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.white),
                  const SizedBox(width: AppSpacing.sm),
                  Text('${item['name']} - wore today!'),
                ],
              ),
              backgroundColor: Colors.green,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Required when using AutomaticKeepAliveClientMixin.
    super.build(context);

    return Consumer<WardrobeProvider>(
      builder: (context, wardrobe, child) {
        final items = wardrobe.items;

        // Apply the active category filter; 'All' bypasses filtering.
        final filtered = _selectedFilter == 'All'
            ? items
            : items.where((e) => e['category'] == _selectedFilter).toList();
        final itemCount = items.length;
        final viewportWidth = MediaQuery.of(context).size.width;

        // Use 3 columns on wider screens (tablets / landscape), 2 on phones.
        final crossAxisCount = viewportWidth >= 540 ? 3 : 2;
        final childAspectRatio = viewportWidth >= 540 ? 0.72 : 0.76;

        // Show a full-screen spinner while the initial wardrobe load is in progress.
        if (wardrobe.isLoading) {
          return const Scaffold(
            backgroundColor: AppColors.background,
            body: Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            ),
          );
        }

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
              'My Wardrobe',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            // Pill badge showing the total number of items across all categories.
            actions: [
              Container(
                margin: const EdgeInsets.only(right: AppSpacing.md),
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.xs + 2,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primarySoft,
                  borderRadius: BorderRadius.circular(AppRadius.full),
                  border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.15),
                  ),
                ),
                child: Text(
                  '$itemCount items',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primary,
                  ),
                ),
              ),
            ],
          ),
          body: RefreshIndicator(
            color: AppColors.primary,
            onRefresh: () async {
              // Re-fetch the wardrobe from Supabase on pull-to-refresh.
              final supabase = SupabaseService();
              final userId = supabase.currentUserId;
              if (userId != null) {
                await context.read<WardrobeProvider>().loadWardrobe(userId);
              }
            },
            child: SlideTransition(
              position: _slideAnim,
              child: FadeTransition(
                opacity: _fadeAnim,
                child: Column(
                  children: [
                    const SizedBox(height: AppSpacing.md),
                    // Horizontally scrollable category filter chips.
                    _FilterChipRow(
                      filters: _categories,
                      categoryIcons: _categoryIcons,
                      selectedFilter: _selectedFilter,
                      onSelect: (f) => setState(() => _selectedFilter = f),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Expanded(
                      child: filtered.isEmpty
                          ? _EmptyFilterState(
                              filter: _selectedFilter,
                              emoji: _categoryIcons[_selectedFilter] ?? '🧥',
                            )
                          : GridView.builder(
                              physics: const BouncingScrollPhysics(
                                parent: AlwaysScrollableScrollPhysics(),
                              ),
                              padding: const EdgeInsets.fromLTRB(
                                AppSpacing.md,
                                0,
                                AppSpacing.md,
                                AppSpacing.xxl,
                              ),
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: crossAxisCount,
                                mainAxisSpacing: AppSpacing.sm,
                                crossAxisSpacing: AppSpacing.sm,
                                childAspectRatio: childAspectRatio,
                              ),
                              itemCount: filtered.length,
                              itemBuilder: (context, i) {
                                final item = filtered[i];
                                return _WardrobeItemCard(
                                  item: item,
                                  onTap: () => _showItemDetail(item),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          bottomNavigationBar: const AppBottomNavBar(currentIndex: 2),
        );
      },
    );
  }
}

/// Grid card representing a single wardrobe item.
/// Shows the item image (or emoji fallback), category label, favorite badge,
/// item name, and wear count.
class _WardrobeItemCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final VoidCallback onTap;

  const _WardrobeItemCard({
    required this.item,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Safely extract and normalise all display fields with sensible defaults.
    final emoji = item['emoji']?.toString().trim().isNotEmpty == true
        ? item['emoji']?.toString().trim() ?? '👕'
        : '👕';
    final name = item['name']?.toString().trim().isNotEmpty == true
        ? item['name']?.toString().trim() ?? 'Item'
        : 'Item';
    final category = item['category']?.toString().trim().isNotEmpty == true
        ? item['category']?.toString().trim() ?? 'Item'
        : 'Item';
    final isFavorite = _toBool(item['is_favorite']);
    final wearCount = _toInt(item['wear_count']);
    final imageUrl = item['image_url'] as String?;
    final imagePath = item['image_path'] as String?;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Ink(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(
              color: AppColors.border.withValues(alpha: 0.8),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  children: [
                    // Full-bleed item image (or emoji placeholder).
                    Positioned.fill(
                      child: ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(AppRadius.lg),
                        ),
                        child: _WardrobeImage(
                          imageUrl: imageUrl,
                          imagePath: imagePath,
                          emoji: emoji,
                        ),
                      ),
                    ),
                    // Subtle bottom gradient to improve text legibility on the image.
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(AppRadius.lg),
                            ),
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Colors.black.withValues(alpha: 0.12),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Category label pill overlaid in the top-left corner.
                    Positioned(
                      top: AppSpacing.xs,
                      left: AppSpacing.xs,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(AppRadius.full),
                        ),
                        child: Text(
                          category,
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                    ),
                    // Favourite heart badge, shown only when the item is marked as favourite.
                    if (isFavorite)
                      Positioned(
                        top: AppSpacing.xs,
                        right: AppSpacing.xs,
                        child: Container(
                          padding: const EdgeInsets.all(5),
                          decoration: BoxDecoration(
                            color: AppColors.primary,
                            borderRadius: BorderRadius.circular(AppRadius.full),
                          ),
                          child: const Icon(
                            Icons.favorite_rounded,
                            size: 12,
                            color: Colors.white,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // Item name and wear count displayed below the image.
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.sm,
                  AppSpacing.sm,
                  AppSpacing.sm,
                  AppSpacing.sm,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        const Icon(
                          Icons.repeat_rounded,
                          size: 13,
                          color: AppColors.textSecondary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          wearCount > 0 ? '$wearCount wears' : 'New item',
                          style: AppTextStyles.labelSmall,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Resolves and displays a wardrobe item's image.
///
/// Priority order:
/// 1. `imageUrl` — remote URL stored in Supabase.
/// 2. `imagePath` — either a remote URL or a local file path.
/// 3. Emoji fallback when no image is available.
///
/// A spinner placeholder is shown while a network image is loading.
class _WardrobeImage extends StatelessWidget {
  final String? imageUrl;
  final String? imagePath;
  final String emoji;

  const _WardrobeImage({
    required this.imageUrl,
    required this.imagePath,
    required this.emoji,
  });

  @override
  Widget build(BuildContext context) {
    if (imageUrl != null && imageUrl!.isNotEmpty) {
      return Image.network(
        imageUrl!,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return _loadingFallback();
        },
        errorBuilder: (_, _, _) => _emojiFallback(),
      );
    }

    if (imagePath != null && imagePath!.isNotEmpty) {
      // Treat paths that start with "http" as remote URLs, otherwise load from disk.
      if (imagePath!.startsWith('http')) {
        return Image.network(
          imagePath!,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return _loadingFallback();
          },
          errorBuilder: (_, _, _) => _emojiFallback(),
        );
      }
      return Image.file(
        File(imagePath!),
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (_, _, _) => _emojiFallback(),
      );
    }

    return _emojiFallback();
  }

  /// Spinner shown while a network image is still downloading.
  Widget _loadingFallback() {
    return Container(
      color: AppColors.surfaceAlt,
      alignment: Alignment.center,
      child: const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(
          strokeWidth: 2.2,
          color: AppColors.primary,
        ),
      ),
    );
  }

  /// Centred emoji shown when no image source is available or loading fails.
  Widget _emojiFallback() {
    return Container(
      color: const Color(0xFFF5F1EC),
      alignment: Alignment.center,
      child: Text(
        emoji,
        style: const TextStyle(fontSize: 34),
      ),
    );
  }
}

/// Horizontally scrollable row of animated category filter chips.
/// The selected chip is filled with the primary colour; others use a
/// bordered outline style.
class _FilterChipRow extends StatelessWidget {
  final List<String> filters;
  final Map<String, String> categoryIcons;
  final String selectedFilter;
  final ValueChanged<String> onSelect;

  const _FilterChipRow({
    required this.filters,
    required this.categoryIcons,
    required this.selectedFilter,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        itemCount: filters.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
        itemBuilder: (context, i) {
          final filter = filters[i];
          final isSelected = filter == selectedFilter;
          final icon = categoryIcons[filter] ?? '•';

          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => onSelect(filter),
              borderRadius: BorderRadius.circular(AppRadius.full),
              // Smoothly animate the background and border when selection changes.
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.xs + 2,
                ),
                decoration: BoxDecoration(
                  color: isSelected ? AppColors.primary : AppColors.surface,
                  borderRadius: BorderRadius.circular(AppRadius.full),
                  border: Border.all(
                    color: isSelected ? AppColors.primary : AppColors.border,
                    width: 1.3,
                  ),
                  // Drop shadow only on the active chip.
                  boxShadow: isSelected
                      ? [
                          BoxShadow(
                            color: AppColors.primary.withValues(alpha: 0.23),
                            blurRadius: 10,
                            offset: const Offset(0, 3),
                          ),
                        ]
                      : null,
                ),
                child: Row(
                  children: [
                    Text(icon, style: const TextStyle(fontSize: 14)),
                    const SizedBox(width: 6),
                    Text(
                      filter,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: isSelected ? Colors.white : AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Modal bottom sheet showing the full details of a wardrobe item.
/// Provides a "Wear Today" button and a delete button.
class _ItemDetailSheet extends StatelessWidget {
  final Map<String, dynamic> item;
  final VoidCallback onDelete;
  final VoidCallback onWearToday;

  const _ItemDetailSheet({
    required this.item,
    required this.onDelete,
    required this.onWearToday,
  });

  @override
  Widget build(BuildContext context) {
    // Safely extract and normalise all display fields with sensible defaults.
    final emoji = item['emoji']?.toString().trim().isNotEmpty == true
        ? item['emoji']?.toString().trim() ?? '👕'
        : '👕';
    final name = item['name']?.toString().trim().isNotEmpty == true
        ? item['name']?.toString().trim() ?? 'Item'
        : 'Item';
    final category = item['category']?.toString().trim().isNotEmpty == true
        ? item['category']?.toString().trim() ?? 'Unknown'
        : 'Unknown';
    final wearCount = _toInt(item['wear_count']);
    final lastWorn = _toDateTime(item['last_worn_at']);
    final isFavorite = _toBool(item['is_favorite']);
    final imageUrl = item['image_url'] as String?;
    final imagePath = item['image_path'] as String?;

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      // Account for the on-screen keyboard height so the sheet isn't obscured.
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: AppSpacing.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle indicator at the top of the sheet.
          Container(
            width: 42,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(AppRadius.full),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          // Large item image preview.
          SizedBox(
            width: 136,
            height: 136,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.border.withValues(alpha: 0.8)),
                ),
                child: _WardrobeImage(
                  imageUrl: imageUrl,
                  imagePath: imagePath,
                  emoji: emoji,
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          // Item name with an inline favourite heart when applicable.
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  name,
                  style: AppTextStyles.headlineLarge,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isFavorite) ...[
                const SizedBox(width: AppSpacing.xs),
                const Icon(
                  Icons.favorite_rounded,
                  color: AppColors.primary,
                  size: 18,
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          // Category pill badge.
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.xs,
            ),
            decoration: BoxDecoration(
              color: AppColors.primarySoft,
              borderRadius: BorderRadius.circular(AppRadius.full),
            ),
            child: Text(
              category,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.primary,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          // Meta chips: wear count and last-worn date (if available).
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            alignment: WrapAlignment.center,
            children: [
              _DetailMetaChip(
                icon: Icons.repeat_rounded,
                label: wearCount > 0 ? '$wearCount wears' : 'Not worn yet',
              ),
              if (lastWorn != null)
                _DetailMetaChip(
                  icon: Icons.calendar_today_rounded,
                  label: 'Last worn ${_formatShortDate(lastWorn)}',
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          // Action row: "Wear Today" primary button and a compact delete button.
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 50,
                  child: ElevatedButton.icon(
                    onPressed: onWearToday,
                    icon: const Icon(Icons.checkroom_rounded, size: 18),
                    label: const Text('Wear Today'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      textStyle: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              SizedBox(
                height: 50,
                width: 50,
                child: OutlinedButton(
                  onPressed: onDelete,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.error,
                    side: BorderSide(
                      color: AppColors.error.withValues(alpha: 0.5),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    padding: EdgeInsets.zero,
                  ),
                  child: const Icon(
                    Icons.delete_outline_rounded,
                    size: 20,
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

/// A small pill-shaped chip pairing an [icon] with a text [label].
/// Used in the item detail sheet to display wear count and last-worn date.
class _DetailMetaChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _DetailMetaChip({
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs + 2,
      ),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(AppRadius.full),
        border: Border.all(color: AppColors.border.withValues(alpha: 0.9)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: AppColors.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Placeholder shown when the filtered item list is empty.
/// Adjusts its title and subtitle based on whether 'All' or a specific
/// category is selected.
class _EmptyFilterState extends StatelessWidget {
  final String filter;
  final String emoji;

  const _EmptyFilterState({
    required this.filter,
    required this.emoji,
  });

  @override
  Widget build(BuildContext context) {
    final isAll = filter == 'All';
    final title = isAll ? 'Your wardrobe is empty' : 'No $filter items yet';
    final subtitle = isAll
        ? 'Add your first clothing item from the Upload tab.'
        : 'Try another category or upload a new $filter piece.';

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AppSpacing.xl),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.xl),
            border: Border.all(color: AppColors.border.withValues(alpha: 0.8)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 78,
                height: 78,
                decoration: BoxDecoration(
                  color: AppColors.primarySoft,
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                ),
                alignment: Alignment.center,
                child: Text(
                  emoji,
                  style: const TextStyle(fontSize: 34),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                title,
                style: AppTextStyles.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                subtitle,
                style: AppTextStyles.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Utility helpers ────────────────────────────────────────────────────────

/// Converts a dynamic [value] to bool.
/// Accepts actual booleans, numeric 0/1, and the strings "true" / "1".
bool _toBool(dynamic value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final normalized = value.trim().toLowerCase();
    return normalized == 'true' || normalized == '1';
  }
  return false;
}

/// Converts a dynamic [value] to int.
/// Handles actual ints, other numeric types, and parseable strings;
/// returns 0 for anything else.
int _toInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

/// Converts a dynamic [value] to a nullable [DateTime].
/// Accepts an existing [DateTime] or an ISO-8601 string; returns null
/// for blank or unparseable values.
DateTime? _toDateTime(dynamic value) {
  if (value is DateTime) return value;
  if (value is String && value.trim().isNotEmpty) {
    return DateTime.tryParse(value);
  }
  return null;
}

/// Formats [date] as a short human-readable string, e.g. "7 Apr".
String _formatShortDate(DateTime date) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  final month = months[date.month - 1];
  return '${date.day} $month';
}
