import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Selectable recommendation-type card used in the Get Outfit screen.
/// Shows an icon, bold title, and description. Highlights when selected.
class OutfitOptionCard extends StatelessWidget {
  final IconData icon;
  final String   title;
  final String   description;
  final bool     isSelected;
  final VoidCallback onTap;

  const OutfitOptionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve:    Curves.easeOut,
        padding:  const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primary.withValues(alpha: 0.06)
              : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(
            color: isSelected ? AppColors.primary : AppColors.border,
            width: isSelected ? 2.0 : 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color:      Colors.black.withValues(alpha: isSelected ? 0.06 : 0.03),
              blurRadius: 12,
              offset:     const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            // ── Icon circle ────────────────────────────────────
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width:  48,
              height: 48,
              decoration: BoxDecoration(
                color: isSelected
                    ? AppColors.primarySoft
                    : AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(AppRadius.full),
              ),
              child: Icon(
                icon,
                size:  24,
                color: isSelected
                    ? AppColors.primary
                    : AppColors.textSecondary,
              ),
            ),
            const SizedBox(width: AppSpacing.md),

            // ── Text column ────────────────────────────────────
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize:   15,
                      fontWeight: FontWeight.w700,
                      color: isSelected
                          ? AppColors.primary
                          : AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    description,
                    style: AppTextStyles.bodySmall,
                  ),
                ],
              ),
            ),

            // ── Selection indicator ────────────────────────────
            AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity:  isSelected ? 1.0 : 0.0,
              child: Container(
                width:  22,
                height: 22,
                decoration: const BoxDecoration(
                  color:  AppColors.primary,
                  shape:  BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check_rounded,
                  size:  14,
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
