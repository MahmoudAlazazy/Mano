import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Tappable category card used in the Upload screen's horizontal list.
/// Shows an emoji icon, category name, and item count.
class CategoryCard extends StatelessWidget {
  final String   emoji;
  final String   label;
  final int      itemCount;
  final bool     isSelected;
  final VoidCallback onTap;

  const CategoryCard({
    super.key,
    required this.emoji,
    required this.label,
    required this.itemCount,
    this.isSelected = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve:    Curves.easeOut,
        width:    90,
        margin:   const EdgeInsets.only(right: AppSpacing.sm),
        padding:  const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical:   AppSpacing.sm + 2,
        ),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.primary : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(
            color: isSelected ? AppColors.primary : AppColors.border,
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color:      Colors.black.withValues(alpha: isSelected ? 0.10 : 0.04),
              blurRadius: 10,
              offset:     const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // ── Emoji ─────────────────────────────────────────
            Container(
              width:  40,
              height: 40,
              decoration: BoxDecoration(
                color: isSelected
                    ? Colors.white.withValues(alpha: 0.15)
                    : AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              alignment: Alignment.center,
              child: Text(emoji, style: const TextStyle(fontSize: 22)),
            ),
            const SizedBox(height: AppSpacing.xs),

            // ── Category name ─────────────────────────────────
            Text(
              label,
              style: TextStyle(
                fontSize:   12,
                fontWeight: FontWeight.w700,
                color:      isSelected
                    ? Colors.white
                    : AppColors.textPrimary,
              ),
              textAlign: TextAlign.center,
              maxLines:  1,
              overflow:  TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),

            // ── Item count ────────────────────────────────────
            Text(
              '$itemCount items',
              style: TextStyle(
                fontSize:   10,
                fontWeight: FontWeight.w400,
                color: isSelected
                    ? Colors.white.withValues(alpha: 0.80)
                    : AppColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
