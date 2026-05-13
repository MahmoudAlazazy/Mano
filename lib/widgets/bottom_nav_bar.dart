import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../main.dart' show AppRoutes;

/// Shared bottom navigation bar - icon-only, soft iOS-style.
class AppBottomNavBar extends StatelessWidget {
  final int currentIndex;

  const AppBottomNavBar({super.key, required this.currentIndex});

  static const List<_NavItem> _items = [
    _NavItem(label: 'Home', icon: Icons.home_outlined, activeIcon: Icons.home_rounded),
    _NavItem(label: 'Upload', icon: Icons.checkroom_outlined, activeIcon: Icons.checkroom_rounded),
    _NavItem(label: 'Wardrobe', icon: Icons.shopping_bag_outlined, activeIcon: Icons.shopping_bag_rounded),
    _NavItem(label: 'Outfit', icon: Icons.auto_awesome_outlined, activeIcon: Icons.auto_awesome_rounded),
    _NavItem(label: 'Profile', icon: Icons.person_outline_rounded, activeIcon: Icons.person_rounded),
  ];

  static const List<String> _routes = [
    AppRoutes.home,
    AppRoutes.upload,
    AppRoutes.wardrobe,
    AppRoutes.outfit,
    AppRoutes.profile,
  ];

  void _onTap(BuildContext context, int index) {
    if (index == currentIndex) return;
    Navigator.pushReplacementNamed(context, _routes[index]);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(22),
          topRight: Radius.circular(22),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 18,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 60,
          child: Row(
            children: List.generate(_items.length, (i) {
              final item = _items[i];
              final isActive = i == currentIndex;
              return Expanded(
                child: InkWell(
                  onTap: () => _onTap(context, i),
                  borderRadius: BorderRadius.circular(12),
                  splashColor: AppColors.primary.withValues(alpha: 0.08),
                  highlightColor: AppColors.primary.withValues(alpha: 0.04),
                  child: Center(
                    child: Icon(
                      isActive ? item.activeIcon : item.icon,
                      size: 24,
                      color:
                          isActive ? AppColors.primary : AppColors.textSecondary,
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _NavItem {
  final String label;
  final IconData icon;
  final IconData activeIcon;
  const _NavItem({
    required this.label,
    required this.icon,
    required this.activeIcon,
  });
}
