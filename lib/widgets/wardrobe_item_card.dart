import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../models/clothing_item.dart';

/// Single item card displayed in the 3-column wardrobe grid.
/// Tapping it triggers [onTap] which opens the detail bottom sheet.
class WardrobeItemCard extends StatelessWidget {
  final ClothingItem item;
  final VoidCallback onTap;

  const WardrobeItemCard({
    super.key,
    required this.item,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color:        AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          boxShadow: [
            BoxShadow(
              color:      Colors.black.withValues(alpha: 0.04),
              blurRadius: 10,
              offset:     const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // ── Emoji thumbnail ──────────────────────────────
            Expanded(
              flex: 3,
              child: Container(
                margin: const EdgeInsets.fromLTRB(
                  AppSpacing.sm,
                  AppSpacing.sm,
                  AppSpacing.sm,
                  AppSpacing.xs,
                ),
                decoration: BoxDecoration(
                  color:        _bgColorFor(item.category),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                alignment: Alignment.center,
                child: Text(
                  item.emoji,
                  style: const TextStyle(fontSize: 34),
                ),
              ),
            ),

            // ── Name + category ──────────────────────────────
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical:   AppSpacing.xs,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      item.name,
                      style: const TextStyle(
                        fontSize:   11,
                        fontWeight: FontWeight.w700,
                        color:      AppColors.textPrimary,
                        height:     1.2,
                      ),
                      textAlign: TextAlign.center,
                      maxLines:  2,
                      overflow:  TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.category,
                      style: const TextStyle(
                        fontSize:   10,
                        fontWeight: FontWeight.w400,
                        color:      AppColors.textSecondary,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Returns a soft background tint based on clothing category
  Color _bgColorFor(String category) {
    switch (category) {
      case ClothingItem.catTops:    return const Color(0xFFEEF2FF);
      case ClothingItem.catBottoms: return const Color(0xFFF0F7FF);
      case ClothingItem.catShoes:   return const Color(0xFFF5F0FF);
      case ClothingItem.catJackets: return const Color(0xFFFFF8EE);
      case ClothingItem.catDresses: return const Color(0xFFFFF0F5);
      case ClothingItem.catAcc:     return const Color(0xFFF0FFF4);
      default:                      return AppColors.surfaceAlt;
    }
  }
}
