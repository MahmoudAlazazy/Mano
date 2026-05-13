import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Single card in the 2×2 Quick Actions grid.
/// Icon at top, title below, subtitle in grey — white card with soft shadow.
/// Fully responsive with no overflow issues.
class QuickActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const QuickActionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;
    final isTablet = MediaQuery.of(context).size.width >= 600 &&
        MediaQuery.of(context).size.width < 1024;

    // Responsive sizing
    final padding = isMobile ? 10.0 : isTablet ? 12.0 : 14.0;
    final iconSize = isMobile ? 28.0 : isTablet ? 32.0 : 34.0;
    final iconRadius = isMobile ? 9.0 : 10.0;
    final spacing1 = isMobile ? 6.0 : isTablet ? 8.0 : 10.0;
    final spacing2 = isMobile ? 2.0 : 3.0;
    final titleFontSize = isMobile ? 12.0 : 13.0;
    final subtitleFontSize = isMobile ? 10.5 : 11.5;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(padding),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min, // ← KEY FIX: Take minimal space
          children: [
            // ── Icon in rounded container ───────────────────
            Container(
              width: iconSize,
              height: iconSize,
              decoration: BoxDecoration(
                color: AppColors.primarySoft,
                borderRadius: BorderRadius.circular(iconRadius),
              ),
              child: Icon(
                icon,
                color: AppColors.primary,
                size: isMobile ? 16 : 18,
              ),
            ),
            SizedBox(height: spacing1),

            // ── Title (with flexible to prevent overflow) ────
            Flexible(
              child: Text(
                title,
                maxLines: 2, // Allow up to 2 lines
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: titleFontSize,
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFF1C1C1C),
                  height: 1.2,
                ),
              ),
            ),
            SizedBox(height: spacing2),

            // ── Subtitle (with flexible to prevent overflow) ─
            Flexible(
              child: Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: subtitleFontSize,
                  fontWeight: FontWeight.w400,
                  color: const Color(0xFF9E9E9E),
                  height: 1.1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
