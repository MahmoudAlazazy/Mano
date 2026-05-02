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
      throw const GeminiException('No available AI keys');
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
  GeminiService({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;

  static const Duration _requestTimeout = Duration(seconds: 25);

  Future<Map<String, dynamic>> generateContent({
    required Map<String, dynamic> body,
    String? model,
  }) async {
    GeminiConfig.validate();

    GeminiException? lastError;
    final routes = _buildProviderRoutes(modelOverride: model);

    for (var i = 0; i < routes.length; i++) {
      final route = routes[i];
      if (route.keys.isEmpty) {
        continue;
      }

      final pool = GeminiKeyPool(route.keys);
      while (!pool.allDead) {
        final keyState = pool.pickBestKey();
        final key = keyState.value;
        final stopwatch = Stopwatch()..start();
        final request = _buildRequest(
          provider: route.provider,
          baseUrl: route.baseUrl,
          apiKey: key,
          model: route.model,
          body: body,
        );

        developer.log(
          'AI request started: provider=${route.provider} model=${route.model}',
          name: 'GeminiService',
        );

        http.Response response;
        try {
          response = await _http
              .post(
                request.uri,
                headers: request.headers,
                body: jsonEncode(request.body),
              )
              .timeout(_requestTimeout);
        } on TimeoutException {
          pool.markFail(key);
          lastError = GeminiException('${route.provider} request timed out');
          developer.log(
            'AI request timed out after ${stopwatch.elapsedMilliseconds}ms',
            name: 'GeminiService',
          );
          continue;
        }

        developer.log(
          'AI response status=${response.statusCode} in ${stopwatch.elapsedMilliseconds}ms',
          name: 'GeminiService',
        );

        if (response.statusCode >= 200 && response.statusCode < 300) {
          pool.markSuccess(key);
          final decoded = jsonDecode(response.body);
          if (decoded is! Map<String, dynamic>) {
            throw const GeminiException('Unexpected AI response format');
          }
          return route.provider == 'openrouter'
              ? _normalizeOpenRouterResponse(decoded)
              : decoded;
        }

        final quota = _isQuotaError(response);
        final auth = _isAuthError(response);

        pool.markFail(key, quota: quota);

        lastError = GeminiException(
          '${route.provider} request failed',
          statusCode: response.statusCode,
          raw: response.body,
        );

        if (quota || auth) {
          continue;
        }

        final hasFallbackProvider = i < routes.length - 1;
        if (hasFallbackProvider) {
          developer.log(
            '${route.provider} failed with non-retriable error; trying fallback provider',
            name: 'GeminiService',
          );
          break;
        }

        throw lastError;
      }
    }

    throw lastError ?? const GeminiException('All AI keys exhausted');
  }

  List<_ProviderRoute> _buildProviderRoutes({String? modelOverride}) {
    final primary = GeminiConfig.provider == 'openrouter'
        ? 'openrouter'
        : 'gemini';
    final secondary = primary == 'gemini' ? 'openrouter' : 'gemini';

    return [
      _routeForProvider(
        provider: primary,
        model: modelOverride,
      ),
      _routeForProvider(provider: secondary),
    ];
  }

  _ProviderRoute _routeForProvider({
    required String provider,
    String? model,
  }) {
    if (provider == 'openrouter') {
      return _ProviderRoute(
        provider: 'openrouter',
        model: (model ?? GeminiConfig.openRouterModel).trim(),
        baseUrl: GeminiConfig.openRouterBaseUrl,
        keys: GeminiConfig.openRouterKeys,
      );
    }

    return _ProviderRoute(
      provider: 'gemini',
      model: (model ?? GeminiConfig.geminiModel).trim(),
      baseUrl: GeminiConfig.geminiBaseUrl,
      keys: GeminiConfig.geminiKeys,
    );
  }

  _HttpRequest _buildRequest({
    required String provider,
    required String baseUrl,
    required String apiKey,
    required String model,
    required Map<String, dynamic> body,
  }) {
    if (provider == 'openrouter') {
      return _buildOpenRouterRequest(
        baseUrl: baseUrl,
        apiKey: apiKey,
        model: model,
        body: body,
      );
    }
    return _buildGeminiRequest(
      baseUrl: baseUrl,
      apiKey: apiKey,
      model: model,
      body: body,
    );
  }

  _HttpRequest _buildGeminiRequest({
    required String baseUrl,
    required String apiKey,
    required String model,
    required Map<String, dynamic> body,
  }) {
    final uri = Uri.parse('$baseUrl/models/$model:generateContent').replace(
      queryParameters: {'key': apiKey},
    );

    return _HttpRequest(
      uri: uri,
      headers: const {'Content-Type': 'application/json'},
      body: body,
    );
  }

  _HttpRequest _buildOpenRouterRequest({
    required String baseUrl,
    required String apiKey,
    required String model,
    required Map<String, dynamic> body,
  }) {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
    };

    if (GeminiConfig.openRouterReferer.trim().isNotEmpty) {
      headers['HTTP-Referer'] = GeminiConfig.openRouterReferer.trim();
    }

    if (GeminiConfig.openRouterTitle.trim().isNotEmpty) {
      headers['X-Title'] = GeminiConfig.openRouterTitle.trim();
    }

    final requestBody = _toOpenRouterBody(source: body, model: model);

    return _HttpRequest(
      uri: Uri.parse('$baseUrl/chat/completions'),
      headers: headers,
      body: requestBody,
    );
  }

  Map<String, dynamic> _toOpenRouterBody({
    required Map<String, dynamic> source,
    required String model,
  }) {
    final request = <String, dynamic>{'model': model};

    final messages = <Map<String, dynamic>>[];
    final contents = source['contents'];
    if (contents is List) {
      for (final entry in contents) {
        if (entry is! Map) continue;

        final roleRaw = (entry['role'] ?? 'user').toString().trim().toLowerCase();
        final role = roleRaw == 'model'
            ? 'assistant'
            : (roleRaw.isEmpty ? 'user' : roleRaw);

        final parts = entry['parts'];
        final textParts = <String>[];
        if (parts is List) {
          for (final part in parts) {
            if (part is Map && part['text'] is String) {
              final text = (part['text'] as String).trim();
              if (text.isNotEmpty) {
                textParts.add(text);
              }
            }
          }
        }

        final content = textParts.join('\n').trim();
        if (content.isEmpty) continue;

        messages.add({'role': role, 'content': content});
      }
    }

    if (messages.isEmpty && source['prompt'] is String) {
      final prompt = (source['prompt'] as String).trim();
      if (prompt.isNotEmpty) {
        messages.add({'role': 'user', 'content': prompt});
      }
    }

    if (messages.isEmpty) {
      throw const GeminiException('OpenRouter request body has no text messages');
    }

    request['messages'] = messages;

    final generationConfig = source['generationConfig'];
    if (generationConfig is Map) {
      final temperature = _asDouble(generationConfig['temperature']);
      if (temperature != null) {
        request['temperature'] = temperature;
      }

      final topP = _asDouble(generationConfig['topP']);
      if (topP != null) {
        request['top_p'] = topP;
      }

      final maxTokens = _asInt(generationConfig['maxOutputTokens']);
      if (maxTokens != null && maxTokens > 0) {
        request['max_tokens'] = maxTokens;
      }

      final mime = (generationConfig['responseMimeType'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      if (mime == 'application/json') {
        request['response_format'] = const {'type': 'json_object'};
      }
    }

    return request;
  }

  Map<String, dynamic> _normalizeOpenRouterResponse(Map<String, dynamic> raw) {
    final choices = raw['choices'];
    if (choices is List && choices.isNotEmpty) {
      final first = choices.first;
      if (first is Map) {
        final message = first['message'];
        if (message is Map) {
          final content = _openRouterContentToText(message['content']).trim();
          if (content.isNotEmpty) {
            return {
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': content},
                    ],
                  },
                },
              ],
            };
          }
        }
      }
    }

    throw GeminiException(
      'OpenRouter response missing assistant content',
      raw: jsonEncode(raw),
    );
  }

  String _openRouterContentToText(dynamic content) {
    if (content is String) {
      return content;
    }

    if (content is List) {
      final buffer = StringBuffer();
      for (final item in content) {
        if (item is Map && item['type'] == 'text' && item['text'] is String) {
          buffer.write(item['text']);
        }
      }
      return buffer.toString();
    }

    return '';
  }

  double? _asDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString().trim());
  }

  int? _asInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is double) return value.round();
    return int.tryParse(value.toString().trim());
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
        body.contains('invalid api key') ||
        body.contains('invalid_api_key') ||
        body.contains('missing api key') ||
        body.contains('not allowed') ||
        body.contains('unauthorized') ||
        body.contains('forbidden');
  }
}

class _HttpRequest {
  const _HttpRequest({
    required this.uri,
    required this.headers,
    required this.body,
  });

  final Uri uri;
  final Map<String, String> headers;
  final Map<String, dynamic> body;
}

class _ProviderRoute {
  const _ProviderRoute({
    required this.provider,
    required this.model,
    required this.baseUrl,
    required this.keys,
  });

  final String provider;
  final String model;
  final String baseUrl;
  final List<String> keys;
}
