import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class ClothingImageService {
  ClothingImageService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const bool _useExternalApi = bool.fromEnvironment(
    'CLOTHING_IMAGE_USE_EXTERNAL_API',
    defaultValue: false,
  );

  static const String _baseUrls = String.fromEnvironment(
    'CLOTHING_IMAGE_API_BASE_URLS',
    defaultValue: '',
  );

  static const String _baseUrl = String.fromEnvironment(
    'CLOTHING_IMAGE_API_BASE_URL',
    defaultValue: '',
  );

  static const String _imagePath = '/api/v1/clothing/image';
  static const Duration _primaryRequestTimeout = Duration(seconds: 12);
  static const Duration _secondaryRequestTimeout = Duration(seconds: 5);
  static const Duration _searchTimeout = Duration(seconds: 8);
  static const Duration _imageDownloadTimeout = Duration(seconds: 12);
  static const Duration _fallbackTimeout = Duration(seconds: 6);
  static const Duration _healthDownloadTimeout = Duration(seconds: 8);
  static const bool _allowGenericFallback = bool.fromEnvironment(
    'CLOTHING_IMAGE_ALLOW_FALLBACK',
    defaultValue: true,
  );

  static const Map<String, String> _browserHeaders = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/124.0.0.0 Safari/537.36',
    'Accept-Language': 'en-US,en;q=0.9',
  };

  static const Map<String, String> _htmlHeaders = {
    ..._browserHeaders,
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  };

  static const Map<String, String> _jsonHeaders = {
    ..._browserHeaders,
    'Accept': 'application/json,text/javascript,*/*;q=0.8',
    'ngrok-skip-browser-warning': 'true',
  };

  static const Map<String, String> _imageHeaders = {
    ..._browserHeaders,
    'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
    'ngrok-skip-browser-warning': 'true',
  };

  static const Set<String> _skipDomains = {
    'gstatic.com',
    'google.com',
    'googleapis.com',
    'googleusercontent.com',
    'google-analytics.com',
    'schema.org',
    'w3.org',
    'duckduckgo.com',
    'bing.com',
  };

  void _terminalDebug(String message) {
    developer.log(message, name: 'ClothingImageService');
    // ignore: avoid_print
    print('[ClothingImageService] $message');
  }

  List<String> get _candidateBaseUrls {
    if (!_useExternalApi) return <String>[];

    final configured = <String>[
      if (_baseUrls.trim().isNotEmpty) ..._baseUrls.split(','),
      if (_baseUrl.trim().isNotEmpty) _baseUrl,
    ];
    final raw = <String>[
      ...configured,
      if (configured.isEmpty) 'http://10.0.2.2:8000',
      if (configured.isEmpty) 'http://127.0.0.1:8000',
      if (configured.isEmpty) 'http://localhost:8000',
    ];
    final unique = <String>{};
    final out = <String>[];
    for (final value in raw) {
      final v = value.trim().replaceAll(RegExp(r'/$'), '');
      if (v.isEmpty) continue;
      if (unique.add(v)) out.add(v);
    }
    return out;
  }

  Uri buildImageUri({required String name, String? type, int? index}) {
    final bases = _candidateBaseUrls;
    if (bases.isNotEmpty) {
      return buildImageUriForBase(
        baseUrl: bases.first,
        name: name,
        type: type,
        index: index,
      );
    }
    return _internalImageUri(name: name, type: type, index: index);
  }

  Uri buildImageUriForBase({
    required String baseUrl,
    required String name,
    String? type,
    int? index,
  }) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final uri = Uri.parse('$base$_imagePath');
    final params = <String, String>{'name': name};
    if (type != null && type.trim().isNotEmpty) {
      params['type'] = type.trim();
    }
    if (index != null && index >= 0) {
      params['index'] = '$index';
    }
    return uri.replace(queryParameters: params);
  }

  Uri _internalImageUri({required String name, String? type, int? index}) {
    return Uri(
      scheme: 'clothing-search',
      host: 'image',
      queryParameters: <String, String>{
        'name': name,
        if (type != null && type.trim().isNotEmpty) 'type': type.trim(),
        if (index != null && index >= 0) 'index': '$index',
      },
    );
  }

  bool _shouldSkipUrl(String url) {
    try {
      final parsed = Uri.parse(url);
      final host = parsed.host.toLowerCase();
      if (parsed.scheme != 'http' && parsed.scheme != 'https') return true;
      if (host.isEmpty) return true;
      return _skipDomains.any(host.contains);
    } catch (_) {
      return true;
    }
  }

  String _decodeSearchUrl(String raw) {
    var value = raw
        .replaceAll(r'\/', '/')
        .replaceAll(r'\u0026', '&')
        .replaceAll(r'\u003d', '=')
        .replaceAll(r'\u002f', '/')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');

    try {
      value = Uri.decodeFull(value);
    } catch (_) {
      // Keep the original value when a search engine returns a partial escape.
    }
    return value;
  }

  List<_ImageSearchHit> _dedupeHits(Iterable<_ImageSearchHit> hits) {
    final seen = <String>{};
    final out = <_ImageSearchHit>[];
    for (final hit in hits) {
      final url = _decodeSearchUrl(hit.url.trim());
      if (url.isEmpty || _shouldSkipUrl(url)) continue;
      if (seen.add(url)) {
        out.add(
          _ImageSearchHit(
            url: url,
            title: hit.title,
            pageUrl: hit.pageUrl,
            source: hit.source,
          ),
        );
      }
    }
    return out;
  }

  String? _detectImageMime(Uint8List bytes) {
    if (bytes.length < 8) return null;
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      return 'image/png';
    }
    if (bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        (bytes[3] == 0x38 && (bytes[4] == 0x37 || bytes[4] == 0x39))) {
      return 'image/gif';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'image/webp';
    }
    if (bytes[0] == 0x42 && bytes[1] == 0x4D) {
      return 'image/bmp';
    }
    return null;
  }

  List<String> _typeKeywords(String name, String type) {
    final text = '${name.toLowerCase()} ${type.toLowerCase()}';
    if (text.contains('watch')) {
      return const ['watch', 'wrist', 'chronograph'];
    }
    if (text.contains('sunglass')) {
      return const ['sunglass', 'eyewear', 'aviator'];
    }
    if (text.contains('cap') || text.contains('hat')) {
      return const ['cap', 'hat', 'snapback'];
    }
    if (text.contains('shoe') ||
        text.contains('sneaker') ||
        text.contains('loafer') ||
        text.contains('boot') ||
        text.contains('sandal') ||
        text.contains('heel') ||
        text.contains('flat')) {
      return const [
        'shoe',
        'sneaker',
        'loafer',
        'boot',
        'sandal',
        'heel',
        'flat',
        'footwear',
      ];
    }
    if (text.contains('pant') ||
        text.contains('trouser') ||
        text.contains('jean') ||
        text.contains('short') ||
        text.contains('jogger') ||
        text.contains('skirt') ||
        text.contains('legging')) {
      return const [
        'pant',
        'trouser',
        'jean',
        'short',
        'jogger',
        'skirt',
        'legging',
        'bottom',
      ];
    }
    if (text.contains('jacket') ||
        text.contains('coat') ||
        text.contains('hoodie') ||
        text.contains('sweater') ||
        text.contains('cardigan')) {
      return const ['jacket', 'coat', 'hoodie', 'sweater', 'outerwear'];
    }
    if (text.contains('dress')) {
      return const ['dress', 'gown'];
    }
    if (text.contains('shirt') ||
        text.contains('tee') ||
        text.contains('top') ||
        text.contains('blouse')) {
      return const ['shirt', 'tee', 'top', 'blouse'];
    }
    if (text.contains('acc') ||
        text.contains('bag') ||
        text.contains('belt') ||
        text.contains('scarf')) {
      return const ['accessory', 'bag', 'belt', 'scarf'];
    }
    return const ['clothing'];
  }

  List<String> _nameKeywords(String name) {
    final stop = <String>{
      'for',
      'with',
      'and',
      'outfit',
      'fashion',
      'style',
      'casual',
      'formal',
      'business',
      'sport',
      'sports',
      'the',
      'new',
    };
    return name
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((t) => t.length >= 4 && !stop.contains(t))
        .toList();
  }

  List<String> _negativeKeywords(String name, String type) {
    final text = '${name.toLowerCase()} ${type.toLowerCase()}';
    final negatives = <String>[];

    if (text.contains('women') ||
        text.contains("women's") ||
        text.contains('woman') ||
        text.contains('female') ||
        text.contains('girl')) {
      negatives.addAll([' men ', " men's ", 'male', 'boy']);
    } else if (text.contains('men') ||
        text.contains("men's") ||
        text.contains('man') ||
        text.contains('male') ||
        text.contains('boy')) {
      negatives.addAll(['women', "women's", 'female', 'girl', 'dress']);
    }

    if (text.contains('watch')) {
      negatives.addAll(['shoe', 'boot', 'jean', 'sunglass', 'dress']);
      return negatives;
    }
    if (text.contains('sunglass')) {
      negatives.addAll(['watch', 'shoe', 'boot', 'jean']);
      return negatives;
    }
    if (text.contains('loafer') ||
        text.contains('oxford') ||
        text.contains('derby')) {
      negatives.addAll(['sneaker', 'trainer', 'running', 'nike', 'adidas']);
      return negatives;
    }
    if (text.contains('shoe') ||
        text.contains('sneaker') ||
        text.contains('boot')) {
      negatives.addAll(['watch', 'sunglass', 'dress']);
      return negatives;
    }
    if (text.contains('short')) {
      negatives.addAll(['jean', 'trouser', 'pants', 'legging']);
      return negatives;
    }
    if (text.contains('pant') ||
        text.contains('jean') ||
        text.contains('short') ||
        text.contains('jogger')) {
      negatives.addAll(['watch', 'sunglass', 'shoe']);
      return negatives;
    }
    if (text.contains('dress')) {
      negatives.addAll(['shirt', 'tshirt', 'pants', 'shorts', 'men']);
      return negatives;
    }
    if (text.contains('shirt') ||
        text.contains('tee') ||
        text.contains('top') ||
        text.contains('hoodie') ||
        text.contains('jacket')) {
      negatives.addAll(['watch', 'sunglass']);
      return negatives;
    }
    negatives.addAll(['watch', 'sunglass']);
    return negatives;
  }

  String _normalizedType(String name, String type) {
    final text = '${name.toLowerCase()} ${type.toLowerCase()}';
    if (text.contains('watch')) return 'watch';
    if (text.contains('sunglass')) return 'sunglasses';
    if (text.contains('cap') || text.contains('hat')) return 'cap';
    if (text.contains('shoe') ||
        text.contains('sneaker') ||
        text.contains('loafer') ||
        text.contains('boot') ||
        text.contains('sandal') ||
        text.contains('heel') ||
        text.contains('flat')) {
      return 'shoes';
    }
    if (text.contains('pant') ||
        text.contains('trouser') ||
        text.contains('jean') ||
        text.contains('short') ||
        text.contains('jogger') ||
        text.contains('bottom') ||
        text.contains('skirt') ||
        text.contains('legging')) {
      return 'pants';
    }
    if (text.contains('jacket') ||
        text.contains('coat') ||
        text.contains('hoodie') ||
        text.contains('blazer') ||
        text.contains('outer')) {
      return 'jacket';
    }
    if (text.contains('dress')) return 'dress';
    if (text.contains('shirt') ||
        text.contains('tee') ||
        text.contains('top') ||
        text.contains('blouse') ||
        text.contains('sweater') ||
        text.contains('cardigan')) {
      return 'top';
    }
    if (text.contains('acc') ||
        text.contains('accessory') ||
        text.contains('bag') ||
        text.contains('belt') ||
        text.contains('scarf')) {
      return 'accessory';
    }
    return 'clothes';
  }

  String _scoreText(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'%[0-9a-f]{2}', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  bool _containsScorePhrase(String haystack, String phrase) {
    final normalizedPhrase = _scoreText(phrase);
    if (normalizedPhrase.isEmpty) return false;
    return ' $haystack '.contains(' $normalizedPhrase ');
  }

  List<String> _strictTypeKeywords(String name, String type) {
    final text = '${name.toLowerCase()} ${type.toLowerCase()}';
    if (text.contains('loafer')) return const ['loafer', 'loafers'];
    if (text.contains('sneaker')) {
      return const ['sneaker', 'sneakers', 'trainer', 'trainers'];
    }
    if (text.contains('boot')) return const ['boot', 'boots', 'chelsea'];
    if (text.contains('sandal')) return const ['sandal', 'sandals'];
    if (text.contains('heel')) return const ['heel', 'heels'];
    if (text.contains('flat')) return const ['flat', 'flats'];
    if (text.contains('short')) return const ['short', 'shorts'];
    if (text.contains('jean')) return const ['jean', 'jeans', 'denim'];
    if (text.contains('legging')) return const ['legging', 'leggings'];
    if (text.contains('skirt')) return const ['skirt'];
    if (text.contains('chino')) return const ['chino', 'chinos'];
    if (text.contains('pant') || text.contains('trouser')) {
      return const ['pant', 'pants', 'trouser', 'trousers'];
    }
    if (text.contains('dress')) return const ['dress', 'gown'];
    if (text.contains('blouse')) return const ['blouse'];
    if (text.contains('tshirt') ||
        text.contains('t-shirt') ||
        text.contains('tee')) {
      return const ['tshirt', 't shirt', 'tee'];
    }
    if (text.contains('shirt')) return const ['shirt'];
    if (text.contains('jacket')) return const ['jacket'];
    if (text.contains('blazer')) return const ['blazer'];
    if (text.contains('coat')) return const ['coat'];
    if (text.contains('hoodie')) return const ['hoodie'];
    if (text.contains('sweater')) return const ['sweater'];
    if (text.contains('cardigan')) return const ['cardigan'];
    if (text.contains('sunglass')) return const ['sunglass', 'sunglasses'];
    if (text.contains('watch')) return const ['watch'];
    if (text.contains('bag')) return const ['bag', 'handbag', 'tote', 'clutch'];
    if (text.contains('cap') || text.contains('hat')) {
      return const ['cap', 'hat'];
    }
    return _typeKeywords(name, type);
  }

  List<String> _conflictingTypeKeywords(String name, String type) {
    final text = '${name.toLowerCase()} ${type.toLowerCase()}';
    if (text.contains('loafer')) {
      return const ['sneaker', 'sneakers', 'trainer', 'running shoe'];
    }
    if (text.contains('sneaker')) {
      return const ['loafer', 'boot', 'dress shoe', 'tshirt', 'shirt'];
    }
    if (text.contains('short')) {
      return const ['pants', 'trouser', 'trousers', 'jeans', 'leggings'];
    }
    if (text.contains('pant') || text.contains('trouser')) {
      return const ['shorts', 'dress', 'skirt'];
    }
    if (text.contains('dress')) {
      return const ['shirt', 'tshirt', 'tee', 'pants', 'shorts'];
    }
    if (text.contains('shirt') ||
        text.contains('tee') ||
        text.contains('blouse') ||
        text.contains('top')) {
      return const ['shorts', 'pants', 'shoes', 'sneakers', 'dress'];
    }
    if (text.contains('jacket') || text.contains('coat')) {
      return const ['shirt', 'tshirt', 'pants', 'shoes'];
    }
    if (text.contains('watch')) {
      return const ['shoe', 'shirt', 'pants', 'dress'];
    }
    if (text.contains('sunglass')) {
      return const ['shoe', 'shirt', 'pants', 'watch'];
    }
    return const <String>[];
  }

  int _scoreImageHit({
    required _ImageSearchHit hit,
    required String name,
    required String type,
    required List<String> positives,
    required List<String> negatives,
  }) {
    final text = _scoreText(
      '${hit.url} ${hit.title ?? ''} ${hit.pageUrl ?? ''} ${hit.source ?? ''}',
    );
    var score = 0;
    var positiveHits = 0;

    for (final p in positives) {
      if (_containsScorePhrase(text, p)) {
        score += 2;
        positiveHits++;
      }
    }

    final strictTokens = _strictTypeKeywords(name, type);
    final strictTypeHit = strictTokens.any((token) {
      return _containsScorePhrase(text, token);
    });
    final typeTokens = _typeKeywords('', type);
    final typeHit = typeTokens.any((token) => _containsScorePhrase(text, token));
    if (strictTypeHit) {
      score += 12;
    } else if (typeHit) {
      score += 5;
    } else {
      score -= 8;
    }

    for (final n in negatives) {
      if (_containsScorePhrase(text, n)) score -= 10;
    }
    for (final n in _conflictingTypeKeywords(name, type)) {
      if (_containsScorePhrase(text, n)) score -= 12;
    }
    if (positiveHits == 0) {
      score -= 3;
    }
    final url = hit.url.toLowerCase();
    if (url.contains('.jpg') ||
        url.contains('.jpeg') ||
        url.contains('.png') ||
        url.contains('.webp')) {
      score += 1;
    }
    return score;
  }

  String? _normalizedAudience(String? audience) {
    final value = audience?.toLowerCase().trim();
    if (value == null || value.isEmpty) return null;
    if (value.contains('women') ||
        value.contains('female') ||
        value.contains('girl')) {
      return "women's";
    }
    if (value.contains('men') || value.contains('male') || value.contains('boy')) {
      return "men's";
    }
    return null;
  }

  String _audienceQualifiedName(String name, String? audience) {
    final normalized = _normalizedAudience(audience);
    var trimmed = name.trim();
    if (normalized == null || trimmed.isEmpty) return trimmed;
    if (normalized == "women's") {
      trimmed = trimmed
          .replaceAll(
            RegExp(r"\bmen'?s?\b|\bmale\b|\bboys?\b", caseSensitive: false),
            '',
          )
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    } else {
      trimmed = trimmed
          .replaceAll(
            RegExp(r"\bwomen'?s?\b|\bfemale\b|\bgirls?\b", caseSensitive: false),
            '',
          )
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }
    final lower = trimmed.toLowerCase();
    final hasTargetAudience = normalized == "women's"
        ? (lower.contains('women') ||
              lower.contains('female') ||
              lower.contains('girl'))
        : (lower.contains('men') || lower.contains('male') || lower.contains('boy'));
    if (hasTargetAudience) {
      return trimmed;
    }
    return '$normalized $trimmed';
  }

  String _buildQuery(String name, String? clothingType, {String? audience}) {
    final qualifiedName = _audienceQualifiedName(name, audience);
    final parts = <String>[qualifiedName];
    if (clothingType != null && clothingType.trim().isNotEmpty) {
      parts.add(clothingType.trim());
    }
    parts.add('single clothing item product photo isolated white background');
    return parts.where((part) => part.trim().isNotEmpty).join(' ');
  }

  Future<List<_ImageSearchHit>> _searchBing(
    String query, {
    int maxResults = 10,
  }) async {
    try {
      final uri = Uri.https('www.bing.com', '/images/search', <String, String>{
        'q': query,
        'form': 'HDRSC2',
        'first': '1',
      });
      final response = await _client
          .get(
            uri,
            headers: const <String, String>{
              ..._htmlHeaders,
              'Referer': 'https://www.bing.com/',
            },
          )
          .timeout(_searchTimeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('HTTP ${response.statusCode}');
      }

      final hits = <_ImageSearchHit>[];
      for (final match in RegExp(
        r'm="({[^"]+})"',
        caseSensitive: false,
      ).allMatches(response.body)) {
        final rawJson = match.group(1);
        if (rawJson == null || rawJson.isEmpty) continue;
        try {
          final decodedJson = jsonDecode(_decodeSearchUrl(rawJson));
          if (decodedJson is! Map<String, dynamic>) continue;
          final imageUrl = decodedJson['murl']?.toString() ??
              decodedJson['imgurl']?.toString() ??
              '';
          if (imageUrl.trim().isEmpty) continue;
          hits.add(
            _ImageSearchHit(
              url: imageUrl,
              title: decodedJson['t']?.toString() ??
                  decodedJson['desc']?.toString(),
              pageUrl: decodedJson['purl']?.toString(),
              source: 'Bing',
            ),
          );
        } catch (_) {
          // Bing occasionally emits partial JSON. Regex fallback below covers it.
        }
      }

      for (final pattern in <RegExp>[
        RegExp(r'"murl":"([^"]+)"', caseSensitive: false),
        RegExp(r'"imgurl":"([^"]+)"', caseSensitive: false),
        RegExp(r'"turl":"([^"]+)"', caseSensitive: false),
        RegExp(r'murl%3a(https?%3a%2f%2f[^&"]+)', caseSensitive: false),
      ]) {
        for (final match in pattern.allMatches(response.body)) {
          final value = match.group(1);
          if (value != null && value.isNotEmpty) {
            hits.add(_ImageSearchHit(url: value, source: 'Bing'));
          }
        }
        if (hits.isNotEmpty) break;
      }

      final unique = _dedupeHits(hits).take(maxResults).toList();
      developer.log(
        'Bing found ${unique.length} image candidates for $query',
        name: 'ClothingImageService',
      );
      return unique;
    } catch (e) {
      developer.log('Bing failed for $query: $e', name: 'ClothingImageService');
      return <_ImageSearchHit>[];
    }
  }

  String? _extractDuckDuckGoVqd(String html) {
    for (final pattern in <RegExp>[
      RegExp("vqd=[\"']?([^&\"'\\s]+)", caseSensitive: false),
      RegExp(r'"vqd":"([^"]+)"', caseSensitive: false),
      RegExp(r"vqd='([^']+)'", caseSensitive: false),
    ]) {
      final match = pattern.firstMatch(html);
      final value = match?.group(1);
      if (value != null && value.trim().isNotEmpty) {
        return value.trim();
      }
    }
    return null;
  }

  Future<List<_ImageSearchHit>> _searchDuckDuckGo(
    String query, {
    int maxResults = 10,
  }) async {
    try {
      final pageUri = Uri.https('duckduckgo.com', '/', <String, String>{
        'q': query,
        'iax': 'images',
        'ia': 'images',
      });
      final pageResponse = await _client
          .get(pageUri, headers: _htmlHeaders)
          .timeout(_searchTimeout);

      if (pageResponse.statusCode < 200 || pageResponse.statusCode >= 300) {
        throw StateError('vqd HTTP ${pageResponse.statusCode}');
      }

      final vqd = _extractDuckDuckGoVqd(pageResponse.body);
      if (vqd == null) {
        throw StateError('missing vqd token');
      }

      final imageUri = Uri.https('duckduckgo.com', '/i.js', <String, String>{
        'l': 'us-en',
        'o': 'json',
        'q': query,
        'vqd': vqd,
        'f': ',,,',
        'p': '1',
      });
      final response = await _client
          .get(
            imageUri,
            headers: const <String, String>{
              ..._jsonHeaders,
              'Referer': 'https://duckduckgo.com/',
            },
          )
          .timeout(_searchTimeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('images HTTP ${response.statusCode}');
      }

      final decoded = jsonDecode(response.body);
      final results = decoded is Map<String, dynamic> ? decoded['results'] : null;
      final hits = <_ImageSearchHit>[];
      if (results is List) {
        for (final raw in results) {
          if (raw is! Map<String, dynamic>) continue;
          final imageUrl = raw['image']?.toString() ?? '';
          if (imageUrl.isNotEmpty) {
            hits.add(
              _ImageSearchHit(
                url: imageUrl,
                title: raw['title']?.toString(),
                pageUrl: raw['url']?.toString(),
                source: raw['source']?.toString() ?? 'DuckDuckGo',
              ),
            );
          }
          if (hits.length >= maxResults * 2) break;
        }
      }

      final unique = _dedupeHits(hits).take(maxResults).toList();
      developer.log(
        'DuckDuckGo found ${unique.length} image candidates for $query',
        name: 'ClothingImageService',
      );
      return unique;
    } catch (e) {
      developer.log(
        'DuckDuckGo failed for $query: $e',
        name: 'ClothingImageService',
      );
      return <_ImageSearchHit>[];
    }
  }

  Future<List<_ImageSearchHit>> _searchGoogle(
    String query, {
    int maxResults = 10,
  }) async {
    try {
      final uri = Uri.https('www.google.com', '/search', <String, String>{
        'q': query,
        'tbm': 'isch',
        'ijn': '0',
        'tbs': 'isz:m',
      });
      final response = await _client
          .get(
            uri,
            headers: const <String, String>{
              ..._browserHeaders,
              'Accept': 'text/html,application/xhtml+xml,application/xml;'
                  'q=0.9,image/webp,*/*;q=0.8',
              'Referer': 'https://www.google.com/',
            },
          )
          .timeout(_searchTimeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('HTTP ${response.statusCode}');
      }

      final hits = <_ImageSearchHit>[];
      final patterns = <RegExp>[
        RegExp(
          r'\["(https?://[^"]+\.(?:jpg|jpeg|png|webp)(?:\?[^"]*)?)",[0-9]+,[0-9]+\]',
          caseSensitive: false,
        ),
        RegExp(
          r'"(https?://[^"]+\.(?:jpg|jpeg|png|webp)(?:\?[^"]*)?)"',
          caseSensitive: false,
        ),
      ];

      for (final pattern in patterns) {
        for (final match in pattern.allMatches(response.body)) {
          final value = match.group(1);
          if (value != null && value.isNotEmpty) {
            hits.add(_ImageSearchHit(url: value, source: 'Google'));
          }
          if (hits.length >= maxResults * 2) break;
        }
        if (hits.length >= maxResults * 2) break;
      }

      final unique = _dedupeHits(hits).take(maxResults).toList();
      developer.log(
        'Google found ${unique.length} image candidates for $query',
        name: 'ClothingImageService',
      );
      return unique;
    } catch (e) {
      developer.log('Google failed for $query: $e', name: 'ClothingImageService');
      return <_ImageSearchHit>[];
    }
  }

  Future<_SearchResult> _searchImages(
    String query, {
    int maxResults = 10,
  }) async {
    final engines =
        <({String name, Future<List<_ImageSearchHit>> Function() run})>[
      (name: 'Bing', run: () => _searchBing(query, maxResults: maxResults)),
      (
        name: 'DuckDuckGo',
        run: () => _searchDuckDuckGo(query, maxResults: maxResults),
      ),
      (name: 'Google', run: () => _searchGoogle(query, maxResults: maxResults)),
    ];

    for (final engine in engines) {
      final urls = await engine.run();
      if (urls.isNotEmpty) {
        return _SearchResult(query: query, engine: engine.name, hits: urls);
      }
      developer.log(
        '${engine.name} returned no image URLs for $query',
        name: 'ClothingImageService',
      );
    }
    return _SearchResult(
      query: query,
      engine: 'none',
      hits: const <_ImageSearchHit>[],
    );
  }

  List<_ImageCandidate> _rankCandidates({
    required List<_ImageSearchHit> hits,
    required String name,
    required String type,
    int? preferredIndex,
    int minConfidenceScore = 0,
  }) {
    final positives = <String>[
      ..._typeKeywords(name, type),
      ..._nameKeywords(name),
    ];
    final negatives = _negativeKeywords(name, type);
    final candidates = <_ImageCandidate>[
      for (var i = 0; i < hits.length; i++)
        _ImageCandidate(
          index: i,
          hit: hits[i],
          score: _scoreImageHit(
            hit: hits[i],
            name: name,
            type: type,
            positives: positives,
            negatives: negatives,
          ),
        ),
    ];

    if (preferredIndex != null && preferredIndex >= 0 && candidates.isNotEmpty) {
      final start = preferredIndex >= candidates.length
          ? candidates.length - 1
          : preferredIndex;
      return <_ImageCandidate>[
        ...candidates.where((candidate) => candidate.index >= start),
        ...candidates.where((candidate) => candidate.index < start),
      ];
    }

    final confident = candidates
        .where((candidate) => candidate.score >= minConfidenceScore)
        .toList()
      ..sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        return byScore == 0 ? a.index.compareTo(b.index) : byScore;
      });
    final rest = candidates
        .where((candidate) => candidate.score < minConfidenceScore)
        .toList();

    if (minConfidenceScore > 0 && confident.isEmpty) {
      return const <_ImageCandidate>[];
    }
    if (confident.isEmpty) return candidates;
    return <_ImageCandidate>[...confident, ...rest];
  }

  Future<_DownloadedImage> _downloadImageUrl(
    _ImageCandidate candidate, {
    Duration timeout = _imageDownloadTimeout,
  }) async {
    final uri = Uri.parse(candidate.url);
    final response = await _client
        .get(uri, headers: _imageHeaders)
        .timeout(timeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('HTTP ${response.statusCode}');
    }
    if (response.bodyBytes.isEmpty) {
      throw StateError('empty body');
    }

    final mimeType = _detectImageMime(response.bodyBytes);
    if (mimeType == null) {
      final contentType = response.headers['content-type'] ?? 'unknown';
      throw StateError('non-image response ($contentType)');
    }

    return _DownloadedImage(
      bytes: response.bodyBytes,
      mimeType: mimeType,
      sourceUrl: candidate.url,
      resultIndex: candidate.index,
      score: candidate.score,
    );
  }

  Future<_DownloadSelection> _downloadFirstValidImage({
    required List<_ImageSearchHit> hits,
    required String name,
    required String type,
    int? preferredIndex,
    int? maxAttempts,
    int minConfidenceScore = 0,
    Duration timeout = _imageDownloadTimeout,
  }) async {
    final candidates = _rankCandidates(
      hits: hits,
      name: name,
      type: type,
      preferredIndex: preferredIndex,
      minConfidenceScore: minConfidenceScore,
    );

    String? lastError;
    var attempts = 0;
    for (final candidate in candidates) {
      if (maxAttempts != null && attempts >= maxAttempts) break;
      attempts++;
      try {
        final image = await _downloadImageUrl(candidate, timeout: timeout);
        return _DownloadSelection(image: image, attempts: attempts);
      } catch (e) {
        lastError = 'Image ${candidate.index} failed: $e';
        developer.log(lastError, name: 'ClothingImageService');
      }
    }

    return _DownloadSelection(
      attempts: attempts,
      error: lastError ?? 'No downloadable image candidates',
    );
  }

  Future<ClothingImageFetchResult> _tryFetchImageFromExternalUri({
    required Uri uri,
    required Duration timeout,
  }) async {
    final stopwatch = Stopwatch()..start();
    _terminalDebug('External image API request started: $uri');

    try {
      final response = await _client
          .get(uri, headers: _imageHeaders)
          .timeout(timeout);

      final elapsedMs = stopwatch.elapsedMilliseconds;
      if (response.statusCode != 200) {
        final detail = _extractApiDetail(response);
        final msg = detail == null
            ? 'HTTP ${response.statusCode} from $uri after ${elapsedMs}ms'
            : 'HTTP ${response.statusCode} from $uri after ${elapsedMs}ms: $detail';
        _terminalDebug(msg);
        return ClothingImageFetchResult(
          bytes: null,
          requestUri: uri,
          statusCode: response.statusCode,
          error: msg,
        );
      }

      final mimeType = _detectImageMime(response.bodyBytes);
      if (mimeType == null) {
        final contentType = response.headers['content-type'] ?? 'unknown';
        final msg = 'Non-image response ($contentType) from $uri';
        _terminalDebug(msg);
        return ClothingImageFetchResult(
          bytes: null,
          requestUri: uri,
          statusCode: response.statusCode,
          error: msg,
        );
      }

      final sourceImageUrl = response.headers['x-image-source']?.trim();
      final apiSearchQuery = response.headers['x-search-query']?.trim();
      final apiSearchEngine = response.headers['x-search-engine']?.trim();
      final rawResultIndex = response.headers['x-result-index']?.trim();
      final apiResultIndex = int.tryParse(rawResultIndex ?? '');

      _terminalDebug(
        'External image API succeeded: $uri after ${elapsedMs}ms '
        '(${response.bodyBytes.length} bytes)',
      );
      return ClothingImageFetchResult(
        bytes: response.bodyBytes,
        requestUri: uri,
        statusCode: response.statusCode,
        sourceImageUrl: sourceImageUrl,
        apiSearchQuery: apiSearchQuery,
        apiSearchEngine: apiSearchEngine,
        apiResultIndex: apiResultIndex,
        isGenericFallback: false,
      );
    } on TimeoutException {
      final msg =
          'Timeout contacting $uri after ${stopwatch.elapsedMilliseconds}ms';
      _terminalDebug(msg);
      return ClothingImageFetchResult(
        bytes: null,
        requestUri: uri,
        statusCode: null,
        error: msg,
      );
    } catch (e) {
      final msg =
          'Request exception for $uri after ${stopwatch.elapsedMilliseconds}ms: $e';
      _terminalDebug(msg);
      return ClothingImageFetchResult(
        bytes: null,
        requestUri: uri,
        statusCode: null,
        error: msg,
      );
    }
  }

  Future<ClothingImageFetchResult?> _fetchFromExternalApi({
    required String name,
    required String type,
    int? index,
  }) async {
    if (_candidateBaseUrls.isEmpty) return null;

    final directIndices = <int>{
      if (index != null && index >= 0) index else 0,
      if (index == null) 1,
    }.toList();

    ClothingImageFetchResult? lastResult;
    for (var baseIndex = 0; baseIndex < _candidateBaseUrls.length; baseIndex++) {
      final base = _candidateBaseUrls[baseIndex];
      final timeout = baseIndex == 0
          ? _primaryRequestTimeout
          : _secondaryRequestTimeout;
      for (final directIndex in directIndices) {
        final uri = buildImageUriForBase(
          baseUrl: base,
          name: name,
          type: type,
          index: directIndex,
        );
        final result = await _tryFetchImageFromExternalUri(
          uri: uri,
          timeout: timeout,
        );
        if (result.isSuccess) return result;
        lastResult = result;
      }
    }
    return lastResult;
  }

  String? _extractApiDetail(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        final detail = decoded['detail']?.toString();
        if (detail != null && detail.trim().isNotEmpty) {
          return detail.trim();
        }
      }
    } catch (_) {
      // Keep silent on parsing errors.
    }
    return null;
  }

  Uri _fallbackImageUri({required String name, required String type}) {
    final t = '${name.toLowerCase().trim()} ${type.toLowerCase().trim()}';

    if (t.contains('watch')) {
      return Uri.parse(
        'https://images.unsplash.com/photo-1523170335258-f5ed11844a49'
        '?auto=format&fit=crop&w=900&q=80',
      );
    }
    if (t.contains('sunglass')) {
      return Uri.parse(
        'https://images.unsplash.com/photo-1511499767150-a48a237f0083'
        '?auto=format&fit=crop&w=900&q=80',
      );
    }
    if (t.contains('cap') || t.contains('hat')) {
      return Uri.parse(
        'https://images.unsplash.com/photo-1575428652377-a2d80e2277fc'
        '?auto=format&fit=crop&w=900&q=80',
      );
    }
    if (t.contains('top') || t.contains('shirt') || t.contains('tee')) {
      return Uri.parse(
        'https://images.unsplash.com/photo-1521572163474-6864f9cf17ab'
        '?auto=format&fit=crop&w=900&q=80',
      );
    }
    if (t.contains('short') ||
        t.contains('pant') ||
        t.contains('jean') ||
        t.contains('bottom')) {
      return Uri.parse(
        'https://images.unsplash.com/photo-1473966968600-fa801b869a1a'
        '?auto=format&fit=crop&w=900&q=80',
      );
    }
    if (t.contains('dress')) {
      return Uri.parse(
        'https://images.unsplash.com/photo-1496747611176-843222e1e57c'
        '?auto=format&fit=crop&w=900&q=80',
      );
    }
    if (t.contains('shoe') || t.contains('sneaker') || t.contains('boot')) {
      return Uri.parse(
        'https://images.unsplash.com/photo-1542291026-7eec264c27ff'
        '?auto=format&fit=crop&w=900&q=80',
      );
    }
    if (t.contains('hoodie') ||
        t.contains('jacket') ||
        t.contains('coat') ||
        t.contains('sweater') ||
        t.contains('cardigan')) {
      return Uri.parse(
        'https://images.unsplash.com/photo-1521223890158-f9f7c3d5d504'
        '?auto=format&fit=crop&w=900&q=80',
      );
    }
    if (t.contains('accessory') || t.contains('bag') || t.contains('belt')) {
      return Uri.parse(
        'https://images.unsplash.com/photo-1594223274512-ad4803739b7c'
        '?auto=format&fit=crop&w=900&q=80',
      );
    }

    return Uri.parse(
      'https://images.unsplash.com/photo-1445205170230-053b83016050'
      '?auto=format&fit=crop&w=900&q=80',
    );
  }

  Future<Uint8List?> _fetchFallbackImageBytes({
    required String name,
    required String type,
  }) async {
    final uri = _fallbackImageUri(name: name, type: type);
    try {
      final response = await _client
          .get(uri, headers: _imageHeaders)
          .timeout(_fallbackTimeout);

      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        developer.log(
          'Fallback image failed: HTTP ${response.statusCode} for $uri',
          name: 'ClothingImageService',
        );
        return null;
      }
      return response.bodyBytes;
    } catch (e) {
      developer.log(
        'Fallback image exception for $uri: $e',
        name: 'ClothingImageService',
      );
      return null;
    }
  }

  Future<ClothingImageFetchResult> fetchClothingImage({
    required String name,
    required String type,
    String? audience,
    int? index,
    bool? allowGenericFallback,
    bool skipMetadataSearch = false,
    int minConfidenceScore = 6,
  }) async {
    final normalizedType = _normalizedType(name, type);
    final fallbackAllowed = allowGenericFallback ?? _allowGenericFallback;
    final minScore = minConfidenceScore < 0 ? 0 : minConfidenceScore;
    final qualifiedName = _audienceQualifiedName(name, audience);
    final requestUri = _internalImageUri(
      name: qualifiedName,
      type: normalizedType,
      index: index,
    );

    developer.log(
      'Starting internal image lookup: name="$name", type="$type", '
      'normalizedType="$normalizedType"',
      name: 'ClothingImageService',
    );

    if (_useExternalApi) {
      final external = await _fetchFromExternalApi(
        name: qualifiedName,
        type: normalizedType,
        index: index,
      );
      if (external != null && external.isSuccess) return external;
    }

    String? lastError;
    try {
      final query = _buildQuery(name, normalizedType, audience: audience);
      final search = await _searchImages(
        query,
        maxResults: skipMetadataSearch ? 4 : 10,
      );

      if (search.hits.isEmpty) {
        lastError = 'No images found for "$query"';
      } else {
        final selection = await _downloadFirstValidImage(
          hits: search.hits,
          name: qualifiedName,
          type: normalizedType,
          preferredIndex: index,
          maxAttempts: skipMetadataSearch ? 3 : null,
          minConfidenceScore: minScore,
        );

        final image = selection.image;
        if (image != null) {
          _terminalDebug(
            'Internal image lookup succeeded via ${search.engine}: '
            '${image.sourceUrl} (${image.bytes.length} bytes)',
          );
          return ClothingImageFetchResult(
            bytes: image.bytes,
            requestUri: _internalImageUri(
              name: name,
              type: normalizedType,
              index: image.resultIndex,
            ),
            statusCode: 200,
            sourceImageUrl: image.sourceUrl,
            apiSearchQuery: search.query,
            apiSearchEngine: search.engine,
            apiResultIndex: image.resultIndex,
            isGenericFallback: false,
          );
        }
        lastError = selection.error;
      }
    } catch (e) {
      lastError = e.toString();
      developer.log('Internal image lookup failed: $e', name: 'ClothingImageService');
    }

    if (fallbackAllowed) {
      final fallbackBytes = await _fetchFallbackImageBytes(
          name: name,
          type: normalizedType,
      );
      if (fallbackBytes != null) {
        developer.log(
          'Primary image search unavailable, served fallback image for '
          '"$normalizedType". Last error: ${lastError ?? "n/a"}',
          name: 'ClothingImageService',
        );
        return ClothingImageFetchResult(
          bytes: fallbackBytes,
          requestUri: _fallbackImageUri(name: name, type: normalizedType),
          statusCode: 200,
          error: null,
          isGenericFallback: true,
        );
      }
    }

    return ClothingImageFetchResult(
      bytes: null,
      requestUri: requestUri,
      statusCode: null,
      error: lastError ?? 'Unknown internal image search failure',
    );
  }

  Future<ClothingImageHealthStatus> checkHealth({
    String name = 'nike hoodie',
    String type = 'hoodie',
    String? audience,
  }) async {
    final stopwatch = Stopwatch()..start();
    final normalizedType = _normalizedType(name, type);
    final qualifiedName = _audienceQualifiedName(name, audience);
    final query = _buildQuery(name, normalizedType, audience: audience);

    try {
      final search = await _searchImages(query, maxResults: 4);
      if (search.hits.isEmpty) {
        return ClothingImageHealthStatus(
          isHealthy: false,
          query: query,
          searchEngine: search.engine,
          resultCount: 0,
          duration: stopwatch.elapsed,
          checkedAt: DateTime.now(),
          error: 'No image URLs returned by Bing, DuckDuckGo, or Google',
        );
      }

      final selection = await _downloadFirstValidImage(
        hits: search.hits,
        name: qualifiedName,
        type: normalizedType,
        maxAttempts: 3,
        minConfidenceScore: 0,
        timeout: _healthDownloadTimeout,
      );

      final image = selection.image;
      if (image == null) {
        return ClothingImageHealthStatus(
          isHealthy: false,
          query: query,
          searchEngine: search.engine,
          resultCount: search.hits.length,
          duration: stopwatch.elapsed,
          checkedAt: DateTime.now(),
          error: selection.error ?? 'Search returned URLs, but download failed',
        );
      }

      return ClothingImageHealthStatus(
        isHealthy: true,
        query: query,
        searchEngine: search.engine,
        resultCount: search.hits.length,
        sampleImageUrl: image.sourceUrl,
        sampleBytes: image.bytes.length,
        sampleMimeType: image.mimeType,
        duration: stopwatch.elapsed,
        checkedAt: DateTime.now(),
      );
    } catch (e) {
      return ClothingImageHealthStatus(
        isHealthy: false,
        query: query,
        searchEngine: 'none',
        resultCount: 0,
        duration: stopwatch.elapsed,
        checkedAt: DateTime.now(),
        error: e.toString(),
      );
    }
  }

  Future<Uint8List?> fetchClothingImageBytes({
    required String name,
    required String type,
    int? index,
    String? audience,
    bool skipMetadataSearch = false,
  }) async {
    final result = await fetchClothingImage(
      name: name,
      type: type,
      audience: audience,
      index: index,
      skipMetadataSearch: skipMetadataSearch,
    );
    return result.bytes;
  }
}

class ClothingImageFetchResult {
  final Uint8List? bytes;
  final Uri? requestUri;
  final int? statusCode;
  final String? error;
  final String? sourceImageUrl;
  final String? apiSearchQuery;
  final String? apiSearchEngine;
  final int? apiResultIndex;
  final bool isGenericFallback;

  const ClothingImageFetchResult({
    required this.bytes,
    this.requestUri,
    this.statusCode,
    this.error,
    this.sourceImageUrl,
    this.apiSearchQuery,
    this.apiSearchEngine,
    this.apiResultIndex,
    this.isGenericFallback = false,
  });

  bool get isSuccess => bytes != null && bytes!.isNotEmpty;
}

class ClothingImageHealthStatus {
  const ClothingImageHealthStatus({
    required this.isHealthy,
    required this.query,
    required this.resultCount,
    required this.duration,
    required this.checkedAt,
    this.searchEngine,
    this.sampleImageUrl,
    this.sampleBytes,
    this.sampleMimeType,
    this.error,
  });

  final bool isHealthy;
  final String query;
  final String? searchEngine;
  final int resultCount;
  final String? sampleImageUrl;
  final int? sampleBytes;
  final String? sampleMimeType;
  final String? error;
  final Duration duration;
  final DateTime checkedAt;

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'is_healthy': isHealthy,
      'query': query,
      'search_engine': searchEngine,
      'result_count': resultCount,
      'sample_image_url': sampleImageUrl,
      'sample_bytes': sampleBytes,
      'sample_mime_type': sampleMimeType,
      'error': error,
      'duration_ms': duration.inMilliseconds,
      'checked_at': checkedAt.toIso8601String(),
    };
  }
}

class _SearchResult {
  const _SearchResult({
    required this.query,
    required this.engine,
    required this.hits,
  });

  final String query;
  final String engine;
  final List<_ImageSearchHit> hits;
  List<String> get urls => hits.map((hit) => hit.url).toList();
}

class _ImageSearchHit {
  const _ImageSearchHit({
    required this.url,
    this.title,
    this.pageUrl,
    this.source,
  });

  final String url;
  final String? title;
  final String? pageUrl;
  final String? source;
}

class _ImageCandidate {
  const _ImageCandidate({
    required this.index,
    required this.hit,
    required this.score,
  });

  final int index;
  final _ImageSearchHit hit;
  final int score;

  String get url => hit.url;
}

class _DownloadedImage {
  const _DownloadedImage({
    required this.bytes,
    required this.mimeType,
    required this.sourceUrl,
    required this.resultIndex,
    required this.score,
  });

  final Uint8List bytes;
  final String mimeType;
  final String sourceUrl;
  final int resultIndex;
  final int score;
}

class _DownloadSelection {
  const _DownloadSelection({
    required this.attempts,
    this.image,
    this.error,
  });

  final int attempts;
  final _DownloadedImage? image;
  final String? error;
}
