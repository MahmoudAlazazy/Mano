import 'dart:convert';
import 'dart:developer' as developer;

import 'gemini_service.dart';

/// The result of an outfit generation request: the 4 items to display and
/// the IDs of any wardrobe pieces included in the outfit.
class OutfitSuggestion {
  final List<OutfitItem> items;
  final List<String> suggestedWardrobeIds;

  const OutfitSuggestion({
    required this.items,
    required this.suggestedWardrobeIds,
  });
}

/// A single garment or accessory in an outfit. [source] is either `"wardrobe"`
/// (matched to a user item) or `"ai"` (a suggested piece with image search fields).
class OutfitItem {
  final String name;
  final String category;
  final String emoji;
  final String source; // "wardrobe" | "ai"
  final String? wardrobeId;
  final String? imageName;
  final String? imageType;
  final int? imageIndex;

  const OutfitItem({
    required this.name,
    required this.category,
    required this.emoji,
    required this.source,
    this.wardrobeId,
    this.imageName,
    this.imageType,
    this.imageIndex,
  });
}

/// Uses the Gemini API to generate a 4-item outfit based on occasion, weather,
/// and the user's wardrobe. Falls back to hardcoded items if the AI call fails.
class OutfitSuggestionService {
  OutfitSuggestionService({GeminiService? gemini})
    : _gemini = gemini ?? GeminiService();

  final GeminiService _gemini;

  void _terminalDebug(String message) {
    developer.log(message, name: 'OutfitSuggestionService');
    // ignore: avoid_print
    print('[OutfitSuggestionService] $message');
  }

  /// Generates a 4-item outfit suggestion for the given [mode], [occasion],
  /// and weather context. On any error the result falls back to a safe
  /// hardcoded outfit so the UI is never left empty.
  Future<OutfitSuggestion> generate({
    required String mode,
    required String occasion,
    required List<Map<String, dynamic>> wardrobeItems,
    required String governorate,
    required double temperatureC,
    String audience = 'men',
  }) async {
    final wardrobe = _WardrobeIndex.fromRaw(wardrobeItems);
    try {
      final prompt = _buildPrompt(
        mode: mode,
        occasion: occasion,
        governorate: governorate,
        temperatureC: temperatureC,
        audience: audience,
        wardrobe: wardrobe,
      );

      final body = {
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': prompt},
            ],
          },
        ],
        'generationConfig': {
          'temperature': 0.45,
          'topP': 0.9,
          'maxOutputTokens': 900,
          // Helps Gemini return parsable JSON instead of markdown text.
          'responseMimeType': 'application/json',
        },
      };

      final response = await _gemini.generateContent(body: body);
      final text = _extractText(response);
      _terminalDebug('Gemini raw outfit response: ${_truncateForLog(text)}');
      final data = _decodeJson(text);
      _terminalDebug(
        'Gemini parsed outfit JSON: ${_truncateForLog(jsonEncode(data))}',
      );

      final parsedItems = _parseItems(data['items']);
      final selectedRaw = data['selected_wardrobe_ids'];

      var resolvedItems = _resolveItemsForMode(
        mode: mode,
        parsedItems: parsedItems,
        wardrobe: wardrobe,
        audience: audience,
        occasion: occasion,
        temperatureC: temperatureC,
      );

      if (resolvedItems.isEmpty) {
        resolvedItems = _fallbackItems(
          mode: mode,
          wardrobe: wardrobe,
          audience: audience,
          occasion: occasion,
          temperatureC: temperatureC,
        );
      }

      final selectedIds = <String>{
        ..._parseSelectedIds(selectedRaw),
        ...resolvedItems
            .where(
              (item) => item.wardrobeId != null && item.wardrobeId!.isNotEmpty,
            )
            .map((item) => item.wardrobeId!),
      };

      selectedIds.retainWhere(wardrobe.byId.containsKey);

      _terminalDebug(
        'Resolved outfit items: ${_truncateForLog(jsonEncode(_itemsForLog(resolvedItems)))}',
      );
      _terminalDebug('Resolved wardrobe IDs: ${selectedIds.toList()}');

      return OutfitSuggestion(
        items: resolvedItems,
        suggestedWardrobeIds: selectedIds.toList(),
      );
    } catch (e, stackTrace) {
      _terminalDebug('Gemini outfit flow failed, using safe fallback: $e');
      developer.log(
        'Gemini fallback stack trace',
        name: 'OutfitSuggestionService',
        stackTrace: stackTrace,
      );
      return _buildSafeFallbackSuggestion(
        mode: mode,
        wardrobe: wardrobe,
        audience: audience,
        occasion: occasion,
        temperatureC: temperatureC,
      );
    }
  }

  /// Returns a short plain-text weather + styling tip (≤ 160 characters) for
  /// the given location and occasion. Throws if the AI returns an empty response.
  Future<String> generateWeatherRecommendation({
    required String occasion,
    required List<Map<String, dynamic>> wardrobeItems,
    required String governorate,
    required double temperatureC,
  }) async {
    final wardrobe = _WardrobeIndex.fromRaw(wardrobeItems);
    final prompt = _buildWeatherRecommendationPrompt(
      occasion: occasion,
      governorate: governorate,
      temperatureC: temperatureC,
      wardrobe: wardrobe,
    );

    final body = {
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': prompt},
          ],
        },
      ],
      'generationConfig': {
        'temperature': 0.35,
        'topP': 0.8,
        'maxOutputTokens': 120,
      },
    };

    final response = await _gemini.generateContent(body: body);
    final text = _extractText(response);
    _terminalDebug('Gemini raw weather response: ${_truncateForLog(text)}');
    final cleaned = _stripMarkdownCodeFences(
      text,
    ).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) {
      throw const FormatException('Empty Gemini weather recommendation');
    }
    return cleaned;
  }

  String _buildPrompt({
    required String mode,
    required String occasion,
    required String governorate,
    required double temperatureC,
    required String audience,
    required _WardrobeIndex wardrobe,
  }) {
    final weatherBand = temperatureC >= 28
        ? 'hot'
        : (temperatureC <= 18 ? 'cold' : 'mild');

    final wardrobeJson = jsonEncode(
      wardrobe.items.take(40).map((w) {
        return {
          'id': w.id,
          'name': w.name,
          'category': w.category,
          'color': w.color,
          'brand': w.brand,
          'emoji': w.emoji,
        };
      }).toList(),
    );

    return '''
You are a fashion stylist. Return STRICT JSON only (no markdown, no explanation).

Mode: $mode
Occasion: $occasion
Target audience: ${audience.toLowerCase().contains('women') ? "women's clothing" : "men's clothing"}
Location (Governorate): $governorate
Temperature (C): ${temperatureC.toStringAsFixed(1)}
Weather band: $weatherBand
Wardrobe items:
$wardrobeJson

Output schema:
{
  "items": [
    {
      "name": "...",
      "category": "...",
      "color": "...",
      "emoji": "...",
      "source": "wardrobe|ai",
      "wardrobe_id": "uuid-or-null",
      "image_name": "text used for image api query",
      "image_type": "optional type tag",
      "image_index": 0
    }
  ],
  "selected_wardrobe_ids": ["uuid", "..."]
}

Rules:
- Total items must be exactly 4.
- Categories: Tops, Bottoms, Shoes, Jackets, Dresses, Accessories.
- The 4 items must form one cohesive outfit that can be worn together.
- Use one clear palette and compatible formality. Avoid mixing formal shoes with athletic clothes, or dresses with separate bottoms.
- Use one of these outfit structures:
  - Top + Bottom + Shoes + Jacket/Accessory.
  - Dress + Shoes + Jacket/Accessory + Accessory.
  - Sport top + Sport bottom + Sport shoes + Sport layer/accessory.
- If Mode is "Use My Wardrobe":
  - Prefer ONLY wardrobe items.
  - Always include wardrobe_id when using wardrobe source.
- If Mode is "Mix & Match":
  - Include 1 or 2 wardrobe items (source=wardrobe, with wardrobe_id).
  - Fill the remaining pieces with AI suggestions (source=ai, wardrobe_id=null).
  - The AI suggestions must complete the wardrobe pieces into one wearable outfit.
- If Mode is "Full Outfit Suggestion":
  - Use source=ai only.
  - Return a complete outfit, not four unrelated product ideas.
- For wardrobe items, use exact IDs from the provided list.
- For AI items, include:
  - image_name: short searchable phrase that will be sent directly as the `name` query parameter to this endpoint:
    GET /api/v1/clothing/image?name=...&type=...
  - image_type: short type that will be sent directly as the `type` query parameter.
  - image_index: integer (usually 0)
  - Keep image_name plain text only, short, searchable, and product-like.
  - image_name must match the target audience. Use women/female terms only for women's clothing and men/male terms only for men's clothing.
  - Do not return sentences in image_name.
Examples of valid AI search fields:
  - image_name="men nike hoodie", image_type="hoodie"
  - image_name="women linen blouse", image_type="blouse"
  - image_name="men adidas running shoes", image_type="shoes"
''';
  }

  String _buildWeatherRecommendationPrompt({
    required String occasion,
    required String governorate,
    required double temperatureC,
    required _WardrobeIndex wardrobe,
  }) {
    final weatherBand = temperatureC >= 28
        ? 'hot'
        : (temperatureC <= 18 ? 'cold' : 'mild');
    final samples = wardrobe.items
        .take(12)
        .map(
          (item) => {
            'name': item.name,
            'category': item.category,
            'color': item.color,
          },
        )
        .toList();

    return '''
You are a concise fashion stylist.
Reply with plain text only, in 1 or 2 short sentences, maximum 160 characters.
Mention today's weather in $governorate, recommend the best clothing direction for $occasion, and use the user's available wardrobe when possible.
If the wardrobe is missing a strong option, suggest opening Full Outfit Suggestion.
Do not use markdown, bullet points, JSON, or emojis.

Occasion: $occasion
Temperature (C): ${temperatureC.toStringAsFixed(1)}
Weather band: $weatherBand
Wardrobe summary: ${_wardrobeSummaryForPrompt(wardrobe)}
Wardrobe samples: ${jsonEncode(samples)}

Weather rules:
- hot: prioritize breathable, light pieces and avoid heavy jackets
- cold: prioritize warm layers, jackets, boots, and heavier fabrics
- mild: prioritize light layering
''';
  }

  String _wardrobeSummaryForPrompt(_WardrobeIndex wardrobe) {
    if (wardrobe.items.isEmpty) {
      return 'No wardrobe items available.';
    }

    final counts = <String, int>{};
    for (final item in wardrobe.items) {
      final bucket = _categoryBucket(item.category);
      final key = bucket.isEmpty ? 'other' : bucket;
      counts[key] = (counts[key] ?? 0) + 1;
    }

    final ordered = counts.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return ordered.map((e) => '${e.key}:${e.value}').join(', ');
  }

  List<_RawSuggestionItem> _parseItems(dynamic itemsRaw) {
    final out = <_RawSuggestionItem>[];
    if (itemsRaw is! List) return out;

    for (final item in itemsRaw) {
      if (item is! Map) continue;

      final name = (item['name'] ?? '').toString().trim();
      final category = (item['category'] ?? '').toString().trim();
      final color = (item['color'] ?? '').toString().trim();
      final emoji = (item['emoji'] ?? '').toString().trim();
      final source = (item['source'] ?? 'ai').toString().trim().toLowerCase();
      final wardrobeId = item['wardrobe_id']?.toString().trim();
      final imageName = item['image_name']?.toString().trim();
      final imageType = item['image_type']?.toString().trim();
      final imageIndex = _parseImageIndex(item['image_index']);

      if (name.isEmpty || category.isEmpty) continue;

      out.add(
        _RawSuggestionItem(
          name: name,
          category: category,
          color: color,
          emoji: emoji,
          source: source.isEmpty ? 'ai' : source,
          wardrobeId: (wardrobeId != null && wardrobeId.isNotEmpty)
              ? wardrobeId
              : null,
          imageName: (imageName != null && imageName.isNotEmpty)
              ? imageName
              : null,
          imageType: (imageType != null && imageType.isNotEmpty)
              ? imageType
              : null,
          imageIndex: imageIndex,
        ),
      );
    }

    return out;
  }

  Set<String> _parseSelectedIds(dynamic selectedRaw) {
    final ids = <String>{};
    if (selectedRaw is! List) return ids;
    for (final id in selectedRaw) {
      if (id == null) continue;
      final v = id.toString().trim();
      if (v.isNotEmpty) ids.add(v);
    }
    return ids;
  }

  int? _parseImageIndex(dynamic value) {
    if (value == null) return null;
    if (value is int && value >= 0) return value;
    final parsed = int.tryParse(value.toString().trim());
    if (parsed == null || parsed < 0) return null;
    return parsed;
  }

  /// Converts raw AI-parsed items into resolved [OutfitItem]s, applying mode
  /// rules (wardrobe-only, mix, or full AI) and enforcing exactly 4 results.
  List<OutfitItem> _resolveItemsForMode({
    required String mode,
    required List<_RawSuggestionItem> parsedItems,
    required _WardrobeIndex wardrobe,
    required String audience,
    required String occasion,
    required double temperatureC,
  }) {
    final modeLower = mode.toLowerCase();
    final isWardrobeMode = modeLower.contains('use my wardrobe');
    final isMixMode = modeLower.contains('mix');
    final isFullMode = modeLower.contains('full');

    final resolved = <OutfitItem>[];
    final usedWardrobeIds = <String>{};

    for (final raw in parsedItems) {
      final wantsWardrobe =
          isWardrobeMode ||
          raw.source == 'wardrobe' ||
          (isMixMode && raw.source != 'ai');

      if (wantsWardrobe) {
        final matchedId = _resolveWardrobeId(raw: raw, wardrobe: wardrobe);
        if (matchedId != null && !usedWardrobeIds.contains(matchedId)) {
          final matched = wardrobe.byId[matchedId]!;
          usedWardrobeIds.add(matchedId);
          resolved.add(
            OutfitItem(
              name: matched.name,
              category: matched.category,
              emoji: _safeEmoji(matched.emoji, matched.category),
              source: 'wardrobe',
              wardrobeId: matched.id,
              imageName: null,
              imageType: null,
              imageIndex: null,
            ),
          );
          continue;
        }

        if (isMixMode) {
          resolved.add(
            OutfitItem(
              name: raw.name,
              category: raw.category,
              emoji: _safeEmoji(raw.emoji, raw.category),
              source: 'ai',
              wardrobeId: null,
              imageName: raw.imageName,
              imageType: raw.imageType,
              imageIndex: raw.imageIndex,
            ),
          );
        }
        continue;
      }

      resolved.add(
        OutfitItem(
          name: raw.name,
          category: raw.category,
          emoji: _safeEmoji(raw.emoji, raw.category),
          source: 'ai',
          wardrobeId: null,
          imageName: raw.imageName,
          imageType: raw.imageType,
          imageIndex: raw.imageIndex,
        ),
      );
    }

    final enforced = _enforceModeConstraints(
      mode: mode,
      items: resolved,
      wardrobe: wardrobe,
      usedWardrobeIds: usedWardrobeIds,
      audience: audience,
      occasion: occasion,
      temperatureC: temperatureC,
    );
    final exactFour = _ensureExactlyFourItems(
      mode: mode,
      items: enforced,
      wardrobe: wardrobe,
      usedWardrobeIds: usedWardrobeIds,
      audience: audience,
      occasion: occasion,
      temperatureC: temperatureC,
    );

    if (isFullMode) {
      return exactFour
          .map(
            (e) => OutfitItem(
              name: e.name,
              category: e.category,
              emoji: e.emoji,
              source: 'ai',
              wardrobeId: null,
              imageName: e.imageName,
              imageType: e.imageType,
              imageIndex: e.imageIndex,
            ),
          )
          .toList();
    }

    return exactFour;
  }

  List<OutfitItem> _enforceModeConstraints({
    required String mode,
    required List<OutfitItem> items,
    required _WardrobeIndex wardrobe,
    required Set<String> usedWardrobeIds,
    required String audience,
    required String occasion,
    required double temperatureC,
  }) {
    final modeLower = mode.toLowerCase();
    final isWardrobeMode = modeLower.contains('use my wardrobe');
    final isMixMode = modeLower.contains('mix');

    var out = List<OutfitItem>.from(items);

    if (isWardrobeMode) {
      out = out.where((e) => e.source == 'wardrobe').toList();

      while (out.length < 4) {
        final next = wardrobe.items.firstWhere(
          (w) => !usedWardrobeIds.contains(w.id),
          orElse: () => _WardrobeRef.empty,
        );
        if (next.isEmpty) break;

        usedWardrobeIds.add(next.id);
        out.add(
          OutfitItem(
            name: next.name,
            category: next.category,
            emoji: _safeEmoji(next.emoji, next.category),
            source: 'wardrobe',
            wardrobeId: next.id,
            imageName: null,
            imageType: null,
            imageIndex: null,
          ),
        );
      }

      if (out.length > 4) {
        out = out.take(4).toList();
      }
      return out;
    }

    if (isMixMode) {
      final targetWardrobeCount = _targetMixWardrobeCount(
        items: out,
        wardrobe: wardrobe,
      );
      var wardrobeCount = out.where((e) => e.source == 'wardrobe').length;
      var aiCount = out.where((e) => e.source == 'ai').length;

      if (wardrobeCount > targetWardrobeCount) {
        for (
          var i = out.length - 1;
          i >= 0 && wardrobeCount > targetWardrobeCount;
          i--
        ) {
          if (out[i].source == 'wardrobe') {
            out.removeAt(i);
            wardrobeCount--;
          }
        }
      }

      while (wardrobeCount < targetWardrobeCount) {
        final next = wardrobe.items.firstWhere(
          (w) => !usedWardrobeIds.contains(w.id),
          orElse: () => _WardrobeRef.empty,
        );
        if (next.isEmpty) break;

        usedWardrobeIds.add(next.id);
        out.add(
          OutfitItem(
            name: next.name,
            category: next.category,
            emoji: _safeEmoji(next.emoji, next.category),
            source: 'wardrobe',
            wardrobeId: next.id,
            imageName: null,
            imageType: null,
            imageIndex: null,
          ),
        );
        wardrobeCount++;
      }

      if (aiCount == 0) {
        out.add(
          OutfitItem(
            name: 'Missing Piece Suggestion',
            category: 'Jackets',
            emoji: '\u{1F9E5}',
            source: 'ai',
            wardrobeId: null,
            imageName: _isWomenAudience(audience)
                ? 'soft blazer'
                : 'light jacket',
            imageType: 'jacket',
            imageIndex: 0,
          ),
        );
        aiCount++;
      }

      if (out.length < 4) {
        final aiFillItems = _fallbackItems(
          mode: mode,
          wardrobe: wardrobe,
          audience: audience,
          occasion: occasion,
          temperatureC: temperatureC,
        ).where((item) => item.source == 'ai');
        out.addAll(aiFillItems);
      }

      if (out.length > 4) {
        out = out.take(4).toList();
      }

      return out;
    }

    if (out.isEmpty) {
      return _fallbackItems(
        mode: mode,
        wardrobe: wardrobe,
        audience: audience,
        occasion: occasion,
        temperatureC: temperatureC,
      );
    }

    if (out.length > 4) {
      out = out.take(4).toList();
    }

    return out;
  }

  List<OutfitItem> _ensureExactlyFourItems({
    required String mode,
    required List<OutfitItem> items,
    required _WardrobeIndex wardrobe,
    required Set<String> usedWardrobeIds,
    required String audience,
    required String occasion,
    required double temperatureC,
  }) {
    var out = List<OutfitItem>.from(items);
    if (out.length >= 4) return out.take(4).toList();

    final modeLower = mode.toLowerCase();
    final isWardrobeMode = modeLower.contains('use my wardrobe');
    final isMixMode = modeLower.contains('mix');

    final aiPool = <OutfitItem>[
      ..._fallbackItems(
        mode: 'Full Outfit Suggestion',
        wardrobe: wardrobe,
        audience: audience,
        occasion: occasion,
        temperatureC: temperatureC,
      ).where((e) => e.source == 'ai'),
      OutfitItem(
        name: _isWomenAudience(audience) ? 'Soft Blazer' : 'Layered Jacket',
        category: 'Jackets',
        emoji: '\u{1F9E5}',
        source: 'ai',
        imageName: _isWomenAudience(audience)
            ? 'soft blazer'
            : 'lightweight jacket',
        imageType: 'jacket',
        imageIndex: 0,
      ),
      OutfitItem(
        name: _isWomenAudience(audience) ? 'Leather Tote' : 'Minimal Watch',
        category: 'Accessories',
        emoji: _isWomenAudience(audience) ? '\u{1F45C}' : '\u{231A}',
        source: 'ai',
        imageName: _isWomenAudience(audience)
            ? 'leather tote bag'
            : 'minimal wrist watch',
        imageType: _isWomenAudience(audience) ? 'bag' : 'watch',
        imageIndex: 0,
      ),
    ];
    var aiCursor = 0;

    void addWardrobeItem() {
      final next = wardrobe.items.firstWhere(
        (w) => !usedWardrobeIds.contains(w.id),
        orElse: () => _WardrobeRef.empty,
      );
      if (next.isEmpty) return;

      usedWardrobeIds.add(next.id);
      out.add(
        OutfitItem(
          name: next.name,
          category: next.category,
          emoji: _safeEmoji(next.emoji, next.category),
          source: 'wardrobe',
          wardrobeId: next.id,
          imageName: null,
          imageType: null,
          imageIndex: null,
        ),
      );
    }

    void addAiItem() {
      if (aiCursor < aiPool.length) {
        out.add(aiPool[aiCursor++]);
        return;
      }

      out.add(
        OutfitItem(
          name: _isWomenAudience(audience)
              ? 'Essential Blouse'
              : 'Essential Piece',
          category: 'Tops',
          emoji: _isWomenAudience(audience) ? '\u{1F45A}' : '\u{1F455}',
          source: 'ai',
          imageName: _isWomenAudience(audience) ? 'basic blouse' : 'basic top',
          imageType: 'top',
          imageIndex: 0,
        ),
      );
    }

    while (out.length < 4) {
      if (isWardrobeMode) {
        final before = out.length;
        addWardrobeItem();
        if (out.length == before) {
          // Last resort to keep try-on stable with 4 pieces.
          addAiItem();
        }
        continue;
      }

      if (isMixMode) {
        final targetWardrobeCount = _targetMixWardrobeCount(
          items: out,
          wardrobe: wardrobe,
        );
        final wardrobeCount = out.where((e) => e.source == 'wardrobe').length;

        if (wardrobeCount < targetWardrobeCount) {
          final before = out.length;
          addWardrobeItem();
          if (out.length == before) addAiItem();
          continue;
        }

        addAiItem();
        continue;
      }

      addAiItem();
    }

    return out.take(4).toList();
  }

  int _targetMixWardrobeCount({
    required List<OutfitItem> items,
    required _WardrobeIndex wardrobe,
  }) {
    if (wardrobe.items.isEmpty) return 0;
    final current = items.where((e) => e.source == 'wardrobe').length;
    if (current >= 2) return 2;
    return 1;
  }

  /// Finds the best matching wardrobe ID for [raw] using a scoring heuristic
  /// based on category, name similarity, token overlap, and color. Returns null
  /// if no item scores high enough (threshold: 4).
  String? _resolveWardrobeId({
    required _RawSuggestionItem raw,
    required _WardrobeIndex wardrobe,
  }) {
    if (raw.wardrobeId != null && wardrobe.byId.containsKey(raw.wardrobeId)) {
      return raw.wardrobeId;
    }

    final targetName = _normalize(raw.name);
    final targetCategory = _categoryBucket(raw.category);
    final targetColor = _normalize(raw.color);
    final targetTokens = _tokens(raw.name);

    _WardrobeRef? best;
    var bestScore = -1;

    for (final w in wardrobe.items) {
      var score = 0;

      final nameNorm = _normalize(w.name);
      final categoryBucket = _categoryBucket(w.category);
      final wTokens = _tokens(w.name);

      if (targetCategory.isNotEmpty && targetCategory == categoryBucket) {
        score += 4;
      }

      if (targetName.isNotEmpty && targetName == nameNorm) {
        score += 5;
      }

      if (targetName.isNotEmpty &&
          (nameNorm.contains(targetName) || targetName.contains(nameNorm))) {
        score += 2;
      }

      final overlap = targetTokens.intersection(wTokens).length;
      score += overlap.clamp(0, 3);

      final wColor = _normalize(w.color ?? '');
      if (targetColor.isNotEmpty &&
          (wColor.contains(targetColor) || targetColor.contains(wColor))) {
        score += 2;
      }

      if (score > bestScore) {
        best = w;
        bestScore = score;
      }
    }

    if (best != null && bestScore >= 4) {
      return best.id;
    }
    return null;
  }

  String _safeEmoji(String? rawEmoji, String category) {
    if (rawEmoji != null && rawEmoji.trim().isNotEmpty) return rawEmoji.trim();

    switch (_categoryBucket(category)) {
      case 'tops':
        return '\u{1F455}';
      case 'bottoms':
        return '\u{1F456}';
      case 'shoes':
        return '\u{1F45F}';
      case 'jackets':
        return '\u{1F9E5}';
      case 'dresses':
        return '\u{1F457}';
      case 'accessories':
        return '\u{1F9E2}';
      default:
        return '\u{2728}';
    }
  }

  String _categoryBucket(String category) {
    final c = _normalize(category);
    if (c.contains('top') ||
        c.contains('shirt') ||
        c.contains('blouse') ||
        c.contains('tee')) {
      return 'tops';
    }
    if (c.contains('bottom') ||
        c.contains('pant') ||
        c.contains('jean') ||
        c.contains('short') ||
        c.contains('skirt') ||
        c.contains('legging')) {
      return 'bottoms';
    }
    if (c.contains('shoe') ||
        c.contains('sneaker') ||
        c.contains('boot') ||
        c.contains('loafer') ||
        c.contains('heel') ||
        c.contains('flat') ||
        c.contains('sandal')) {
      return 'shoes';
    }
    if (c.contains('jacket') ||
        c.contains('coat') ||
        c.contains('hoodie') ||
        c.contains('blazer')) {
      return 'jackets';
    }
    if (c.contains('dress')) {
      return 'dresses';
    }
    if (c.contains('acc') ||
        c.contains('watch') ||
        c.contains('cap') ||
        c.contains('bag') ||
        c.contains('tote') ||
        c.contains('clutch')) {
      return 'accessories';
    }
    return '';
  }

  String _normalize(String input) {
    return input
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  Set<String> _tokens(String input) {
    return _normalize(
      input,
    ).split(' ').where((t) => t.trim().length >= 2).toSet();
  }

  String _extractText(Map<String, dynamic> response) {
    final candidates = response['candidates'];
    if (candidates is List && candidates.isNotEmpty) {
      final content = candidates.first['content'];
      final parts = (content is Map) ? content['parts'] : null;
      if (parts is List) {
        final buffer = StringBuffer();
        for (final part in parts) {
          if (part is Map && part['text'] is String) {
            buffer.write(part['text']);
          }
        }
        final text = buffer.toString().trim();
        if (text.isNotEmpty) return text;
      }
    }
    throw const FormatException('Empty Gemini response');
  }

  /// Parses the AI response text as JSON. If strict parsing fails, attempts to
  /// extract the first `{...}` block and retry before re-throwing.
  Map<String, dynamic> _decodeJson(String text) {
    final cleaned = _stripMarkdownCodeFences(text).trim();
    try {
      return jsonDecode(cleaned) as Map<String, dynamic>;
    } catch (_) {
      final start = cleaned.indexOf('{');
      final end = cleaned.lastIndexOf('}');
      if (start >= 0 && end > start) {
        final slice = cleaned.substring(start, end + 1);
        return jsonDecode(slice) as Map<String, dynamic>;
      }
      rethrow;
    }
  }

  String _stripMarkdownCodeFences(String input) {
    var out = input.trim();
    if (out.startsWith('```')) {
      out = out.replaceFirst(RegExp(r'^```[a-zA-Z0-9_-]*\s*'), '');
      out = out.replaceFirst(RegExp(r'\s*```$'), '');
    }
    return out.trim();
  }

  String _truncateForLog(String input, {int max = 1400}) {
    final compact = input.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.length <= max) return compact;
    return '${compact.substring(0, max)}...';
  }

  List<Map<String, dynamic>> _itemsForLog(List<OutfitItem> items) {
    return items
        .map(
          (item) => {
            'name': item.name,
            'category': item.category,
            'source': item.source,
            'wardrobe_id': item.wardrobeId,
            'image_name': item.imageName,
            'image_type': item.imageType,
            'image_index': item.imageIndex,
          },
        )
        .toList();
  }

  OutfitSuggestion _buildSafeFallbackSuggestion({
    required String mode,
    required _WardrobeIndex wardrobe,
    required String audience,
    required String occasion,
    required double temperatureC,
  }) {
    final items = _fallbackItems(
      mode: mode,
      wardrobe: wardrobe,
      audience: audience,
      occasion: occasion,
      temperatureC: temperatureC,
    );
    final selectedIds = items
        .where((item) => item.wardrobeId != null && item.wardrobeId!.isNotEmpty)
        .map((item) => item.wardrobeId!)
        .where(wardrobe.byId.containsKey)
        .toSet()
        .toList();
    return OutfitSuggestion(items: items, suggestedWardrobeIds: selectedIds);
  }

  bool _isWomenAudience(String audience) {
    final value = audience.toLowerCase();
    return value.contains('women') ||
        value.contains('female') ||
        value.contains('girl');
  }

  String _fallbackOccasionKey(String occasion) {
    final value = occasion.toLowerCase();
    if (value.contains('formal')) return 'formal';
    if (value.contains('business')) return 'business';
    if (value.contains('sport')) return 'sport';
    return 'casual';
  }

  String _fallbackWeatherBand(double temperatureC) {
    if (temperatureC >= 28) return 'hot';
    if (temperatureC <= 18) return 'cold';
    return 'mild';
  }

  /// Returns a hardcoded 4-item AI outfit appropriate for the audience,
  /// occasion, and temperature band. Used when the AI response is unusable.
  List<OutfitItem> _cohesiveAiFallbackItems({
    required String audience,
    required String occasion,
    required double temperatureC,
  }) {
    final isWomen = _isWomenAudience(audience);
    final occ = _fallbackOccasionKey(occasion);
    final band = _fallbackWeatherBand(temperatureC);

    if (isWomen) {
      if (occ == 'formal') {
        if (band == 'cold') {
          return const [
            OutfitItem(
              name: 'Knit Dress',
              category: 'Dresses',
              emoji: '\u{1F457}',
              source: 'ai',
              imageName: 'black knit turtleneck dress',
              imageType: 'dress',
              imageIndex: 0,
            ),
            OutfitItem(
              name: 'Ankle Boots',
              category: 'Shoes',
              emoji: '\u{1F97E}',
              source: 'ai',
              imageName: 'black leather ankle boots',
              imageType: 'boots',
              imageIndex: 0,
            ),
            OutfitItem(
              name: 'Wool Coat',
              category: 'Jackets',
              emoji: '\u{1F9E5}',
              source: 'ai',
              imageName: 'camel tailored wool coat',
              imageType: 'coat',
              imageIndex: 0,
            ),
            OutfitItem(
              name: 'Handbag',
              category: 'Accessories',
              emoji: '\u{1F45C}',
              source: 'ai',
              imageName: 'black structured handbag',
              imageType: 'bag',
              imageIndex: 0,
            ),
          ];
        }
        return const [
          OutfitItem(
            name: 'Satin Midi Dress',
            category: 'Dresses',
            emoji: '\u{1F457}',
            source: 'ai',
            imageName: 'champagne satin midi dress',
            imageType: 'dress',
            imageIndex: 0,
          ),
          OutfitItem(
            name: 'Block Heels',
            category: 'Shoes',
            emoji: '\u{1F460}',
            source: 'ai',
            imageName: 'nude strappy block heels',
            imageType: 'heels',
            imageIndex: 0,
          ),
          OutfitItem(
            name: 'Cream Blazer',
            category: 'Jackets',
            emoji: '\u{1F9E5}',
            source: 'ai',
            imageName: 'cream formal blazer',
            imageType: 'blazer',
            imageIndex: 0,
          ),
          OutfitItem(
            name: 'Clutch Bag',
            category: 'Accessories',
            emoji: '\u{1F45C}',
            source: 'ai',
            imageName: 'champagne clutch bag',
            imageType: 'bag',
            imageIndex: 0,
          ),
        ];
      }

      if (occ == 'business') {
        if (band == 'cold') {
          return const [
            OutfitItem(
              name: 'Turtleneck Sweater',
              category: 'Tops',
              emoji: '\u{1F9E5}',
              source: 'ai',
              imageName: 'cream ribbed turtleneck sweater',
              imageType: 'sweater',
              imageIndex: 0,
            ),
            OutfitItem(
              name: 'Wool Trousers',
              category: 'Bottoms',
              emoji: '\u{1F456}',
              source: 'ai',
              imageName: 'charcoal wool tailored trousers',
              imageType: 'trousers',
              imageIndex: 0,
            ),
            OutfitItem(
              name: 'Ankle Boots',
              category: 'Shoes',
              emoji: '\u{1F97E}',
              source: 'ai',
              imageName: 'black leather ankle boots',
              imageType: 'boots',
              imageIndex: 0,
            ),
            OutfitItem(
              name: 'Belted Coat',
              category: 'Jackets',
              emoji: '\u{1F9E5}',
              source: 'ai',
              imageName: 'camel belted wool coat',
              imageType: 'coat',
              imageIndex: 0,
            ),
          ];
        }
        return const [
          OutfitItem(
            name: 'Button Blouse',
            category: 'Tops',
            emoji: '\u{1F45A}',
            source: 'ai',
            imageName: 'white cotton button blouse',
            imageType: 'blouse',
            imageIndex: 0,
          ),
          OutfitItem(
            name: 'Wide Leg Trousers',
            category: 'Bottoms',
            emoji: '\u{1F456}',
            source: 'ai',
            imageName: 'beige tailored wide leg trousers',
            imageType: 'trousers',
            imageIndex: 0,
          ),
          OutfitItem(
            name: 'Pointed Flats',
            category: 'Shoes',
            emoji: '\u{1F97F}',
            source: 'ai',
            imageName: 'tan pointed flats',
            imageType: 'flats',
            imageIndex: 0,
          ),
          OutfitItem(
            name: 'Leather Tote',
            category: 'Accessories',
            emoji: '\u{1F45C}',
            source: 'ai',
            imageName: 'tan minimal leather tote',
            imageType: 'bag',
            imageIndex: 0,
          ),
        ];
      }

      if (occ == 'sport') {
        if (band == 'cold') {
          return const [
            OutfitItem(
              name: 'Thermal Top',
              category: 'Tops',
              emoji: '\u{1F9E5}',
              source: 'ai',
              imageName: 'black thermal training top',
              imageType: 'top',
              imageIndex: 0,
            ),
            OutfitItem(
              name: 'Leggings',
              category: 'Bottoms',
              emoji: '\u{1F456}',
              source: 'ai',
              imageName: 'black high waist leggings',
              imageType: 'leggings',
              imageIndex: 0,
            ),
            OutfitItem(
              name: 'Running Sneakers',
              category: 'Shoes',
              emoji: '\u{1F45F}',
              source: 'ai',
              imageName: 'white running sneakers',
              imageType: 'sneakers',
              imageIndex: 0,
            ),
            OutfitItem(
              name: 'Training Jacket',
              category: 'Jackets',
              emoji: '\u{1F9E5}',
              source: 'ai',
              imageName: 'black training jacket',
              imageType: 'jacket',
              imageIndex: 0,
            ),
          ];
        }
        return const [
          OutfitItem(
            name: 'Training Tank',
            category: 'Tops',
            emoji: '\u{1F45A}',
            source: 'ai',
            imageName: 'white training tank top',
            imageType: 'top',
            imageIndex: 0,
          ),
          OutfitItem(
            name: 'Biker Shorts',
            category: 'Bottoms',
            emoji: '\u{1FA73}',
            source: 'ai',
            imageName: 'black biker shorts',
            imageType: 'shorts',
            imageIndex: 0,
          ),
          OutfitItem(
            name: 'Training Sneakers',
            category: 'Shoes',
            emoji: '\u{1F45F}',
            source: 'ai',
            imageName: 'white training sneakers',
            imageType: 'sneakers',
            imageIndex: 0,
          ),
          OutfitItem(
            name: 'Sports Cap',
            category: 'Accessories',
            emoji: '\u{1F9E2}',
            source: 'ai',
            imageName: 'black sports cap',
            imageType: 'cap',
            imageIndex: 0,
          ),
        ];
      }

      if (band == 'hot') {
        return const [
          OutfitItem(
            name: 'Linen Blouse',
            category: 'Tops',
            emoji: '\u{1F45A}',
            source: 'ai',
            imageName: 'ivory linen sleeveless blouse',
            imageType: 'blouse',
            imageIndex: 0,
          ),
          OutfitItem(
            name: 'Summer Shorts',
            category: 'Bottoms',
            emoji: '\u{1FA73}',
            source: 'ai',
            imageName: 'beige high waisted summer shorts',
            imageType: 'shorts',
            imageIndex: 0,
          ),
          OutfitItem(
            name: 'Flat Sandals',
            category: 'Shoes',
            emoji: '\u{1F461}',
            source: 'ai',
            imageName: 'tan flat summer sandals',
            imageType: 'sandals',
            imageIndex: 0,
          ),
          OutfitItem(
            name: 'Straw Tote',
            category: 'Accessories',
            emoji: '\u{1F45C}',
            source: 'ai',
            imageName: 'straw tote bag',
            imageType: 'bag',
            imageIndex: 0,
          ),
        ];
      }

      if (band == 'cold') {
        return const [
          OutfitItem(
            name: 'Knit Sweater',
            category: 'Tops',
            emoji: '\u{1F9E5}',
            source: 'ai',
            imageName: 'cream knit turtleneck sweater',
            imageType: 'sweater',
            imageIndex: 0,
          ),
          OutfitItem(
            name: 'Straight Jeans',
            category: 'Bottoms',
            emoji: '\u{1F456}',
            source: 'ai',
            imageName: 'dark straight leg jeans',
            imageType: 'jeans',
            imageIndex: 0,
          ),
          OutfitItem(
            name: 'Ankle Boots',
            category: 'Shoes',
            emoji: '\u{1F97E}',
            source: 'ai',
            imageName: 'black leather ankle boots',
            imageType: 'boots',
            imageIndex: 0,
          ),
          OutfitItem(
            name: 'Wrap Coat',
            category: 'Jackets',
            emoji: '\u{1F9E5}',
            source: 'ai',
            imageName: 'camel wool wrap coat',
            imageType: 'coat',
            imageIndex: 0,
          ),
        ];
      }

      return const [
        OutfitItem(
          name: 'Button Blouse',
          category: 'Tops',
          emoji: '\u{1F45A}',
          source: 'ai',
          imageName: 'white cotton button blouse',
          imageType: 'blouse',
          imageIndex: 0,
        ),
        OutfitItem(
          name: 'Wide Leg Trousers',
          category: 'Bottoms',
          emoji: '\u{1F456}',
          source: 'ai',
          imageName: 'sand wide leg trousers',
          imageType: 'trousers',
          imageIndex: 0,
        ),
        OutfitItem(
          name: 'Fashion Sneakers',
          category: 'Shoes',
          emoji: '\u{1F45F}',
          source: 'ai',
          imageName: 'white fashion sneakers',
          imageType: 'sneakers',
          imageIndex: 0,
        ),
        OutfitItem(
          name: 'Cardigan',
          category: 'Jackets',
          emoji: '\u{1F9E5}',
          source: 'ai',
          imageName: 'oatmeal cardigan sweater',
          imageType: 'cardigan',
          imageIndex: 0,
        ),
      ];
    }

    if (occ == 'formal') {
      if (band == 'cold') {
        return const [
          OutfitItem(
            name: 'Turtleneck',
            category: 'Tops',
            emoji: '\u{1F9E5}',
            source: 'ai',
            imageName: 'black formal turtleneck',
            imageType: 'top',
            imageIndex: 0,
          ),
          OutfitItem(
            name: 'Wool Trousers',
            category: 'Bottoms',
            emoji: '\u{1F456}',
            source: 'ai',
            imageName: 'charcoal wool trousers',
            imageType: 'pants',
            imageIndex: 0,
          ),
          OutfitItem(
            name: 'Chelsea Boots',
            category: 'Shoes',
            emoji: '\u{1F97E}',
            source: 'ai',
            imageName: 'black leather chelsea boots',
            imageType: 'boots',
            imageIndex: 0,
          ),
          OutfitItem(
            name: 'Wool Coat',
            category: 'Jackets',
            emoji: '\u{1F9E5}',
            source: 'ai',
            imageName: 'charcoal long wool coat',
            imageType: 'coat',
            imageIndex: 0,
          ),
        ];
      }
      return const [
        OutfitItem(
          name: 'Dress Shirt',
          category: 'Tops',
          emoji: '\u{1F454}',
          source: 'ai',
          imageName: 'white formal dress shirt',
          imageType: 'shirt',
          imageIndex: 0,
        ),
        OutfitItem(
          name: 'Tailored Pants',
          category: 'Bottoms',
          emoji: '\u{1F456}',
          source: 'ai',
          imageName: 'charcoal tailored pants',
          imageType: 'pants',
          imageIndex: 0,
        ),
        OutfitItem(
          name: 'Derby Shoes',
          category: 'Shoes',
          emoji: '\u{1F45E}',
          source: 'ai',
          imageName: 'black derby shoes',
          imageType: 'shoes',
          imageIndex: 0,
        ),
        OutfitItem(
          name: 'Navy Blazer',
          category: 'Jackets',
          emoji: '\u{1F9E5}',
          source: 'ai',
          imageName: 'navy formal blazer',
          imageType: 'blazer',
          imageIndex: 0,
        ),
      ];
    }

    if (occ == 'business') {
      if (band == 'cold') {
        return const [
          OutfitItem(
            name: 'Turtleneck',
            category: 'Tops',
            emoji: '\u{1F9E5}',
            source: 'ai',
            imageName: 'cream turtleneck sweater',
            imageType: 'sweater',
            imageIndex: 0,
          ),
          OutfitItem(
            name: 'Wool Trousers',
            category: 'Bottoms',
            emoji: '\u{1F456}',
            source: 'ai',
            imageName: 'charcoal wool trousers',
            imageType: 'pants',
            imageIndex: 0,
          ),
          OutfitItem(
            name: 'Chelsea Boots',
            category: 'Shoes',
            emoji: '\u{1F97E}',
            source: 'ai',
            imageName: 'black leather chelsea boots',
            imageType: 'boots',
            imageIndex: 0,
          ),
          OutfitItem(
            name: 'Wool Coat',
            category: 'Jackets',
            emoji: '\u{1F9E5}',
            source: 'ai',
            imageName: 'charcoal long wool coat',
            imageType: 'coat',
            imageIndex: 0,
          ),
        ];
      }
      return const [
        OutfitItem(
          name: 'Linen Shirt',
          category: 'Tops',
          emoji: '\u{1F454}',
          source: 'ai',
          imageName: 'white linen shirt',
          imageType: 'shirt',
          imageIndex: 0,
        ),
        OutfitItem(
          name: 'Tailored Trousers',
          category: 'Bottoms',
          emoji: '\u{1F456}',
          source: 'ai',
          imageName: 'beige tailored trousers',
          imageType: 'pants',
          imageIndex: 0,
        ),
        OutfitItem(
          name: 'Suede Loafers',
          category: 'Shoes',
          emoji: '\u{1F45E}',
          source: 'ai',
          imageName: 'brown suede loafers',
          imageType: 'loafers',
          imageIndex: 0,
        ),
        OutfitItem(
          name: 'Leather Watch',
          category: 'Accessories',
          emoji: '\u{231A}',
          source: 'ai',
          imageName: 'brown leather watch',
          imageType: 'watch',
          imageIndex: 0,
        ),
      ];
    }

    if (occ == 'sport') {
      if (band == 'cold') {
        return const [
          OutfitItem(
            name: 'Thermal Top',
            category: 'Tops',
            emoji: '\u{1F9E5}',
            source: 'ai',
            imageName: 'black thermal training top',
            imageType: 'top',
            imageIndex: 0,
          ),
          OutfitItem(
            name: 'Joggers',
            category: 'Bottoms',
            emoji: '\u{1F456}',
            source: 'ai',
            imageName: 'black running joggers',
            imageType: 'pants',
            imageIndex: 0,
          ),
          OutfitItem(
            name: 'Running Shoes',
            category: 'Shoes',
            emoji: '\u{1F45F}',
            source: 'ai',
            imageName: 'white running shoes',
            imageType: 'shoes',
            imageIndex: 0,
          ),
          OutfitItem(
            name: 'Training Jacket',
            category: 'Jackets',
            emoji: '\u{1F9E5}',
            source: 'ai',
            imageName: 'black training jacket',
            imageType: 'jacket',
            imageIndex: 0,
          ),
        ];
      }
      return const [
        OutfitItem(
          name: 'Dry-Fit Tee',
          category: 'Tops',
          emoji: '\u{1F455}',
          source: 'ai',
          imageName: 'white dry fit t shirt',
          imageType: 'tshirt',
          imageIndex: 0,
        ),
        OutfitItem(
          name: 'Running Shorts',
          category: 'Bottoms',
          emoji: '\u{1FA73}',
          source: 'ai',
          imageName: 'black running shorts',
          imageType: 'shorts',
          imageIndex: 0,
        ),
        OutfitItem(
          name: 'Training Sneakers',
          category: 'Shoes',
          emoji: '\u{1F45F}',
          source: 'ai',
          imageName: 'white training sneakers',
          imageType: 'sneakers',
          imageIndex: 0,
        ),
        OutfitItem(
          name: 'Sports Cap',
          category: 'Accessories',
          emoji: '\u{1F9E2}',
          source: 'ai',
          imageName: 'black sports cap',
          imageType: 'cap',
          imageIndex: 0,
        ),
      ];
    }

    if (band == 'hot') {
      return const [
        OutfitItem(
          name: 'Cotton Tee',
          category: 'Tops',
          emoji: '\u{1F455}',
          source: 'ai',
          imageName: 'white cotton t-shirt',
          imageType: 'tshirt',
          imageIndex: 0,
        ),
        OutfitItem(
          name: 'Chino Shorts',
          category: 'Bottoms',
          emoji: '\u{1FA73}',
          source: 'ai',
          imageName: 'beige chino shorts',
          imageType: 'shorts',
          imageIndex: 0,
        ),
        OutfitItem(
          name: 'Low Top Sneakers',
          category: 'Shoes',
          emoji: '\u{1F45F}',
          source: 'ai',
          imageName: 'white low top sneakers',
          imageType: 'sneakers',
          imageIndex: 0,
        ),
        OutfitItem(
          name: 'Sunglasses',
          category: 'Accessories',
          emoji: '\u{1F576}',
          source: 'ai',
          imageName: 'tortoise sunglasses',
          imageType: 'sunglasses',
          imageIndex: 0,
        ),
      ];
    }

    if (band == 'cold') {
      return const [
        OutfitItem(
          name: 'Warm Hoodie',
          category: 'Tops',
          emoji: '\u{1F9E5}',
          source: 'ai',
          imageName: 'charcoal warm hoodie',
          imageType: 'hoodie',
          imageIndex: 0,
        ),
        OutfitItem(
          name: 'Dark Jeans',
          category: 'Bottoms',
          emoji: '\u{1F456}',
          source: 'ai',
          imageName: 'dark denim jeans',
          imageType: 'jeans',
          imageIndex: 0,
        ),
        OutfitItem(
          name: 'Leather Boots',
          category: 'Shoes',
          emoji: '\u{1F97E}',
          source: 'ai',
          imageName: 'brown leather boots',
          imageType: 'boots',
          imageIndex: 0,
        ),
        OutfitItem(
          name: 'Puffer Jacket',
          category: 'Jackets',
          emoji: '\u{1F9E5}',
          source: 'ai',
          imageName: 'black puffer jacket',
          imageType: 'jacket',
          imageIndex: 0,
        ),
      ];
    }

    return const [
      OutfitItem(
        name: 'Casual Shirt',
        category: 'Tops',
        emoji: '\u{1F454}',
        source: 'ai',
        imageName: 'light blue casual shirt',
        imageType: 'shirt',
        imageIndex: 0,
      ),
      OutfitItem(
        name: 'Chino Pants',
        category: 'Bottoms',
        emoji: '\u{1F456}',
        source: 'ai',
        imageName: 'navy chino pants',
        imageType: 'pants',
        imageIndex: 0,
      ),
      OutfitItem(
        name: 'White Sneakers',
        category: 'Shoes',
        emoji: '\u{1F45F}',
        source: 'ai',
        imageName: 'white sneakers',
        imageType: 'sneakers',
        imageIndex: 0,
      ),
      OutfitItem(
        name: 'Gray Cardigan',
        category: 'Jackets',
        emoji: '\u{1F9E5}',
        source: 'ai',
        imageName: 'gray cardigan sweater',
        imageType: 'cardigan',
        imageIndex: 0,
      ),
    ];
  }

  List<OutfitItem> _fallbackItems({
    required String mode,
    required _WardrobeIndex wardrobe,
    required String audience,
    String occasion = 'Casual',
    double temperatureC = 24,
  }) {
    final modeLower = mode.toLowerCase();
    final isWardrobeMode = modeLower.contains('use my wardrobe');
    final isMixMode = modeLower.contains('mix');
    final aiFallback = _cohesiveAiFallbackItems(
      audience: audience,
      occasion: occasion,
      temperatureC: temperatureC,
    );

    if (isWardrobeMode) {
      if (wardrobe.items.isNotEmpty) {
        return wardrobe.items.take(4).map((w) {
          return OutfitItem(
            name: w.name,
            category: w.category,
            emoji: _safeEmoji(w.emoji ?? '', w.category),
            source: 'wardrobe',
            wardrobeId: w.id,
            imageName: null,
            imageType: null,
            imageIndex: null,
          );
        }).toList();
      }
      return const [];
    }

    if (isMixMode) {
      final fromWardrobe = wardrobe.items.take(2).map((w) {
        return OutfitItem(
          name: w.name,
          category: w.category,
          emoji: w.emoji ?? '\u{1F455}',
          source: 'wardrobe',
          wardrobeId: w.id,
          imageName: null,
          imageType: null,
          imageIndex: null,
        );
      }).toList();

      return [...fromWardrobe, ...aiFallback].take(4).toList();
    }

    return aiFallback;
  }
}

class _RawSuggestionItem {
  final String name;
  final String category;
  final String color;
  final String emoji;
  final String source;
  final String? wardrobeId;
  final String? imageName;
  final String? imageType;
  final int? imageIndex;

  const _RawSuggestionItem({
    required this.name,
    required this.category,
    required this.color,
    required this.emoji,
    required this.source,
    required this.wardrobeId,
    required this.imageName,
    required this.imageType,
    required this.imageIndex,
  });
}

class _WardrobeRef {
  final String id;
  final String name;
  final String category;
  final String? color;
  final String? brand;
  final String? emoji;

  const _WardrobeRef({
    required this.id,
    required this.name,
    required this.category,
    required this.color,
    required this.brand,
    required this.emoji,
  });

  static const empty = _WardrobeRef(
    id: '',
    name: '',
    category: '',
    color: null,
    brand: null,
    emoji: null,
  );

  bool get isEmpty => id.isEmpty;
}

/// Indexes the user's raw wardrobe data for fast lookup by ID and ordered iteration.
class _WardrobeIndex {
  final List<_WardrobeRef> items;
  final Map<String, _WardrobeRef> byId;

  const _WardrobeIndex({required this.items, required this.byId});

  factory _WardrobeIndex.fromRaw(List<Map<String, dynamic>> raw) {
    final items = <_WardrobeRef>[];
    final byId = <String, _WardrobeRef>{};

    for (final item in raw) {
      final id = item['id']?.toString().trim() ?? '';
      final name = item['name']?.toString().trim() ?? '';
      final category = item['category']?.toString().trim() ?? '';
      if (id.isEmpty || name.isEmpty || category.isEmpty) continue;

      final ref = _WardrobeRef(
        id: id,
        name: name,
        category: category,
        color: item['color']?.toString().trim(),
        brand: item['brand']?.toString().trim(),
        emoji: item['emoji']?.toString().trim(),
      );

      items.add(ref);
      byId[id] = ref;
    }

    return _WardrobeIndex(items: items, byId: byId);
  }
}
