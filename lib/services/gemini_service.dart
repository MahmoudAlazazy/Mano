import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;

import '../config/gemini_config.dart';

class GeminiException implements Exception {
  final String message;
  final int? statusCode;
  final String? raw;

  const GeminiException(this.message, {this.statusCode, this.raw});

  @override
  String toString() {
    final rawSnippet = (raw != null && raw!.isNotEmpty)
        ? (raw!.length > 200 ? '${raw!.substring(0, 200)}...' : raw!)
        : null;

    if (statusCode != null || rawSnippet != null) {
      return 'GeminiException($message, statusCode: $statusCode, raw: $rawSnippet)';
    }
    return 'GeminiException($message)';
  }
}

class KeyState {
  KeyState(this.value);

  final String value;

  bool exhausted = false;
  int failCount = 0;

  DateTime? cooldownUntil;

  double get score {
    if (exhausted) return -1;

    if (cooldownUntil != null && DateTime.now().isBefore(cooldownUntil!)) {
      return 0;
    }

    return 100 - (failCount * 10);
  }

  bool get isAvailable {
    if (exhausted) return false;
    if (cooldownUntil == null) return true;
    return DateTime.now().isAfter(cooldownUntil!);
  }

  void markFail({bool quota = false}) {
    failCount++;

    cooldownUntil = DateTime.now().add(
      quota ? const Duration(minutes: 2) : const Duration(seconds: 30),
    );

    if (failCount >= 5) {
      exhausted = true;
    }
  }

  void markSuccess() {
    failCount = 0;
  }
}

class GeminiKeyPool {
  GeminiKeyPool(List<String> keys)
    : _keys = keys.map((k) => KeyState(k)).toList();

  final List<KeyState> _keys;

  bool get allDead => _keys.every((k) => !k.isAvailable);

  KeyState pickBestKey() {
    final available = _keys.where((k) => k.isAvailable).toList();

    if (available.isEmpty) {
      throw const GeminiException('No available Gemini keys');
    }

    available.sort((a, b) => b.score.compareTo(a.score));
    return available.first;
  }

  void markFail(String key, {bool quota = false}) {
    _keys.firstWhere((k) => k.value == key).markFail(quota: quota);
  }

  void markSuccess(String key) {
    _keys.firstWhere((k) => k.value == key).markSuccess();
  }
}

class GeminiService {
  GeminiService({http.Client? client})
    : _http = client ?? http.Client(),
      _pool = GeminiKeyPool(GeminiConfig.keys);

  final http.Client _http;
  final GeminiKeyPool _pool;

  static const String _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta';
  static const Duration _requestTimeout = Duration(seconds: 25);

  Future<Map<String, dynamic>> generateContent({
    required Map<String, dynamic> body,
    String? model,
  }) async {
    GeminiConfig.validate();

    final requestModel = model ?? GeminiConfig.model;

    GeminiException? lastError;

    while (!_pool.allDead) {
      final keyState = _pool.pickBestKey();
      final key = keyState.value;
      final stopwatch = Stopwatch()..start();

      final uri = Uri.parse(
        '$_baseUrl/models/$requestModel:generateContent',
      ).replace(queryParameters: {'key': key});

      developer.log(
        'Gemini request started: model=$requestModel',
        name: 'GeminiService',
      );

      http.Response response;
      try {
        response = await _http
            .post(
              uri,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(body),
            )
            .timeout(_requestTimeout);
      } on TimeoutException {
        _pool.markFail(key);
        lastError = const GeminiException('Gemini request timed out');
        developer.log(
          'Gemini request timed out after ${stopwatch.elapsedMilliseconds}ms',
          name: 'GeminiService',
        );
        continue;
      }

      developer.log(
        'Gemini response status=${response.statusCode} in ${stopwatch.elapsedMilliseconds}ms',
        name: 'GeminiService',
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        _pool.markSuccess(key);

        return jsonDecode(response.body) as Map<String, dynamic>;
      }

      final quota = _isQuotaError(response);
      final auth = _isAuthError(response);

      _pool.markFail(key, quota: quota);

      lastError = GeminiException(
        'Gemini request failed',
        statusCode: response.statusCode,
        raw: response.body,
      );

      if (quota || auth) {
        continue;
      }

      throw lastError;
    }

    throw lastError ?? const GeminiException('All Gemini keys exhausted');
  }

  bool _isQuotaError(http.Response response) {
    if (response.statusCode == 429) return true;

    if (response.statusCode == 403) {
      final body = response.body.toLowerCase();
      return body.contains('quota') ||
          body.contains('rate') ||
          body.contains('exceeded');
    }

    return false;
  }

  bool _isAuthError(http.Response response) {
    if (response.statusCode != 401 && response.statusCode != 403) {
      return false;
    }

    final body = response.body.toLowerCase();

    return body.contains('unregistered callers') ||
        body.contains('api key not valid') ||
        body.contains('api_key_invalid') ||
        body.contains('missing api key') ||
        body.contains('not allowed');
  }
}
