import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config/magic_hour_config.dart';

class MagicHourException implements Exception {
  final String message;
  final int? statusCode;
  final String? raw;

  const MagicHourException(this.message, {this.statusCode, this.raw});

  @override
  String toString() {
    final rawSnippet = (raw != null && raw!.isNotEmpty)
        ? (raw!.length > 200 ? '${raw!.substring(0, 200)}...' : raw!)
        : null;
    if (statusCode != null || rawSnippet != null) {
      return 'MagicHourException($message, statusCode: $statusCode, raw: $rawSnippet)';
    }
    return 'MagicHourException($message)';
  }
}

class MagicHourKeyPool {
  MagicHourKeyPool(List<String> keys)
      : _keys = keys.map((k) => _KeyState(k)).toList();

  final List<_KeyState> _keys;
  int _cursor = 0;

  bool get allExhausted => _keys.every((k) => k.exhausted);

  _KeyState nextAvailable() {
    if (_keys.isEmpty) {
      throw const MagicHourException('No Magic Hour keys configured');
    }

    for (int i = 0; i < _keys.length; i++) {
      final idx = (_cursor + i) % _keys.length;
      final key = _keys[idx];
      if (!key.exhausted) {
        _cursor = (idx + 1) % _keys.length;
        return key;
      }
    }

    throw const MagicHourException('All Magic Hour keys exhausted');
  }

  void markExhausted(String key) {
    for (final k in _keys) {
      if (k.value == key) {
        k.exhausted = true;
        return;
      }
    }
  }
}

class MagicHourService {
  MagicHourService({http.Client? client})
      : _http = client ?? http.Client(),
        _pool = MagicHourKeyPool(MagicHourConfig.keys);

  final http.Client _http;
  final MagicHourKeyPool _pool;

  String get _baseUrl => MagicHourConfig.baseUrl;

  String acquireKey() => _pool.nextAvailable().value;

  void markKeyExhausted(String key) => _pool.markExhausted(key);

  static bool isRetryableStatus(int? statusCode) {
    if (statusCode == null) return false;
    return statusCode == 401 ||
        statusCode == 402 ||
        statusCode == 403 ||
        statusCode == 404 ||
        statusCode == 429;
  }

  Future<MagicHourUploadedAsset> uploadImageBytes({
    required Uint8List bytes,
    required String mimeType,
    String? keyOverride,
  }) async {
    final ext = _extensionFromMime(mimeType);
    final uploadInfo = await _generateUploadUrl(
      type: 'image',
      extension: ext,
      keyOverride: keyOverride,
    );

    final uploadUrl = uploadInfo['upload_url'] as String?;
    final filePath = uploadInfo['file_path'] as String?;

    if (uploadUrl == null || filePath == null) {
      throw const MagicHourException('Invalid upload URL response');
    }

    final res = await _http.put(
      Uri.parse(uploadUrl),
      headers: {'Content-Type': mimeType},
      body: bytes,
    );

    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw MagicHourException(
        'Failed to upload image to Magic Hour storage',
        statusCode: res.statusCode,
        raw: res.body,
      );
    }

    final publicUrl = _publicUrlFromUploadUrl(uploadUrl);
    return MagicHourUploadedAsset(filePath: filePath, publicUrl: publicUrl);
  }

  Future<String> createClothesChangerJob({
    required String personFilePath,
    required String garmentFilePath,
    String? garmentType,
    String? name,
    String? keyOverride,
  }) async {
    final body = <String, dynamic>{
      'assets': {
        'person_file_path': personFilePath,
        'garment_file_path': garmentFilePath,
        if (garmentType != null && garmentType.isNotEmpty)
          'garment_type': garmentType,
      },
      if (name != null && name.isNotEmpty) 'name': name,
    };

    final res = keyOverride != null
        ? await _requestWithKey(
            keyOverride,
            'POST /v1/ai-clothes-changer',
            () => _http.post(
              Uri.parse('$_baseUrl/v1/ai-clothes-changer'),
              headers: _authHeaders(keyOverride),
              body: jsonEncode(body),
            ),
          )
        : await _requestWithRetry('POST /v1/ai-clothes-changer', (key) {
            return _http.post(
              Uri.parse('$_baseUrl/v1/ai-clothes-changer'),
              headers: _authHeaders(key),
              body: jsonEncode(body),
            );
          });

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final id = data['id'] as String?;
    if (id == null || id.isEmpty) {
      throw MagicHourException(
        'Magic Hour response missing job id',
        statusCode: res.statusCode,
        raw: res.body,
      );
    }
    return id;
  }

  Future<Map<String, dynamic>> getImageProject(String id, {String? keyOverride}) async {
    final res = keyOverride != null
        ? await _requestWithKey(
            keyOverride,
            'GET /v1/image-projects/$id',
            () => _http.get(
              Uri.parse('$_baseUrl/v1/image-projects/$id'),
              headers: _authHeaders(keyOverride),
            ),
          )
        : await _requestWithRetry('GET /v1/image-projects/$id', (key) {
            return _http.get(
              Uri.parse('$_baseUrl/v1/image-projects/$id'),
              headers: _authHeaders(key),
            );
          });
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Uint8List> downloadFile(String url) async {
    final res = await _http.get(Uri.parse(url));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw MagicHourException(
        'Failed to download Magic Hour output',
        statusCode: res.statusCode,
        raw: res.body,
      );
    }
    return res.bodyBytes;
  }

  Future<String> waitForImageDownloadUrl(
    String id, {
    Duration pollInterval = const Duration(seconds: 2),
    Duration timeout = const Duration(seconds: 60),
    String? keyOverride,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      Map<String, dynamic> data;
      try {
        data = await getImageProject(id, keyOverride: keyOverride);
      } on MagicHourException catch (e) {
        if (e.statusCode == 404) {
          await Future.delayed(pollInterval);
          continue;
        }
        rethrow;
      }
      final status = data['status'] as String?;
      if (status == 'complete') {
        final downloads = data['downloads'];
        if (downloads is List && downloads.isNotEmpty) {
          final first = downloads.first;
          final url = (first is Map) ? first['url'] as String? : null;
          if (url != null && url.isNotEmpty) return url;
        }
        throw const MagicHourException('No download URL returned');
      }
      if (status == 'error') {
        throw MagicHourException(
          'Magic Hour render failed',
          raw: jsonEncode(data['error'] ?? data),
        );
      }
      await Future.delayed(pollInterval);
    }
    throw const MagicHourException('Magic Hour render timed out');
  }

  Future<Map<String, dynamic>> _generateUploadUrl({
    required String type,
    required String extension,
    String? keyOverride,
  }) async {
    final body = {
      'items': [
        {'type': type, 'extension': extension}
      ],
    };

    final res = keyOverride != null
        ? await _requestWithKey(
            keyOverride,
            'POST /v1/files/upload-urls',
            () => _http.post(
              Uri.parse('$_baseUrl/v1/files/upload-urls'),
              headers: _authHeaders(keyOverride),
              body: jsonEncode(body),
            ),
          )
        : await _requestWithRetry('POST /v1/files/upload-urls', (key) {
            return _http.post(
              Uri.parse('$_baseUrl/v1/files/upload-urls'),
              headers: _authHeaders(key),
              body: jsonEncode(body),
            );
          });

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final items = data['items'];
    if (items is List && items.isNotEmpty && items.first is Map) {
      return items.first as Map<String, dynamic>;
    }
    throw MagicHourException(
      'Invalid upload URL response',
      statusCode: res.statusCode,
      raw: res.body,
    );
  }

  Future<http.Response> _requestWithRetry(
    String requestName,
    Future<http.Response> Function(String key) request,
  ) async {
    MagicHourConfig.validate();

    MagicHourException? lastError;
    for (int attempt = 0; attempt < MagicHourConfig.keys.length; attempt++) {
      final key = _pool.nextAvailable().value;
      final res = await request(key);

      if (res.statusCode >= 200 && res.statusCode < 300) {
        return res;
      }

      if (_isRetryable(res)) {
        _pool.markExhausted(key);
        lastError = MagicHourException(
          'Magic Hour key not usable (invalid/limited/quota) on $requestName @ $_baseUrl',
          statusCode: res.statusCode,
          raw: res.body,
        );
        continue;
      }

      throw MagicHourException(
        'Magic Hour request failed on $requestName @ $_baseUrl',
        statusCode: res.statusCode,
        raw: res.body,
      );
    }

    throw lastError ?? const MagicHourException('All Magic Hour keys exhausted');
  }

  Future<http.Response> _requestWithKey(
    String key,
    String requestName,
    Future<http.Response> Function() request,
  ) async {
    MagicHourConfig.validate();
    final res = await request();
    if (res.statusCode >= 200 && res.statusCode < 300) return res;
    throw MagicHourException(
      'Magic Hour request failed on $requestName @ $_baseUrl',
      statusCode: res.statusCode,
      raw: res.body,
    );
  }

  bool _isRetryable(http.Response res) {
    if (res.statusCode == 401 ||
        res.statusCode == 402 ||
        res.statusCode == 403 ||
        res.statusCode == 429) {
      return true;
    }
    return false;
  }

  Map<String, String> _authHeaders(String key) {
    return {
      'Authorization': 'Bearer $key',
      'Content-Type': 'application/json',
    };
  }

  String _extensionFromMime(String mime) {
    final lower = mime.toLowerCase();
    if (lower.contains('png')) return 'png';
    if (lower.contains('webp')) return 'webp';
    if (lower.contains('avif')) return 'avif';
    return 'jpg';
  }

  String _publicUrlFromUploadUrl(String uploadUrl) {
    final uri = Uri.parse(uploadUrl);
    return uri.replace(query: '').toString();
  }
}

class MagicHourUploadedAsset {
  final String filePath;
  final String publicUrl;
  const MagicHourUploadedAsset({
    required this.filePath,
    required this.publicUrl,
  });
}

class _KeyState {
  _KeyState(this.value);
  final String value;
  bool exhausted = false;
}
