part of '../outfit_screen.dart';

// Local data models
// ─────────────────────────────────────────────────────────────────
enum _WardrobeBucket { top, bottom, shoes, jacket, accessory, other }

enum _WeatherBand { cold, mild, hot }

class _OutfitOption {
  final IconData icon;
  final String title;
  final String description;
  const _OutfitOption({
    required this.icon,
    required this.title,
    required this.description,
  });
}

class _AudienceOption {
  final String label;
  final String searchValue;
  final IconData icon;

  const _AudienceOption({
    required this.label,
    required this.searchValue,
    required this.icon,
  });
}

class _ApiSuggestionSeed {
  final String searchName;
  final String type;
  final String name;
  final String category;
  final String emoji;

  const _ApiSuggestionSeed({
    required this.searchName,
    required this.type,
    required this.name,
    required this.category,
    required this.emoji,
  });

  _ApiSuggestionSeed copyWith({
    String? searchName,
    String? type,
    String? name,
    String? category,
    String? emoji,
  }) {
    return _ApiSuggestionSeed(
      searchName: searchName ?? this.searchName,
      type: type ?? this.type,
      name: name ?? this.name,
      category: category ?? this.category,
      emoji: emoji ?? this.emoji,
    );
  }
}

class _PreviewLoadResult {
  final List<_OutfitPiece> items;
  final String? firstApiError;

  const _PreviewLoadResult({required this.items, required this.firstApiError});
}

class _OutfitPiece {
  final String emoji;
  final String name;
  final String category;
  final String? imagePath;
  final Uint8List? imageBytes;
  final String? wardrobeId;
  final String? apiImageName;
  final String? apiImageType;
  final int? apiImageIndex;
  final String? apiSourceImageUrl;
  final String? apiSearchQuery;
  final String? apiSearchEngine;
  final int? apiResultIndex;
  final bool usedGenericFallback;
  const _OutfitPiece({
    required this.emoji,
    required this.name,
    required this.category,
    this.imagePath,
    this.imageBytes,
    this.wardrobeId,
    this.apiImageName,
    this.apiImageType,
    this.apiImageIndex,
    this.apiSourceImageUrl,
    this.apiSearchQuery,
    this.apiSearchEngine,
    this.apiResultIndex,
    this.usedGenericFallback = false,
  });

  _OutfitPiece copyWith({
    String? emoji,
    String? name,
    String? category,
    String? imagePath,
    Uint8List? imageBytes,
    String? wardrobeId,
    String? apiImageName,
    String? apiImageType,
    int? apiImageIndex,
    String? apiSourceImageUrl,
    String? apiSearchQuery,
    String? apiSearchEngine,
    int? apiResultIndex,
    bool? usedGenericFallback,
  }) {
    return _OutfitPiece(
      emoji: emoji ?? this.emoji,
      name: name ?? this.name,
      category: category ?? this.category,
      imagePath: imagePath ?? this.imagePath,
      imageBytes: imageBytes ?? this.imageBytes,
      wardrobeId: wardrobeId ?? this.wardrobeId,
      apiImageName: apiImageName ?? this.apiImageName,
      apiImageType: apiImageType ?? this.apiImageType,
      apiImageIndex: apiImageIndex ?? this.apiImageIndex,
      apiSourceImageUrl: apiSourceImageUrl ?? this.apiSourceImageUrl,
      apiSearchQuery: apiSearchQuery ?? this.apiSearchQuery,
      apiSearchEngine: apiSearchEngine ?? this.apiSearchEngine,
      apiResultIndex: apiResultIndex ?? this.apiResultIndex,
      usedGenericFallback: usedGenericFallback ?? this.usedGenericFallback,
    );
  }
}

class _OutfitSaveDraft {
  final String name;
  final DateTime plannedDate;
  final _WeatherBand weatherBand;
  final double minTempC;
  final double maxTempC;

  const _OutfitSaveDraft({
    required this.name,
    required this.plannedDate,
    required this.weatherBand,
    required this.minTempC,
    required this.maxTempC,
  });
}


