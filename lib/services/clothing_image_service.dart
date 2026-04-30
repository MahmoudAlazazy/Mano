import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class ClothingImageService {
  static const String _baseUrls = String.fromEnvironment(
    'CLOTHING_IMAGE_API_BASE_URLS',
    defaultValue: '',
  );

  static const String _baseUrl = String.fromEnvironment(
    'CLOTHING_IMAGE_API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8000',
  );

  static const String _imagePath = '/api/v1/clothing/image';
  static const String _searchPath = '/api/v1/clothing/search';
  static const Duration _primaryRequestTimeout = Duration(seconds: 12);
  static const Duration _secondaryRequestTimeout = Duration(seconds: 5);
  static const Duration _metadataTimeout = Duration(seconds: 8);
  static const Duration _fallbackTimeout = Duration(seconds: 6);
  static const bool _allowGenericFallback = bool.fromEnvironment(
    'CLOTHING_IMAGE_ALLOW_FALLBACK',
    defaultValue: true,
  );
  static const Map<String, String> _jsonHeaders = {
    'Accept': 'application/json',
    'ngrok-skip-browser-warning': 'true',
  };
  static const Map<String, String> _imageHeaders = {
    'Accept': 'image/*',
    'ngrok-skip-browser-warning': 'true',
  };

  void _terminalDebug(String message) {
    developer.log(message, name: 'ClothingImageService');
    // ignore: avoid_print
    print('[ClothingImageService] $message');
  }

  List<String> get _candidateBaseUrls {
    final configured = <String>[
      if (_baseUrls.trim().isNotEmpty) ..._baseUrls.split(','),
      if (_baseUrl.trim().isNotEmpty) _baseUrl,
    ];
    final raw = <String>[
      ...configured,
      'http://10.0.2.2:8000',
      'http://127.0.0.1:8000',
      'http://localhost:8000',
    ];
    final unique = <String>{};
    final out = <String>[];
    for (final value in raw) {
      final v = value.trim();
      if (v.isEmpty) continue;
      if (unique.add(v)) out.add(v);
    }
    return out;
  }

  Uri buildImageUri({required String name, String? type, int? index}) {
    return buildImageUriForBase(
      baseUrl: _baseUrl,
      name: name,
      type: type,
      index: index,
    );
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

  Uri _buildSearchUriForBase({
    required String baseUrl,
    required String name,
    required String type,
  }) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final uri = Uri.parse('$base$_searchPath');
    return uri.replace(
      queryParameters: {'name': name, 'type': type, 'max_results': '10'},
    );
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
        text.contains('boot')) {
      return const ['shoe', 'sneaker', 'loafer', 'boot', 'footwear'];
    }
    if (text.contains('pant') ||
        text.contains('trouser') ||
        text.contains('jean') ||
        text.contains('short') ||
        text.contains('jogger')) {
      return const ['pant', 'trouser', 'jean', 'short', 'jogger', 'bottom'];
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
        text.contains('top')) {
      return const ['shirt', 'tee', 'top', 'blouse'];
    }
    return const ['clothing'];
  }

  List<String> _nameKeywords(String name) {
    final stop = <String>{
      'men',
      'man',
      'women',
      'woman',
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
    if (text.contains('watch')) {
      return const ['shoe', 'boot', 'jean', 'sunglass', 'dress'];
    }
    if (text.contains('sunglass')) {
      return const ['watch', 'shoe', 'boot', 'jean'];
    }
    if (text.contains('shoe') ||
        text.contains('sneaker') ||
        text.contains('boot')) {
      return const ['watch', 'sunglass', 'dress'];
    }
    if (text.contains('pant') ||
        text.contains('jean') ||
        text.contains('short') ||
        text.contains('jogger')) {
      return const ['watch', 'sunglass', 'shoe'];
    }
    if (text.contains('shirt') ||
        text.contains('tee') ||
        text.contains('top') ||
        text.contains('hoodie') ||
        text.contains('jacket')) {
      return const ['watch', 'sunglass'];
    }
    return const ['watch', 'sunglass'];
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
        text.contains('heel')) {
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

  int _scoreImageUrl({
    required String imageUrl,
    required String type,
    required List<String> positives,
    required List<String> negatives,
  }) {
    final url = imageUrl.toLowerCase();
    var score = 0;
    var positiveHits = 0;

    for (final p in positives) {
      if (url.contains(p)) {
        score += 2;
        positiveHits++;
      }
    }

    final typeTokens = _typeKeywords('', type);
    final typeHit = typeTokens.any(url.contains);
    if (typeHit) {
      score += 8;
    } else {
      score -= 4;
    }

    for (final n in negatives) {
      if (url.contains(n)) score -= 7;
    }
    if (positiveHits == 0) {
      score -= 2;
    }
    if (url.contains('.jpg') ||
        url.contains('.jpeg') ||
        url.contains('.png') ||
        url.contains('.webp')) {
      score += 1;
    }
    return score;
  }

  bool _looksLikeImageBytes(Uint8List bytes) {
    if (bytes.length < 4) return false;
    final jpeg = bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF;
    final png =
        bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47;
    final gif = bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46;
    final webp =
        bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50;
    return jpeg || png || gif || webp;
  }

  bool _isGifBytes(Uint8List bytes) {
    return bytes.length >= 6 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46;
  }

  bool _isAnimatedWebpBytes(Uint8List bytes) {
    if (bytes.length < 16) return false;
    final isWebp =
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50;
    if (!isWebp) return false;

    final animSignature = ascii.encode('ANIM');
    for (var i = 0; i <= bytes.length - animSignature.length; i++) {
      var matches = true;
      for (var j = 0; j < animSignature.length; j++) {
        if (bytes[i + j] != animSignature[j]) {
          matches = false;
          break;
        }
      }
      if (matches) return true;
    }

    return false;
  }

  String? _unsupportedImageReason(http.Response response) {
    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    if (contentType.contains('image/gif') || _isGifBytes(response.bodyBytes)) {
      return 'Animated GIF response rejected';
    }
    if (_isAnimatedWebpBytes(response.bodyBytes)) {
      return 'Animated WebP response rejected';
    }
    if (contentType.contains('image/')) {
      return null;
    }
    if (_looksLikeImageBytes(response.bodyBytes)) {
      return null;
    }
    return 'Non-image response (content-type=$contentType)';
  }

  Future<ClothingImageFetchResult> _tryFetchImageFromUri({
    required Uri uri,
    required Duration timeout,
  }) async {
    final stopwatch = Stopwatch()..start();
    _terminalDebug(
      'Image request started: $uri (timeout=${timeout.inSeconds}s)',
    );

    try {
      final response = await http
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

      if (response.bodyBytes.isEmpty) {
        final msg = 'Empty image body from $uri after ${elapsedMs}ms';
        _terminalDebug(msg);
        return ClothingImageFetchResult(
          bytes: null,
          requestUri: uri,
          statusCode: response.statusCode,
          error: msg,
        );
      }

      final unsupportedReason = _unsupportedImageReason(response);
      if (unsupportedReason != null) {
        final msg = '$unsupportedReason from $uri after ${elapsedMs}ms';
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
      final sourceHost = sourceImageUrl == null
          ? null
          : Uri.tryParse(sourceImageUrl)?.host;

      _terminalDebug(
        'Image request succeeded: $uri after ${elapsedMs}ms (${response.bodyBytes.length} bytes)',
      );
      _terminalDebug(
        'Image API debug: search_query="${apiSearchQuery ?? "-"}", '
        'search_engine="${apiSearchEngine ?? "-"}", '
        'source_url="${sourceImageUrl ?? "-"}", source_host="${sourceHost ?? "-"}", '
        'result_index=${apiResultIndex ?? -1}',
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

  Future<_RankedIndex?> _bestResultIndexForBase({
    required String baseUrl,
    required String name,
    required String type,
    int? preferredIndex,
  }) async {
    try {
      final searchUri = _buildSearchUriForBase(
        baseUrl: baseUrl,
        name: name,
        type: type,
      );
      final response = await http
          .get(searchUri, headers: _jsonHeaders)
          .timeout(_metadataTimeout);
      if (response.statusCode != 200) return null;

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return null;
      final resultsRaw = decoded['results'];
      if (resultsRaw is! List) return null;

      final positives = <String>[
        ..._typeKeywords(name, type),
        ..._nameKeywords(name),
      ];
      final negatives = _negativeKeywords(name, type);

      int? bestIndex;
      var bestScore = -1 << 30;
      for (final raw in resultsRaw) {
        if (raw is! Map<String, dynamic>) continue;
        final idxRaw = raw['index'];
        final imageUrl = raw['image_url']?.toString() ?? '';
        if (idxRaw is! int || imageUrl.isEmpty) continue;
        var score = _scoreImageUrl(
          imageUrl: imageUrl,
          type: type,
          positives: positives,
          negatives: negatives,
        );
        if (preferredIndex != null && preferredIndex == idxRaw) {
          score += 1;
        }
        if (score > bestScore) {
          bestScore = score;
          bestIndex = idxRaw;
        }
      }

      if (bestIndex != null) {
        return _RankedIndex(index: bestIndex, score: bestScore);
      }
      return null;
    } catch (e) {
      developer.log(
        'Search metadata failed for $baseUrl ($name/$type): $e',
        name: 'ClothingImageService',
      );
      return null;
    }
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
      final response = await http
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
    int? index,
    bool? allowGenericFallback,
    bool skipMetadataSearch = false,
    int minConfidenceScore = 6,
  }) async {
    final normalizedType = _normalizedType(name, type);
    final fallbackAllowed = allowGenericFallback ?? _allowGenericFallback;
    final minScore = minConfidenceScore < 0 ? 0 : minConfidenceScore;
    final baseUrls = _candidateBaseUrls;
    String? lastError;
    Uri? lastUri;
    int? lastStatusCode;
    final directIndices = <int>{
      if (index != null && index >= 0) index else 0,
      if (index == null) 1,
    }.toList();

    developer.log(
      'Starting image lookup: name="$name", type="$type", normalizedType="$normalizedType", bases=${baseUrls.join(", ")}',
      name: 'ClothingImageService',
    );

    // Fast path: use the image endpoint directly.
    // The backend already does its own Bing/DDG/Google lookup and streams
    // the best image, so we do not need to call the metadata search endpoint
    // before every image request.
    for (var baseIndex = 0; baseIndex < baseUrls.length; baseIndex++) {
      final base = baseUrls[baseIndex];
      final timeout = baseIndex == 0
          ? _primaryRequestTimeout
          : _secondaryRequestTimeout;
      for (final directIndex in directIndices) {
        final uri = buildImageUriForBase(
          baseUrl: base,
          name: name,
          type: normalizedType,
          index: directIndex,
        );
        final result = await _tryFetchImageFromUri(uri: uri, timeout: timeout);
        if (result.isSuccess) return result;
        lastError = result.error;
        lastUri = result.requestUri;
        lastStatusCode = result.statusCode;
      }
    }

    if (skipMetadataSearch) {
      if (fallbackAllowed) {
        final fallbackBytes = await _fetchFallbackImageBytes(
          name: name,
          type: normalizedType,
        );
        if (fallbackBytes != null) {
          developer.log(
            'Using fast fallback image for "$normalizedType" (skipMetadataSearch=true). '
            'Last error: ${lastError ?? "n/a"}',
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
        requestUri: lastUri,
        statusCode: lastStatusCode,
        error: lastError ?? 'Unknown image API failure',
      );
    }

    // Fallback path: use metadata ranking only if the direct endpoint failed.
    for (var baseIndex = 0; baseIndex < baseUrls.length; baseIndex++) {
      final base = baseUrls[baseIndex];
      final timeout = baseIndex == 0
          ? _primaryRequestTimeout
          : _secondaryRequestTimeout;
      final ranked = await _bestResultIndexForBase(
        baseUrl: base,
        name: name,
        type: normalizedType,
        preferredIndex: index,
      );
      if (ranked == null) {
        lastError =
            'No ranked search result for $name/$normalizedType on $base';
        continue;
      }
      if (ranked.score < minScore) {
        lastError =
            'Low-confidence image match for $name/$normalizedType on $base (score=${ranked.score})';
        continue;
      }
      final uri = buildImageUriForBase(
        baseUrl: base,
        name: name,
        type: normalizedType,
        index: ranked.index,
      );
      final result = await _tryFetchImageFromUri(uri: uri, timeout: timeout);
      if (result.isSuccess) return result;
      lastError = result.error;
      lastUri = result.requestUri;
      lastStatusCode = result.statusCode;
    }

    if (fallbackAllowed) {
      final fallbackBytes = await _fetchFallbackImageBytes(
        name: name,
        type: normalizedType,
      );
      if (fallbackBytes != null) {
        developer.log(
          'Primary API unavailable, served fallback image for type "$normalizedType". '
          'Last error: ${lastError ?? "n/a"}',
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
      requestUri: lastUri,
      statusCode: lastStatusCode,
      error: lastError ?? 'Unknown image API failure',
    );
  }

  Future<Uint8List?> fetchClothingImageBytes({
    required String name,
    required String type,
    int? index,
    bool skipMetadataSearch = false,
  }) async {
    final result = await fetchClothingImage(
      name: name,
      type: type,
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

class _RankedIndex {
  final int index;
  final int score;

  const _RankedIndex({required this.index, required this.score});
}
