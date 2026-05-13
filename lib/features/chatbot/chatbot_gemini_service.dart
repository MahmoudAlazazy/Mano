import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;

import 'chatbot_keys.dart';

/// Thrown when a Gemini API call fails for any reason.
/// Carries enough context (model, key suffix, status code, attempt trace)
/// to diagnose the failure without exposing the full API key.
class ChatbotGeminiException implements Exception {
  const ChatbotGeminiException(
    this.message, {
    this.statusCode,
    this.model,
    this.keySuffix,
    this.raw,
    this.promptBlocked = false,
    this.attemptTrace = const [],
  });

  final String message;
  final int? statusCode;
  final String? model;
  final String? keySuffix;
  final String? raw;
  final bool promptBlocked;

  /// Ordered log of every model/key attempt made before this exception was raised.
  final List<String> attemptTrace;

  @override
  String toString() {
    // Truncate raw response to avoid flooding logs.
    final snippet = (raw != null && raw!.trim().isNotEmpty)
        ? (raw!.length > 220 ? '${raw!.substring(0, 220)}...' : raw!)
        : null;

    return 'ChatbotGeminiException('
        '$message, statusCode: $statusCode, model: $model, key: $keySuffix, promptBlocked: $promptBlocked, attempts: ${attemptTrace.length}, raw: $snippet'
        ')';
  }
}

/// Handles all communication with the Gemini generative language API.
///
/// Implements a multi-key, multi-model fallback strategy:
/// - Iterates over available models (outer loop) and API keys (inner loop).
/// - Permanently skips keys marked invalid (bad credentials).
/// - Temporarily skips keys under quota backoff (rate-limited).
/// - Disables models that return 404 for the lifetime of the session.
class ChatbotGeminiService {
  ChatbotGeminiService({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;

  /// Keys confirmed invalid (bad credentials) — never retried.
  final Set<String> _invalidKeys = <String>{};

  /// Keys temporarily blocked due to quota/rate-limit errors, with expiry time.
  final Map<String, DateTime> _quotaBackoffUntil = <String, DateTime>{};

  /// Models that returned 404 this session — skipped until the set is cleared.
  final Set<String> _disabledModels = <String>{};

  static const String _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta';

  /// Preference-ordered list of models; earlier entries are tried first.
  static const List<String> _models = [
    'gemini-2.5-flash',
    'gemini-2.5-flash-lite',
    'gemini-2.0-flash',
  ];

  static const Duration _timeout = Duration(seconds: 25);

  /// How long a key stays on the quota backoff list after a 429 response.
  static const Duration _quotaBackoff = Duration(minutes: 5);

  void _terminalDebug(String message) {
    developer.log(message, name: 'ChatbotGeminiService');
    // ignore: avoid_print
    print('[ChatbotGeminiService] $message');
  }

  /// Sends a chat request and returns the model's text response.
  ///
  /// [contents] follows the Gemini `contents` schema (role + parts).
  /// [systemPrompt] is sent as a separate `systemInstruction`, keeping it
  /// out of the conversation history.
  ///
  /// Tries every (model, key) combination until one succeeds.
  /// Throws [ChatbotGeminiException] if all attempts are exhausted.
  Future<String> chat({
    required List<Map<String, dynamic>> contents,
    required String systemPrompt,
  }) async {
    final allKeys = ChatbotKeys.geminiApiKeys
        .map((k) => k.trim())
        .where((k) => k.isNotEmpty)
        .toList();

    if (allKeys.isEmpty) {
      throw const ChatbotGeminiException('No chatbot Gemini keys configured');
    }

    ChatbotGeminiException? lastError;
    final attemptTrace = <String>[];

    // Reset disabled models if every model has been disabled, to avoid a
    // permanent deadlock when models are restored on the API side.
    var models = _models.where((m) => !_disabledModels.contains(m)).toList();
    if (models.isEmpty) {
      _disabledModels.clear();
      models = List<String>.from(_models);
    }

    modelLoop:
    for (final model in models) {
      for (final key in allKeys) {
        final now = DateTime.now();
        final keyMask = _maskKey(key);

        if (_invalidKeys.contains(key)) {
          attemptTrace.add(
            'SKIP model=$model key=$keyMask reason=invalid_key_cached',
          );
          continue;
        }

        // Check whether this key is still within its quota cooldown window.
        final blockedUntil = _quotaBackoffUntil[key];
        if (blockedUntil != null && now.isBefore(blockedUntil)) {
          attemptTrace.add(
            'SKIP model=$model key=$keyMask reason=quota_backoff until=${blockedUntil.toIso8601String()}',
          );
          continue;
        }

        attemptTrace.add('TRY model=$model key=$keyMask');
        _terminalDebug('Trying Gemini key $keyMask on model=$model');

        final uri = Uri.parse(
          '$_baseUrl/models/$model:generateContent',
        ).replace(queryParameters: {'key': key});

        // systemInstruction is kept separate from contents per Gemini API spec.
        final body = {
          'contents': contents,
          'systemInstruction': {
            'parts': [
              {'text': systemPrompt},
            ],
          },
          'generationConfig': const {
            'temperature': 0.45,
            'topP': 0.9,
            'maxOutputTokens': 550,
            'responseMimeType': 'text/plain',
          },
        };

        try {
          final response = await _http
              .post(
                uri,
                headers: {
                  'Content-Type': 'application/json',
                  'x-goog-api-key': key,
                },
                body: jsonEncode(body),
              )
              .timeout(_timeout);

          final decodedBody = _safeDecodeToMap(response.body);
          final errorReason = _extractErrorReason(decodedBody);
          final errorMessage = _extractErrorMessage(decodedBody);

          if (response.statusCode >= 200 && response.statusCode < 300) {
            if (decodedBody == null) {
              lastError = ChatbotGeminiException(
                'Invalid Gemini JSON response',
                statusCode: response.statusCode,
                model: model,
                keySuffix: keyMask,
                raw: response.body,
                attemptTrace: _traceSnapshot(attemptTrace),
              );
              attemptTrace.add(
                'FAIL status=${response.statusCode} model=$model key=$keyMask reason=invalid_json',
              );
              continue;
            }

            // A 200 response can still represent a blocked prompt via promptFeedback.
            final blocked = _isPromptBlocked(decodedBody);
            if (blocked) {
              attemptTrace.add(
                'BLOCKED status=${response.statusCode} model=$model key=$keyMask reason=prompt_blocked',
              );
              // Prompt blocks are not retryable — rethrow immediately.
              throw ChatbotGeminiException(
                'Prompt blocked by Gemini safety filters',
                statusCode: response.statusCode,
                model: model,
                keySuffix: keyMask,
                raw: response.body,
                promptBlocked: true,
                attemptTrace: _traceSnapshot(attemptTrace),
              );
            }

            final text = _extractText(decodedBody);
            if (text.isNotEmpty) {
              _terminalDebug(
                'Chatbot Gemini success model=$model key=${_maskKey(key)} chars=${text.length}',
              );
              attemptTrace.add(
                'SUCCESS status=${response.statusCode} model=$model key=$keyMask chars=${text.length}',
              );
              return text;
            }

            // 200 with no usable text — treat as a soft failure and try next key.
            lastError = ChatbotGeminiException(
              'Empty content from Gemini',
              statusCode: response.statusCode,
              model: model,
              keySuffix: keyMask,
              raw: response.body,
              attemptTrace: _traceSnapshot(attemptTrace),
            );
            attemptTrace.add(
              'FAIL status=${response.statusCode} model=$model key=$keyMask reason=empty_content',
            );
            continue;
          }

          // Handle well-known error categories and update state accordingly.
          if (_isInvalidKeyError(response.statusCode, errorReason, errorMessage)) {
            _invalidKeys.add(key);
            attemptTrace.add(
              'MARK_INVALID status=${response.statusCode} model=$model key=$keyMask reason=api_key_invalid',
            );
          } else if (_isQuotaError(
            response.statusCode,
            errorReason,
            errorMessage,
          )) {
            final until = DateTime.now().add(_quotaBackoff);
            _quotaBackoffUntil[key] = until;
            attemptTrace.add(
              'MARK_QUOTA status=${response.statusCode} model=$model key=$keyMask until=${until.toIso8601String()}',
            );
          } else if (_isModelNotFoundError(
            response.statusCode,
            errorReason,
            errorMessage,
          )) {
            // Disable the model for this session and jump to the next one.
            _disabledModels.add(model);
            attemptTrace.add(
              'MARK_MODEL_DISABLED status=${response.statusCode} model=$model reason=model_not_found',
            );
            _terminalDebug('Model disabled for this session: $model');
            lastError = ChatbotGeminiException(
              'Gemini model not available',
              statusCode: response.statusCode,
              model: model,
              keySuffix: keyMask,
              raw: response.body,
              attemptTrace: _traceSnapshot(attemptTrace),
            );
            continue modelLoop;
          }

          lastError = ChatbotGeminiException(
            'Gemini request failed',
            statusCode: response.statusCode,
            model: model,
            keySuffix: keyMask,
            raw: response.body,
            attemptTrace: _traceSnapshot(attemptTrace),
          );
          attemptTrace.add(
            'FAIL status=${response.statusCode} model=$model key=$keyMask reason=http_error code=${errorReason ?? 'unknown'}',
          );
          _terminalDebug(
            'Gemini failed status=${response.statusCode} key=$keyMask model=$model reason=${errorReason ?? 'unknown'}',
          );
          continue;
        } on TimeoutException {
          attemptTrace.add('FAIL status=timeout model=$model key=$keyMask');
          lastError = ChatbotGeminiException(
            'Gemini request timed out',
            model: model,
            keySuffix: keyMask,
            attemptTrace: _traceSnapshot(attemptTrace),
          );
          _terminalDebug('Gemini timed out key=$keyMask model=$model');
        } catch (e) {
          if (e is ChatbotGeminiException) {
            // Prompt-blocked exceptions must propagate immediately.
            if (e.promptBlocked) {
              throw e;
            }
            lastError = e;
            attemptTrace.add('FAIL status=exception model=$model key=$keyMask');
            _terminalDebug('Gemini error key=$keyMask model=$model: $e');
          } else {
            attemptTrace.add('FAIL status=unexpected model=$model key=$keyMask');
            lastError = ChatbotGeminiException(
              'Unexpected Gemini chat error: $e',
              model: model,
              keySuffix: keyMask,
              attemptTrace: _traceSnapshot(attemptTrace),
            );
            _terminalDebug(
              'Unexpected Gemini exception key=$keyMask model=$model: $e',
            );
          }
        }
      }
    }

    // All (model, key) combinations exhausted — summarise the pool state.
    final keysOnBackoff = _quotaBackoffUntil.entries
        .where((entry) => DateTime.now().isBefore(entry.value))
        .length;
    final poolSummary =
        'pool: total=${allKeys.length}, invalid=${_invalidKeys.length}, quota_backoff=$keysOnBackoff, disabled_models=${_disabledModels.length}';
    _terminalDebug('All attempts failed. $poolSummary');

    final finalTrace = <String>[
      ...attemptTrace,
      poolSummary,
    ];

    if (_invalidKeys.length == allKeys.length) {
      throw ChatbotGeminiException(
        'All configured Gemini keys are invalid',
        attemptTrace: _traceSnapshot(finalTrace),
      );
    }

    throw lastError ??
        ChatbotGeminiException(
          'All chatbot Gemini keys failed with unknown reason',
          attemptTrace: _traceSnapshot(finalTrace),
        );
  }

  /// Returns true if the API reported that the prompt was blocked by safety filters.
  bool _isPromptBlocked(Map<String, dynamic> decoded) {
    final promptFeedback = decoded['promptFeedback'];
    if (promptFeedback is! Map) return false;
    final blockReason = promptFeedback['blockReason'];
    return blockReason != null && blockReason.toString().trim().isNotEmpty;
  }

  /// Concatenates all text parts from the first candidate into a single string.
  String _extractText(Map<String, dynamic> decoded) {
    final candidates = decoded['candidates'];
    if (candidates is! List || candidates.isEmpty) return '';
    final first = candidates.first;
    if (first is! Map) return '';

    final content = first['content'];
    final parts = (content is Map) ? content['parts'] : null;
    if (parts is! List) return '';

    final buffer = StringBuffer();
    for (final part in parts) {
      if (part is Map && part['text'] is String) {
        buffer.write(part['text']);
      }
    }

    return buffer.toString().trim();
  }

  /// Returns the last 6 characters of a key prefixed with `***`, e.g. `***abc123`.
  String _maskKey(String key) {
    final v = key.trim();
    if (v.length <= 6) return '***';
    return '***${v.substring(v.length - 6)}';
  }

  /// Decodes [raw] JSON into a map, returning null on any parse failure.
  Map<String, dynamic>? _safeDecodeToMap(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {}
    return null;
  }

  /// Pulls the machine-readable error reason from the `error.details` array
  /// or falls back to `error.status`.
  String? _extractErrorReason(Map<String, dynamic>? decoded) {
    final error = decoded?['error'];
    if (error is! Map) return null;

    final details = error['details'];
    if (details is List) {
      for (final item in details) {
        if (item is Map && item['reason'] is String) {
          final v = (item['reason'] as String).trim();
          if (v.isNotEmpty) return v;
        }
      }
    }

    final status = error['status'];
    if (status is String && status.trim().isNotEmpty) {
      return status.trim();
    }
    return null;
  }

  /// Extracts the human-readable message from `error.message`.
  String? _extractErrorMessage(Map<String, dynamic>? decoded) {
    final error = decoded?['error'];
    if (error is! Map) return null;
    final message = error['message'];
    if (message is String && message.trim().isNotEmpty) {
      return message.trim();
    }
    return null;
  }

  bool _isInvalidKeyError(int status, String? reason, String? message) {
    if (status != 400 && status != 401 && status != 403) return false;
    final r = (reason ?? '').toLowerCase();
    final m = (message ?? '').toLowerCase();
    return r.contains('api_key_invalid') ||
        m.contains('api key not valid') ||
        m.contains('api key not found') ||
        m.contains('invalid api key');
  }

  bool _isQuotaError(int status, String? reason, String? message) {
    if (status == 429) return true;
    final r = (reason ?? '').toLowerCase();
    final m = (message ?? '').toLowerCase();
    return r.contains('resource_exhausted') ||
        m.contains('quota') ||
        m.contains('rate limit');
  }

  bool _isModelNotFoundError(int status, String? reason, String? message) {
    if (status != 404) return false;
    final r = (reason ?? '').toLowerCase();
    final m = (message ?? '').toLowerCase();
    return r.contains('not_found') || m.contains('model');
  }

  /// Returns an immutable snapshot of the attempt trace at the time of calling.
  List<String> _traceSnapshot(List<String> trace) {
    return List<String>.unmodifiable(trace);
  }
}
