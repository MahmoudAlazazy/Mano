import 'dart:convert';
import 'dart:developer' as developer;

import 'gemini_service.dart';

class OutfitSuggestion {
  final List<OutfitItem> items;
  final List<String> suggestedWardrobeIds;

  const OutfitSuggestion({
    required this.items,
    required this.suggestedWardrobeIds,
  });
}

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

class OutfitSuggestionService {
  OutfitSuggestionService({GeminiService? gemini})
    : _gemini = gemini ?? GeminiService();

  final GeminiService _gemini;

  void _terminalDebug(String message) {
    developer.log(message, name: 'OutfitSuggestionService');
    // ignore: avoid_print
    print('[OutfitSuggestionService] $message');
  }

  Future<OutfitSuggestion> generate({
    required String mode,
    required String occasion,
    required List<Map<String, dynamic>> wardrobeItems,
    required String governorate,
    required double temperatureC,
  }) async {
    final wardrobe = _WardrobeIndex.fromRaw(wardrobeItems);
    try {
      final prompt = _buildPrompt(
        mode: mode,
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
      );

      if (resolvedItems.isEmpty) {
        resolvedItems = _fallbackItems(mode: mode, wardrobe: wardrobe);
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
      return _buildSafeFallbackSuggestion(mode: mode, wardrobe: wardrobe);
    }
  }

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
- If Mode is "Use My Wardrobe":
  - Prefer ONLY wardrobe items.
  - Always include wardrobe_id when using wardrobe source.
- If Mode is "Mix & Match":
  - Include exactly 2 wardrobe items (source=wardrobe, with wardrobe_id).
  - Include exactly 2 missing suggestions (source=ai, wardrobe_id=null).
- If Mode is "Full Outfit Suggestion":
  - Use source=ai only.
- For wardrobe items, use exact IDs from the provided list.
- For AI items, include:
  - image_name: short searchable phrase that will be sent directly as the `name` query parameter to this endpoint:
    GET /api/v1/clothing/image?name=...&type=...
  - image_type: short type that will be sent directly as the `type` query parameter.
  - image_index: integer (usually 0)
  - Keep image_name plain text only, short, searchable, and product-like.
  - Do not return sentences in image_name.
Examples of valid AI search fields:
  - image_name="nike hoodie", image_type="hoodie"
  - image_name="adidas running shoes", image_type="shoes"
  - image_name="levis 501", image_type="jeans"
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

  List<OutfitItem> _resolveItemsForMode({
    required String mode,
    required List<_RawSuggestionItem> parsedItems,
    required _WardrobeIndex wardrobe,
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
    );
    final exactFour = _ensureExactlyFourItems(
      mode: mode,
      items: enforced,
      wardrobe: wardrobe,
      usedWardrobeIds: usedWardrobeIds,
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
      var wardrobeCount = out.where((e) => e.source == 'wardrobe').length;
      var aiCount = out.where((e) => e.source == 'ai').length;

      while (wardrobeCount < 2) {
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
            imageName: 'light jacket',
            imageType: 'jacket',
            imageIndex: 0,
          ),
        );
        aiCount++;
      }

      if (out.length < 4) {
        out.addAll(_fallbackItems(mode: mode, wardrobe: wardrobe));
      }

      if (out.length > 4) {
        out = out.take(4).toList();
      }

      return out;
    }

    if (out.isEmpty) {
      return _fallbackItems(mode: mode, wardrobe: wardrobe);
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
      ).where((e) => e.source == 'ai'),
      const OutfitItem(
        name: 'Layered Jacket',
        category: 'Jackets',
        emoji: '\u{1F9E5}',
        source: 'ai',
        imageName: 'lightweight jacket',
        imageType: 'jacket',
        imageIndex: 0,
      ),
      const OutfitItem(
        name: 'Minimal Watch',
        category: 'Accessories',
        emoji: '\u{231A}',
        source: 'ai',
        imageName: 'minimal wrist watch',
        imageType: 'watch',
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
        const OutfitItem(
          name: 'Essential Piece',
          category: 'Tops',
          emoji: '\u{1F455}',
          source: 'ai',
          imageName: 'basic top',
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
        final wardrobeCount = out.where((e) => e.source == 'wardrobe').length;
        final aiCount = out.where((e) => e.source == 'ai').length;

        if (wardrobeCount < 2) {
          final before = out.length;
          addWardrobeItem();
          if (out.length == before) addAiItem();
          continue;
        }

        if (aiCount < 2) {
          addAiItem();
          continue;
        }

        final before = out.length;
        addWardrobeItem();
        if (out.length == before) addAiItem();
        continue;
      }

      addAiItem();
    }

    return out.take(4).toList();
  }

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
        c.contains('short')) {
      return 'bottoms';
    }
    if (c.contains('shoe') ||
        c.contains('sneaker') ||
        c.contains('boot') ||
        c.contains('loafer')) {
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
        c.contains('bag')) {
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
  }) {
    final items = _fallbackItems(mode: mode, wardrobe: wardrobe);
    final selectedIds = items
        .where((item) => item.wardrobeId != null && item.wardrobeId!.isNotEmpty)
        .map((item) => item.wardrobeId!)
        .where(wardrobe.byId.containsKey)
        .toSet()
        .toList();
    return OutfitSuggestion(items: items, suggestedWardrobeIds: selectedIds);
  }

  List<OutfitItem> _fallbackItems({
    required String mode,
    required _WardrobeIndex wardrobe,
  }) {
    final modeLower = mode.toLowerCase();
    final isWardrobeMode = modeLower.contains('use my wardrobe');
    final isMixMode = modeLower.contains('mix');

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

      return [
        ...fromWardrobe,
        const OutfitItem(
          name: 'Suggested Jacket',
          category: 'Jackets',
          emoji: '\u{1F9E5}',
          source: 'ai',
          imageName: 'light jacket',
          imageType: 'jacket',
          imageIndex: 0,
        ),
        const OutfitItem(
          name: 'Suggested Sneakers',
          category: 'Shoes',
          emoji: '\u{1F45F}',
          source: 'ai',
          imageName: 'white sneakers',
          imageType: 'shoes',
          imageIndex: 0,
        ),
        const OutfitItem(
          name: 'Suggested Accessory',
          category: 'Accessories',
          emoji: '\u{1F9E2}',
          source: 'ai',
          imageName: 'fashion accessory',
          imageType: 'accessory',
          imageIndex: 0,
        ),
      ].take(4).toList();
    }

    return const [
      OutfitItem(
        name: 'Linen Crew Tee',
        category: 'Tops',
        emoji: '\u{1F455}',
        source: 'ai',
        imageName: 'white linen t-shirt',
        imageType: 'tshirt',
        imageIndex: 0,
      ),
      OutfitItem(
        name: 'Tailored Shorts',
        category: 'Bottoms',
        emoji: '\u{1FA73}',
        source: 'ai',
        imageName: 'tailored shorts',
        imageType: 'shorts',
        imageIndex: 0,
      ),
      OutfitItem(
        name: 'Suede Loafers',
        category: 'Shoes',
        emoji: '\u{1F45E}',
        source: 'ai',
        imageName: 'suede loafers',
        imageType: 'loafers',
        imageIndex: 0,
      ),
      OutfitItem(
        name: 'Light Jacket',
        category: 'Jackets',
        emoji: '\u{1F9E5}',
        source: 'ai',
        imageName: 'light jacket',
        imageType: 'jacket',
        imageIndex: 0,
      ),
    ];
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
