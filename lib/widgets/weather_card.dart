import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Weather summary card - warm, soft card with subtle shadow.
class WeatherCard extends StatelessWidget {
  final String temperature;
  final String? location;
  final String condition;
  final String tip;
  final IconData weatherIcon;

  const WeatherCard({
    super.key,
    this.temperature = '24°C',
    this.location,
    this.condition = 'Mostly Sunny',
    this.tip = 'Perfect day for a light top!',
    this.weatherIcon = Icons.wb_sunny_rounded,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          // Sun icon tile
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFFFBE9C8),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              weatherIcon,
              color: const Color(0xFFF2B457),
              size: 26,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (location != null && location!.trim().isNotEmpty) ...[
                  Text(
                    location!,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF7A6B55),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                ],
                Text(
                  temperature,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF1C1C1C),
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  condition,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF5A5A5A),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  tip,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
