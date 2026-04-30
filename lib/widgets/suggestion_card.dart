import 'dart:typed_data';
import 'package:flutter/material.dart';

/// Clothing suggestion card - compact tile with image and labels.
class SuggestionCard extends StatelessWidget {
  final String name;
  final String category;
  final String? imagePath;
  final Uint8List? imageBytes;
  final String? emoji;

  const SuggestionCard({
    super.key,
    required this.name,
    required this.category,
    this.imagePath,
    this.imageBytes,
    this.emoji,
  });

  @override
  Widget build(BuildContext context) {
    final hasMemoryImage = imageBytes != null && imageBytes!.isNotEmpty;
    final hasImage = imagePath != null && imagePath!.trim().isNotEmpty;
    final isNetworkImage = hasImage &&
        (imagePath!.startsWith('http://') ||
            imagePath!.startsWith('https://'));

    return Container(
      width: 130,
      margin: const EdgeInsets.only(right: 14),
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
        children: [
          // Clothing image
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox.expand(
                  child: hasMemoryImage
                      ? Image.memory(
                          imageBytes!,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          errorBuilder: (_, _, _) => _emojiPlaceholder(),
                        )
                      : hasImage
                      ? (isNetworkImage
                          ? Image.network(
                              imagePath!,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => _emojiPlaceholder(),
                            )
                          : Image.asset(
                              imagePath!,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => _emojiPlaceholder(),
                            ))
                      : _emojiPlaceholder(),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1C1C1C),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  category,
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF9E9E9E),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _emojiPlaceholder() {
    return Container(
      color: const Color(0xFFF5F1EC),
      alignment: Alignment.center,
      child: Text(
        emoji ?? '\u{2728}',
        style: const TextStyle(fontSize: 38),
      ),
    );
  }
}
