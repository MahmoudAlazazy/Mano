import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;

import '../config/gemini_config.dart';

/// Thrown when the Gemini/OpenRouter API returns an error or all keys are exhausted.
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

/// Tracks the health and availability of a single API key.
class KeyState {
  KeyState(this.value);

  final String value;

  /// True once the key has failed too many times and should never be retried.
  bool exhausted = false;
  int failCount = 0;

  /// When set, the key is in a temporary cooldown and should not be used until after this time.
  DateTime? cooldownUntil;

  /// Higher score = more preferred. Exhausted keys return -1; keys in cooldown return 0.
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

  /// Records a failure. Quota errors get a longer cooldown (2 min) than other errors (30 s).
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

/// Manages a pool of API keys, routing requests to the healthiest available key.
class GeminiKeyPool {
  GeminiKeyPool(List<String> keys)
    : _keys = keys.map((k) => KeyState(k)).toList();

  final List<KeyState> _keys;

  bool get allDead => _keys.every((k) => !k.isAvailable);

  /// Returns the available key with the highest score.
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

/// Sends requests to the Gemini or OpenRouter API with automatic key rotation
/// and provider fallback.
class GeminiService {
  GeminiService({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;

  static const Duration _requestTimeout = Duration(seconds: 25);

  /// Calls the AI API with [body], trying each provider and key until one succeeds.
  ///
  /// Set [geminiOnly] to skip the OpenRouter fallback entirely.
  Future<Map<String, dynamic>> generateContent({
    required Map<String, dynamic> body,
    String? model,
    bool geminiOnly = false,
  }) async {
    GeminiConfig.validate();

    GeminiException? lastError;
    final routes = _buildProviderRoutes(
      modelOverride: model,
      geminiOnly: geminiOnly,
    );

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
          // Normalize OpenRouter responses to match the Gemini response shape.
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

        // Quota and auth errors are key-specific — rotate to the next key.
        // Other errors are likely request-level, so fall through to the next provider.
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

  /// Builds the ordered list of providers to try. Primary provider is tried first,
  /// then the secondary as a fallback (unless [geminiOnly] is set).
  List<_ProviderRoute> _buildProviderRoutes({
    String? modelOverride,
    bool geminiOnly = false,
  }) {
    if (geminiOnly) {
      return [
        _routeForProvider(
          provider: 'gemini',
          model: modelOverride,
        ),
      ];
    }

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

  /// Builds a Gemini REST request, passing the API key as a query parameter.
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

  /// Builds an OpenRouter request, translating Gemini-style body fields to
  /// the OpenAI-compatible format that OpenRouter expects.
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

  /// Converts a Gemini-format request body to the OpenAI chat-completions format.
  /// Maps Gemini's `contents[].parts[].text` structure to `messages[].content`.
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

        // Gemini uses "model" for assistant turns; OpenAI uses "assistant".
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

    // Fall back to a top-level `prompt` string if no structured contents were found.
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

    // Forward generation parameters, translating Gemini field names to OpenAI equivalents.
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

  /// Converts an OpenRouter response into the Gemini `candidates` shape so the
  /// rest of the app can treat both providers identically.
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

  /// Handles both plain string content and the structured content-block array
  /// format that some OpenRouter models return.
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

  /// Returns true for HTTP 429 and quota-related 403 responses.
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

  /// Returns true when the response indicates an invalid or unauthorized API key.
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
