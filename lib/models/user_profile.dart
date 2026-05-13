import 'package:flutter/material.dart';

/// Holds all user body & style preference data.
class UserProfile {
  final String       name;
  final String?      imagePath;        // Local file path for profile photo
  final double       height;           // cm
  final double       weight;           // kg
  final String       skinTone;         // Must be one of [skinTones]
  final String       bodyType;         // Must be one of [bodyTypeOptions]
  final List<String> favoriteColors;   // Subset of [colorSwatches] names
  final List<String> occasions;        // Subset of [occasionOptions]
  final String       stylePersonality; // Must be one of [styleOptions]
  final DateTime     createdAt;
  final DateTime     updatedAt;

  const UserProfile({
    this.name             = 'Sarah',
    this.imagePath,
    this.height           = 170,
    this.weight           = 65,
    this.skinTone         = 'Medium',
    this.bodyType         = 'Regular',
    this.favoriteColors   = const ['Black', 'Navy', 'Beige'],
    this.occasions        = const ['Casual'],
    this.stylePersonality = 'Classic',
    required this.createdAt,
    required this.updatedAt,
  });

  /// Deserializes a [UserProfile] from a database row map.
  /// Note: [favoriteColors] and [occasions] are stored in separate junction
  /// tables and must be loaded and merged by the repository after construction.
  UserProfile.fromMap(Map<String, dynamic> map)
      : name             = map['name'] as String,
        imagePath        = map['image_path'] as String?,
        height           = (map['height'] as num?)?.toDouble() ?? 170.0,
        weight           = (map['weight'] as num?)?.toDouble() ?? 65.0,
        skinTone         = map['skin_tone'] as String? ?? 'Medium',
        bodyType         = map['body_type'] as String? ?? 'Regular',
        stylePersonality = map['style_personality'] as String? ?? 'Classic',
        createdAt        = DateTime.parse(map['created_at'] as String),
        updatedAt        = DateTime.parse(map['updated_at'] as String),
        favoriteColors   = const [],   // Loaded separately from user_favorite_colors
        occasions        = const [];   // Loaded separately from user_occasions

  /// Serializes this profile to a database row map.
  /// [id] is passed in rather than stored on the object to match the DB schema.
  /// [favoriteColors] and [occasions] are intentionally omitted — they are
  /// persisted via their own junction tables.
  Map<String, dynamic> toMap(String id) => {
        'id':                id,
        'name':              name,
        'image_path':        imagePath,
        'height':            height,
        'weight':            weight,
        'skin_tone':         skinTone,
        'body_type':         bodyType,
        'style_personality': stylePersonality,
        'created_at':        createdAt.toIso8601String(),
        'updated_at':        updatedAt.toIso8601String(),
      };

  /// Returns a copy of this profile with selected fields replaced.
  /// Use [clearImage] to explicitly set [imagePath] to null; passing
  /// `imagePath: null` alone will keep the existing value.
  UserProfile copyWith({
    String?       name,
    String?       imagePath,
    bool          clearImage = false,
    double?       height,
    double?       weight,
    String?       skinTone,
    String?       bodyType,
    List<String>? favoriteColors,
    List<String>? occasions,
    String?       stylePersonality,
    DateTime?     createdAt,
    DateTime?     updatedAt,
  }) {
    return UserProfile(
      name:             name             ?? this.name,
      imagePath:        clearImage ? null : (imagePath ?? this.imagePath),
      height:           height           ?? this.height,
      weight:           weight           ?? this.weight,
      skinTone:         skinTone         ?? this.skinTone,
      bodyType:         bodyType         ?? this.bodyType,
      favoriteColors:   favoriteColors   ?? this.favoriteColors,
      occasions:        occasions        ?? this.occasions,
      stylePersonality: stylePersonality ?? this.stylePersonality,
      createdAt:        createdAt        ?? this.createdAt,
      updatedAt:        updatedAt        ?? this.updatedAt,
    );
  }

  // ── Option lists ───────────────────────────────────────────
  // These are the single source of truth for every picker/dropdown in the UI.

  static const List<String> skinTones = [
    'Fair', 'Light', 'Medium', 'Olive', 'Tan', 'Brown', 'Dark',
  ];

  static const List<String> bodyTypeOptions = [
    'Slim', 'Athletic', 'Regular', 'Muscular', 'Plus Size',
  ];

  /// Colour swatches shown in the style-preference picker.
  /// Light colours (white, beige) set [AppColorSwatch.hasBorder] so they
  /// remain visible against a light background.
  static const List<AppColorSwatch> colorSwatches = [
    AppColorSwatch(name: 'Black',    color: Color(0xFF2C2C2C)),
    AppColorSwatch(name: 'White',    color: Color(0xFFF5F5F0), hasBorder: true),
    AppColorSwatch(name: 'Navy',     color: Color(0xFF2C3E6B)),
    AppColorSwatch(name: 'Burgundy', color: Color(0xFF8B2635)),
    AppColorSwatch(name: 'Beige',    color: Color(0xFFE8DCC8), hasBorder: true),
    AppColorSwatch(name: 'Olive',    color: Color(0xFF6B7C45)),
    AppColorSwatch(name: 'Blush',    color: Color(0xFFF4A7B3)),
    AppColorSwatch(name: 'Teal',     color: Color(0xFF2A8C7E)),
  ];

  static const List<String> occasionOptions = [
    'Casual', 'Business', 'Formal', 'Sport', 'Evening',
  ];

  static const List<String> styleOptions = [
    'Classic', 'Streetwear', 'Minimalist', 'Bohemian', 'Sporty',
  ];
}

/// Simple value object pairing a colour name with its display swatch.
class AppColorSwatch {
  final String name;
  final Color  color;
  final bool   hasBorder;   // True for light swatches that need a border to stay visible

  const AppColorSwatch({
    required this.name,
    required this.color,
    this.hasBorder = false,
  });
}
