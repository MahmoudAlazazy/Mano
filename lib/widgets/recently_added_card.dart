import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../models/clothing_item.dart';

/// Horizontal card showing a recently added clothing item.
/// Used in the "Recently Added" section of the Upload screen.
class RecentlyAddedCard extends StatelessWidget {
  final ClothingItem item;
  final VoidCallback? onDelete;

  const RecentlyAddedCard({
    super.key,
    required this.item,
    this.onDelete,
  });

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 60)  return '${diff.inMinutes}m ago';
    if (diff.inHours   < 24)  return '${diff.inHours}h ago';
    if (diff.inDays    == 1)  return 'Yesterday';
    return '${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
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
      child: Row(
        children: [
          // ── Emoji thumbnail ──────────────────────────────────
          Container(
            width:  54,
            height: 54,
            decoration: BoxDecoration(
              color:        AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            alignment: Alignment.center,
            child: Text(
              item.emoji,
              style: const TextStyle(fontSize: 28),
            ),
          ),
          const SizedBox(width: AppSpacing.md),

          // ── Name + category + time ───────────────────────────
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  style: const TextStyle(
                    fontSize:   14,
                    fontWeight: FontWeight.w700,
                    color:      AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    // Category pill
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical:   2,
                      ),
                      decoration: BoxDecoration(
                        color:        AppColors.primarySoft,
                        borderRadius: BorderRadius.circular(AppRadius.full),
                      ),
                      child: Text(
                        item.category,
                        style: const TextStyle(
                          fontSize:   10,
                          fontWeight: FontWeight.w600,
                          color:      AppColors.primary,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      _timeAgo(item.addedAt),
                      style: AppTextStyles.labelSmall,
                    ),
                  ],
                ),
              ],
            ),
          ),

          // ── Delete button ────────────────────────────────────
          if (onDelete != null)
            IconButton(
              onPressed: onDelete,
              icon: const Icon(
                Icons.delete_outline_rounded,
                color: AppColors.textSecondary,
                size:  20,
              ),
              padding:       EdgeInsets.zero,
              constraints:   const BoxConstraints(),
              splashRadius:  20,
            ),
        ],
      ),
    );
  }
}
