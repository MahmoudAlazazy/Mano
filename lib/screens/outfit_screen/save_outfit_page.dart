part of '../outfit_screen.dart';

class _SaveOutfitPage extends StatefulWidget {
  final String modeName;
  final String occasion;
  final String audienceLabel;
  final List<_OutfitPiece> items;
  final double currentTemperatureC;
  final _WeatherBand initialWeatherBand;   // Pre-selected based on current weather
  /// Called with the completed draft when the user confirms; the caller
  /// is responsible for persisting and closing any loading states.
  final Future<void> Function(_OutfitSaveDraft draft) onSave;

  const _SaveOutfitPage({
    required this.modeName,
    required this.occasion,
    required this.audienceLabel,
    required this.items,
    required this.currentTemperatureC,
    required this.initialWeatherBand,
    required this.onSave,
  });

  @override
  State<_SaveOutfitPage> createState() => _SaveOutfitPageState();
}

class _SaveOutfitPageState extends State<_SaveOutfitPage> {
  late final TextEditingController _nameController;
  late DateTime _plannedDate;
  late _WeatherBand _selectedBand;
  late double _minTemp;   // °C; lower bound of the suitable temperature range
  late double _maxTemp;   // °C; upper bound of the suitable temperature range
  bool _isSaving = false;
  String? _errorText;     // Non-null while a validation or save error is shown

  @override
  void initState() {
    super.initState();
    // Pre-fill the name field with a sensible default the user can edit.
    _nameController = TextEditingController(
      text: '${widget.modeName} - ${widget.occasion}',
    );
    _plannedDate = DateTime.now();
    _selectedBand = widget.initialWeatherBand;
    // Initialise the slider to the default range for the pre-selected band.
    final defaults = _defaultRangeForBand(widget.initialWeatherBand);
    _minTemp = defaults.$1;
    _maxTemp = defaults.$2;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  /// Returns the (min, max) °C defaults for a given [band].
  /// Applied both on first load and whenever the user switches bands.
  (double, double) _defaultRangeForBand(_WeatherBand band) {
    switch (band) {
      case _WeatherBand.cold:
        return (8, 18);
      case _WeatherBand.mild:
        return (19, 27);
      case _WeatherBand.hot:
        return (28, 40);
    }
  }

  /// Human-readable label for a [_WeatherBand], used on the choice chips.
  String _bandLabel(_WeatherBand band) {
    switch (band) {
      case _WeatherBand.cold:
        return 'Cold';
      case _WeatherBand.mild:
        return 'Mild';
      case _WeatherBand.hot:
        return 'Hot';
    }
  }

  /// Returns the full weekday name for [date] (Monday … Sunday).
  String _weekdayName(DateTime date) {
    const names = <String>[
      'Monday', 'Tuesday', 'Wednesday', 'Thursday',
      'Friday', 'Saturday', 'Sunday',
    ];
    return names[(date.weekday - 1).clamp(0, 6)];
  }

  /// Formats [date] as YYYY-MM-DD for display in the date picker row.
  String _dateLabel(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// Opens the system date picker and updates [_plannedDate] on selection.
  /// Allows dates from one year in the past to two years in the future.
  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _plannedDate,
      firstDate: DateTime(now.year - 1, now.month, now.day),
      lastDate: DateTime(now.year + 2, now.month, now.day),
    );
    if (picked == null) return;   // User dismissed the picker
    setState(() {
      // Strip time component so comparisons stay date-only.
      _plannedDate = DateTime(picked.year, picked.month, picked.day);
    });
  }

  /// Validates the name field, calls [widget.onSave] with the current draft,
  /// and pops the page on success. Sets [_errorText] on validation failure
  /// or if the save throws.
  Future<void> _handleSave() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _errorText = 'Please enter outfit name.');
      return;
    }
    setState(() {
      _isSaving = true;
      _errorText = null;
    });
    try {
      await widget.onSave(
        _OutfitSaveDraft(
          name: name,
          plannedDate: _plannedDate,
          weatherBand: _selectedBand,
          minTempC: _minTemp,
          maxTempC: _maxTemp,
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorText = 'Save failed: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  /// Renders the visual for a single outfit piece in the summary chip row.
  /// Priority: in-memory bytes → network/asset path → emoji fallback.
  Widget _pieceVisual(_OutfitPiece piece) {
    if (piece.imageBytes != null && piece.imageBytes!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(
          piece.imageBytes!,
          width: 34,
          height: 34,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) =>
              Text(piece.emoji, style: const TextStyle(fontSize: 24)),
        ),
      );
    }

    final path = piece.imagePath?.trim();
    if (path != null && path.isNotEmpty) {
      final isNetwork = path.startsWith('http://') || path.startsWith('https://');
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: isNetwork
            ? Image.network(
                path,
                width: 34,
                height: 34,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    Text(piece.emoji, style: const TextStyle(fontSize: 24)),
              )
            : Image.asset(
                path,
                width: 34,
                height: 34,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    Text(piece.emoji, style: const TextStyle(fontSize: 24)),
              ),
      );
    }
    // Ultimate fallback when no image is available at all.
    return Text(piece.emoji, style: const TextStyle(fontSize: 24));
  }

  @override
  Widget build(BuildContext context) {
    final isBusy = _isSaving;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Save Outfit'),
        backgroundColor: AppColors.background,
      ),
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [

          // ── Outfit summary card ──────────────────────────────
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.modeName,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${widget.occasion} - ${widget.audienceLabel}',
                  style: AppTextStyles.bodySmall,
                ),
                const SizedBox(height: AppSpacing.sm),
                // Scrollable row of piece thumbnails / emoji chips
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: widget.items
                      .map(
                        (piece) => Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.sm,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceAlt,
                            borderRadius: BorderRadius.circular(AppRadius.full),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _pieceVisual(piece),
                              const SizedBox(width: 6),
                              Text(
                                piece.name,
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
          ),

          const SizedBox(height: AppSpacing.md),

          // ── Outfit name field ────────────────────────────────
          TextField(
            controller: _nameController,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'Outfit Name',
              hintText: 'e.g. Friday Casual Look',
            ),
          ),

          const SizedBox(height: AppSpacing.md),

          // ── Planned date picker ──────────────────────────────
          InkWell(
            borderRadius: BorderRadius.circular(AppRadius.md),
            onTap: _pickDate,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.md,
              ),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                children: [
                  const Icon(Icons.calendar_today_rounded, size: 18),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      '${_dateLabel(_plannedDate)} (${_weekdayName(_plannedDate)})',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  const Icon(Icons.keyboard_arrow_down_rounded),
                ],
              ),
            ),
          ),

          const SizedBox(height: AppSpacing.md),

          // ── Weather band selector ────────────────────────────
          // Switching bands also resets the temperature range to band defaults.
          const Text(
            'Suitable Weather',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            children: _WeatherBand.values.map((band) {
              final selected = band == _selectedBand;
              return ChoiceChip(
                selected: selected,
                label: Text(_bandLabel(band)),
                onSelected: (_) {
                  final defaults = _defaultRangeForBand(band);
                  setState(() {
                    _selectedBand = band;
                    _minTemp = defaults.$1;
                    _maxTemp = defaults.$2;
                  });
                },
              );
            }).toList(),
          ),

          const SizedBox(height: AppSpacing.md),

          // ── Temperature range slider ─────────────────────────
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Best temperature: ${_minTemp.toStringAsFixed(0)} - ${_maxTemp.toStringAsFixed(0)} C',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                RangeSlider(
                  values: RangeValues(_minTemp, _maxTemp),
                  min: 0,
                  max: 45,
                  divisions: 45,
                  labels: RangeLabels(
                    _minTemp.toStringAsFixed(0),
                    _maxTemp.toStringAsFixed(0),
                  ),
                  onChanged: (values) {
                    // Guard against the handles crossing each other.
                    setState(() {
                      _minTemp = values.start <= values.end
                          ? values.start
                          : values.end;
                      _maxTemp = values.end >= values.start
                          ? values.end
                          : values.start;
                    });
                  },
                ),
                // Read-only reminder of the temperature used during AI generation
                Text(
                  'Current weather while generating: ${widget.currentTemperatureC.toStringAsFixed(1)} C',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),

          // ── Inline error message ─────────────────────────────
          if (_errorText != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              _errorText!,
              style: const TextStyle(
                color: AppColors.error,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],

          const SizedBox(height: AppSpacing.lg),

          // ── Save button ──────────────────────────────────────
          // Disabled and shows a spinner while the async save is in progress.
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              onPressed: isBusy ? null : _handleSave,
              icon: isBusy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.save_rounded),
              label: Text(isBusy ? 'Saving...' : 'Save Outfit'),
            ),
          ),

          const SizedBox(height: AppSpacing.lg),
        ],
      ),
    );
  }
}
