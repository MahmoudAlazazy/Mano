import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mano/providers/supabase_provider.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../services/supabase_service.dart';
import '../widgets/bottom_nav_bar.dart';
import '../main.dart' show AppRoutes;

class WardrobeScreen extends StatefulWidget {
  const WardrobeScreen({super.key});

  @override
  State<WardrobeScreen> createState() => _WardrobeScreenState();
}

class _WardrobeScreenState extends State<WardrobeScreen>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {

  String _selectedFilter = 'All';

  // ── Animation ────────────────────────────────────────────────
  late final AnimationController _controller;
  late final Animation<double>    _fadeAnim;
  late final Animation<Offset>    _slideAnim;

  // ── Category definitions ─────────────────────────────────────
  static const List<String> _categories = [
    'All',
    'Tops',
    'Bottoms',
    'Shoes',
    'Jackets',
    'Dresses',
    'Accessories',
  ];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();

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

  // ── Detail bottom sheet ──────────────────────────────────────
  Future<void> _showItemDetail(Map<String, dynamic> item) async {
    await showModalBottomSheet(
      context:           context,
      isScrollControlled: true,
      backgroundColor:   Colors.transparent,
      builder:           (_) => _ItemDetailSheet(
        item: item,
        onDelete: () async {
          Navigator.pop(context);
          
          final supabase = SupabaseService();
          final userId = supabase.currentUserId;
          
          if (userId != null) {
            final wardrobeProvider = context.read<WardrobeProvider>();
            await wardrobeProvider.deleteItem(userId, item['id'] as String);
            
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content:         Text('${item['name']} removed'),
                  backgroundColor: AppColors.primary,
                  behavior:        SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                ),
              );
            }
          }
        },
        onWearToday: () async {
          Navigator.pop(context);
          
          final supabase = SupabaseService();
          final userId = supabase.currentUserId;
          
          if (userId != null) {
            final statsProvider = context.read<StatsProvider>();
            await statsProvider.recordItemWear(
              userId: userId,
              clothingItemId: item['id'] as String,
            );
            
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Row(
                    children: [
                      Icon(Icons.check_circle, color: Colors.white),
                      SizedBox(width: AppSpacing.sm),
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
            }
          }
        },
      ),
    );
  }

  // ── Build ────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Consumer<WardrobeProvider>(
      builder: (context, wardrobe, child) {
        final items = wardrobe.items;
        final filtered = _selectedFilter == 'All' 
            ? items 
            : items.where((e) => e['category'] == _selectedFilter).toList();
        final itemCount = items.length;

        if (wardrobe.isLoading) {
          return Scaffold(
            backgroundColor: AppColors.background,
            body: const Center(child: CircularProgressIndicator()),
          );
        }

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
                child: const Icon(
                  Icons.arrow_back_ios_new_rounded,
                  size:  18,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            title: const Text(
              'My Wardrobe',
              style: TextStyle(
                fontSize:   18,
                fontWeight: FontWeight.w700,
                color:      AppColors.textPrimary,
              ),
            ),
            actions: [
              // Item count badge
              Container(
                margin: const EdgeInsets.only(right: AppSpacing.md),
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical:   AppSpacing.xs + 2,
                ),
                decoration: BoxDecoration(
                  color:        AppColors.primarySoft,
                  borderRadius: BorderRadius.circular(AppRadius.full),
                ),
                child: Text(
                  '$itemCount items',
                  style: const TextStyle(
                    fontSize:   12,
                    fontWeight: FontWeight.w600,
                    color:      AppColors.primary,
                  ),
                ),
              ),
            ],
          ),

          // ── Body ─────────────────────────────────────────────────
          body: RefreshIndicator(
            onRefresh: () async {
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
                    const SizedBox(height: AppSpacing.sm),

                    // ── Filter chips row ──────────────────────────
                    _FilterChipRow(
                      filters:        _categories,
                      selectedFilter: _selectedFilter,
                      onSelect: (f) => setState(() => _selectedFilter = f),
                    ),
                    const SizedBox(height: AppSpacing.md),

                    // ── Grid or empty state ───────────────────────
                    Expanded(
                      child: filtered.isEmpty
                          ? _EmptyFilterState(filter: _selectedFilter)
                          : GridView.builder(
                              physics: const BouncingScrollPhysics(),
                              padding: const EdgeInsets.fromLTRB(
                                AppSpacing.md,
                                0,
                                AppSpacing.md,
                                AppSpacing.xxl,
                              ),
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount:   3,
                                mainAxisSpacing:  AppSpacing.sm,
                                crossAxisSpacing: AppSpacing.sm,
                                childAspectRatio: 0.78,
                              ),
                              itemCount:   filtered.length,
                              itemBuilder: (context, i) {
                                final item = filtered[i];
                                return _WardrobeItemCard(
                                  item:  item,
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

          // ── Bottom Navigation Bar ─────────────────────────────────
          bottomNavigationBar: const AppBottomNavBar(currentIndex: 2),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// Wardrobe Item Card
// ─────────────────────────────────────────────────────────────────
class _WardrobeItemCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final VoidCallback onTap;

  const _WardrobeItemCard({
    required this.item,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final emoji = item['emoji'] as String? ?? '👕';
    final name = item['name'] as String? ?? 'Item';
    final isFavorite = item['is_favorite'] as bool? ?? false;
    final imageUrl = item['image_url'] as String?;
    final imagePath = item['image_path'] as String?;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.md),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Stack(
          children: [
            // Main content
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  height: 96,
                  width: double.infinity,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    child: _WardrobeImage(
                      imageUrl: imageUrl,
                      imagePath: imagePath,
                      emoji: emoji,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                  child: Text(
                    name,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),

            // Favorite badge
            if (isFavorite)
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    shape: BoxShape.circle,
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
    );
  }
}

// ─────────────────────────────────────────────────────────────────
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
        errorBuilder: (_, _, _) => _emojiFallback(),
      );
    }

    if (imagePath != null && imagePath!.isNotEmpty) {
      if (imagePath!.startsWith('http')) {
        return Image.network(
          imagePath!,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          errorBuilder: (_, _, _) => _emojiFallback(),
        );
      } else {
        return Image.file(
          File(imagePath!),
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          errorBuilder: (_, _, _) => _emojiFallback(),
        );
      }
    }

    return _emojiFallback();
  }

  Widget _emojiFallback() {
    return Container(
      color: const Color(0xFFF5F1EC),
      alignment: Alignment.center,
      child: Text(
        emoji,
        style: const TextStyle(fontSize: 32),
      ),
    );
  }
}

// Filter Chip Row
// ─────────────────────────────────────────────────────────────────
class _FilterChipRow extends StatelessWidget {
  final List<String> filters;
  final String       selectedFilter;
  final ValueChanged<String> onSelect;

  const _FilterChipRow({
    required this.filters,
    required this.selectedFilter,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics:         const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        itemCount:   filters.length,
        itemBuilder: (context, i) {
          final filter     = filters[i];
          final isSelected = filter == selectedFilter;
          return GestureDetector(
            onTap: () => onSelect(filter),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve:    Curves.easeOut,
              margin:   const EdgeInsets.only(right: AppSpacing.sm),
              padding:  const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical:   AppSpacing.xs + 2,
              ),
              decoration: BoxDecoration(
                color: isSelected ? AppColors.primary : AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadius.full),
                border: Border.all(
                  color: isSelected ? AppColors.primary : AppColors.border,
                  width: 1.5,
                ),
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color:      AppColors.primary.withValues(alpha: 0.25),
                          blurRadius: 8,
                          offset:     const Offset(0, 2),
                        ),
                      ]
                    : [],
              ),
              child: Text(
                filter,
                style: TextStyle(
                  fontSize:   13,
                  fontWeight: FontWeight.w600,
                  color: isSelected ? Colors.white : AppColors.textPrimary,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// Item Detail Bottom Sheet
// ─────────────────────────────────────────────────────────────────
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
    final emoji = item['emoji'] as String? ?? '👕';
    final name = item['name'] as String? ?? 'Item';
    final category = item['category'] as String? ?? 'Unknown';

    return Container(
      decoration: const BoxDecoration(
        color:        AppColors.surface,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.xl),
        ),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
        left:   AppSpacing.lg,
        right:  AppSpacing.lg,
        top:    AppSpacing.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Drag handle ──────────────────────────────────────
          Container(
            width:  40,
            height: 4,
            decoration: BoxDecoration(
              color:        AppColors.border,
              borderRadius: BorderRadius.circular(AppRadius.full),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          // ── Large emoji ──────────────────────────────────────
          Container(
            width:  100,
            height: 100,
            decoration: BoxDecoration(
              color:        AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(AppRadius.xl),
            ),
            alignment: Alignment.center,
            child: Text(emoji, style: const TextStyle(fontSize: 52)),
          ),
          const SizedBox(height: AppSpacing.md),

          // ── Name ─────────────────────────────────────────────
          Text(
            name,
            style: AppTextStyles.headlineLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.xs),

          // ── Category chip ────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical:   AppSpacing.xs,
            ),
            decoration: BoxDecoration(
              color:        AppColors.primarySoft,
              borderRadius: BorderRadius.circular(AppRadius.full),
            ),
            child: Text(
              category,
              style: const TextStyle(
                fontSize:   12,
                fontWeight: FontWeight.w600,
                color:      AppColors.primary,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          // ── Action buttons ───────────────────────────────────
          Row(
            children: [
              // Wear Today
              Expanded(
                child: SizedBox(
                  height: 50,
                  child: ElevatedButton.icon(
                    onPressed: onWearToday,
                    icon:  const Icon(Icons.checkroom_rounded, size: 18),
                    label: const Text('Wear Today'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      elevation:       0,
                      textStyle: const TextStyle(
                        fontSize:   13,
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

              // Delete
              SizedBox(
                height: 50,
                width:  50,
                child: OutlinedButton(
                  onPressed: onDelete,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.error,
                    side: BorderSide(color: AppColors.error.withValues(alpha: 0.5)),
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

// ─────────────────────────────────────────────────────────────────
// Empty state when filter returns no results
// ─────────────────────────────────────────────────────────────────
class _EmptyFilterState extends StatelessWidget {
  final String filter;
  const _EmptyFilterState({required this.filter});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              color:        AppColors.primarySoft,
              borderRadius: BorderRadius.circular(AppRadius.xl),
            ),
            child: const Icon(
              Icons.search_off_rounded,
              size:  48,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            'No $filter items yet',
            style: AppTextStyles.headlineSmall,
          ),
          const SizedBox(height: AppSpacing.xs),
          const Text(
            'Upload some clothes to get started',
            style: AppTextStyles.bodyMedium,
          ),
        ],
      ),
    );
  }
}
