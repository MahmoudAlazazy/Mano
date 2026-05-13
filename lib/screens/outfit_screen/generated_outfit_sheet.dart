part of '../outfit_screen.dart';

// Generated Outfit Result Bottom Sheet
// ─────────────────────────────────────────────────────────────────
class _GeneratedOutfitSheet extends StatefulWidget {
  final String modeName;
  final String occasion;
  final List<_OutfitPiece> items;
  final List<Map<String, dynamic>> wardrobeItems;
  final List<String> preselectedIds;
  final bool requireWardrobeSelection;
  final Future<void> Function(List<String>) onSave;

  const _GeneratedOutfitSheet({
    required this.modeName,
    required this.occasion,
    required this.items,
    required this.wardrobeItems,
    required this.preselectedIds,
    required this.requireWardrobeSelection,
    required this.onSave,
  });

  @override
  State<_GeneratedOutfitSheet> createState() => _GeneratedOutfitSheetState();
}

class _GeneratedOutfitSheetState extends State<_GeneratedOutfitSheet> {
  final Set<String> _selectedIds = {};
  String? _errorText;

  Widget _pieceVisual(_OutfitPiece piece) {
    if (piece.imageBytes != null && piece.imageBytes!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(
          piece.imageBytes!,
          width: 32,
          height: 32,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) =>
              Text(piece.emoji, style: const TextStyle(fontSize: 26)),
        ),
      );
    }

    final path = piece.imagePath?.trim();
    if (path != null && path.isNotEmpty) {
      final isNetwork =
          path.startsWith('http://') || path.startsWith('https://');
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: isNetwork
            ? Image.network(
                path,
                width: 32,
                height: 32,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    Text(piece.emoji, style: const TextStyle(fontSize: 26)),
              )
            : Image.asset(
                path,
                width: 32,
                height: 32,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    Text(piece.emoji, style: const TextStyle(fontSize: 26)),
              ),
      );
    }
    return Text(piece.emoji, style: const TextStyle(fontSize: 26));
  }

  @override
  void initState() {
    super.initState();
    if (widget.preselectedIds.isNotEmpty) {
      final validIds = widget.wardrobeItems
          .map((e) => e['id'])
          .whereType<String>()
          .toSet();
      _selectedIds.addAll(
        widget.preselectedIds.where((id) => validIds.contains(id)),
      );
    }
    if (widget.requireWardrobeSelection && widget.wardrobeItems.length == 1) {
      final id = widget.wardrobeItems.first['id'];
      if (id is String) _selectedIds.add(id);
    }
  }

  bool get _needsSelection =>
      widget.requireWardrobeSelection && widget.wardrobeItems.isNotEmpty;

  void _toggleSelect(String id) {
    setState(() {
      _selectedIds.contains(id)
          ? _selectedIds.remove(id)
          : _selectedIds.add(id);
      _errorText = null;
    });
  }

  Future<void> _handleSave() async {
    if (_needsSelection && _selectedIds.isEmpty) {
      setState(() => _errorText = 'Select at least one wardrobe item to link.');
      return;
    }
    await widget.onSave(_selectedIds.toList());
  }

  @override
  Widget build(BuildContext context) {
    final wardrobeItems = widget.wardrobeItems;

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: AppSpacing.md,
      ),
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Drag handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(AppRadius.full),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),

            // Header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: AppColors.primarySoft,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: const Icon(
                    Icons.auto_awesome_rounded,
                    color: AppColors.primary,
                    size: 20,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "Today's Outfit",
                        style: AppTextStyles.headlineSmall,
                      ),
                      Text(
                        '${widget.modeName} • ${widget.occasion}',
                        style: AppTextStyles.bodySmall,
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: const Icon(
                      Icons.refresh_rounded,
                      size: 20,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),

            // Outfit pieces grid
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: AppSpacing.sm,
                crossAxisSpacing: AppSpacing.sm,
                childAspectRatio: 2.4,
              ),
              itemCount: widget.items.length,
              itemBuilder: (context, i) {
                final piece = widget.items[i];
                return Container(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Row(
                    children: [
                      _pieceVisual(piece),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              piece.name,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              piece.category,
                              style: AppTextStyles.labelSmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: AppSpacing.md),

            if (widget.requireWardrobeSelection) ...[
              const Text(
                'Link Items From Your Wardrobe',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),

              if (wardrobeItems.isEmpty)
                Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: const Text(
                    'No wardrobe items yet. You can still save the suggestion.',
                    style: AppTextStyles.bodySmall,
                  ),
                )
              else
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: wardrobeItems.map((item) {
                    final id = item['id'] as String?;
                    final name = item['name'] as String? ?? 'Item';
                    final emoji = item['emoji'] as String? ?? '\u{1F455}';
                    final selected = id != null && _selectedIds.contains(id);
                    return FilterChip(
                      label: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 160),
                        child: Text(
                          '$emoji $name',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      selected: selected,
                      onSelected: id == null ? null : (_) => _toggleSelect(id),
                      selectedColor: AppColors.primary.withValues(alpha: 0.15),
                      checkmarkColor: AppColors.primary,
                      side: BorderSide(
                        color: selected ? AppColors.primary : AppColors.border,
                      ),
                    );
                  }).toList(),
                ),

              if (_errorText != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  _errorText!,
                  style: const TextStyle(
                    color: AppColors.error,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],

              const SizedBox(height: AppSpacing.md),
            ],

            // Save button
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _handleSave,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                ),
                child: const Text(
                  'Continue To Save Details',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
