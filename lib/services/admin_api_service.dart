import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config/admin_api_config.dart';

/// Records a single HTTP attempt made by [AdminApiService], whether it
/// succeeded or failed. Used to build connection traces and request history.
class AdminApiAttempt {
  const AdminApiAttempt({
    required this.method,
    required this.baseUrl,
    required this.endpoint,
    required this.timestamp,
    this.statusCode,
    this.error,
    required this.success,
  });

  final String method;
  final String baseUrl;
  final String endpoint;
  final DateTime timestamp;

  /// HTTP status code returned by the server; `null` if the request threw
  /// before a response was received.
  final int? statusCode;

  /// Error message if the request threw an exception; `null` on success.
  final String? error;
  final bool success;

  /// Serialises this attempt to a plain map, suitable for logging or storage.
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'method': method,
      'base_url': baseUrl,
      'endpoint': endpoint,
      'timestamp': timestamp.toIso8601String(),
      'status_code': statusCode,
      'error': error,
      'success': success,
    };
  }
}

/// Snapshot of the most recent connection probe result produced by
/// [AdminApiService.checkConnection].
class ApiConnectionStatus {
  const ApiConnectionStatus({
    required this.isConnected,
    this.statusCode,
    this.endpoint,
    this.baseUrl,
    this.error,
    this.checkedAt,
  });

  /// Whether at least one candidate base URL responded successfully.
  final bool isConnected;
  final int? statusCode;

  /// The endpoint path that resulted in a successful (or last attempted)
  /// connection.
  final String? endpoint;

  /// The base URL that succeeded (or was last tried).
  final String? baseUrl;

  /// Human-readable description when [isConnected] is `false`, including a
  /// per-candidate summary of outcomes.
  final String? error;

  /// Wall-clock time at which the probe completed.
  final DateTime? checkedAt;
}

/// The full result of a single admin API call, including the raw response
/// body, parsed JSON, timing information, and any error details.
class AdminApiResult {
  AdminApiResult({
    required this.ok,
    required this.statusCode,
    required this.body,
    Uint8List? bodyBytes,
    this.contentType,
    this.jsonBody,
    required this.duration,
    required this.endpoint,
    this.baseUrl,
    this.requestUri,
    this.error,
  }) : bodyBytes = bodyBytes ?? Uint8List(0);

  /// `true` when [statusCode] is in the 2xx range.
  final bool ok;
  final int statusCode;

  /// Raw response body as a UTF-8 string.
  final String body;

  /// Raw response bytes; empty (`Uint8List(0)`) when not available.
  final Uint8List bodyBytes;
  final String? contentType;

  /// Pre-parsed JSON body, or `null` if the body was empty or not valid JSON.
  final dynamic jsonBody;

  /// Wall-clock time from the start of the request to receiving the full response.
  final Duration duration;
  final String endpoint;
  final String? baseUrl;

  /// The fully resolved URI that was actually requested.
  final String? requestUri;

  /// Error description when [ok] is `false` due to a thrown exception.
  final String? error;
}

/// HTTP client wrapper for the admin back-end API.
///
/// Supports multiple candidate base URLs (configured via [AdminApiConfig]) and
/// automatically fails over to the next candidate when one is unreachable.
/// The most recently successful base URL is cached as [activeBaseUrl] and
/// tried first on subsequent calls.
///
/// Keeps a rolling window of the last 12 [requestHistory] entries and stores
/// the full attempt trace from the most recent [checkConnection] call.
class AdminApiService {
  /// [client] may be injected for testing; production code uses the default
  /// [http.Client].
  AdminApiService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// The base URL that last produced a successful response; `null` until a
  /// successful call has been made.
  String? _activeBaseUrl;

  /// Ordered attempt log from the most recent [checkConnection] probe,
  /// newest first.
  List<AdminApiAttempt> _lastConnectionTrace = const <AdminApiAttempt>[];

  /// Rolling log of the last 12 request attempts across all endpoints,
  /// newest first.
  List<AdminApiAttempt> _requestHistory = const <AdminApiAttempt>[];

  // ─── Public accessors ────────────────────────────────────────────────────

  /// Defensive copy of the deduplicated list of candidate base URLs derived
  /// from [AdminApiConfig].
  List<String> get candidateBaseUrls => List<String>.from(_candidateBaseUrls);

  String? get activeBaseUrl => _activeBaseUrl;

  /// Defensive copy of the connection-probe attempt trace, newest first.
  List<AdminApiAttempt> get lastConnectionTrace =>
      List<AdminApiAttempt>.from(_lastConnectionTrace);

  /// Defensive copy of the rolling request history, newest first.
  List<AdminApiAttempt> get requestHistory =>
      List<AdminApiAttempt>.from(_requestHistory);

  // ─── Private helpers ─────────────────────────────────────────────────────

  /// Merges and deduplicates base URLs from [AdminApiConfig.baseUrls] (a
  /// comma-separated list) and [AdminApiConfig.baseUrl] (a single fallback).
  /// Trailing slashes are stripped so URLs can be concatenated with paths
  /// that start with '/'.
  List<String> get _candidateBaseUrls {
    final raw = <String>[
      if (AdminApiConfig.baseUrls.trim().isNotEmpty)
        ...AdminApiConfig.baseUrls.split(','),
      AdminApiConfig.baseUrl,
    ];

    final out = <String>[];
    final seen = <String>{};
    for (final value in raw) {
      final base = value.trim().replaceAll(RegExp(r'/$'), '');
      if (base.isEmpty) continue;
      if (seen.add(base)) out.add(base);
    }
    return out;
  }

  /// Returns the candidate base URLs sorted so [_activeBaseUrl] is tried first.
  /// Falls back to the plain [_candidateBaseUrls] order when no active URL is set.
  List<String> get _preferredBaseUrls {
    final candidates = _candidateBaseUrls;
    final active = _activeBaseUrl;
    if (active == null || active.trim().isEmpty) return candidates;
    return <String>[
      active,
      ...candidates.where((base) => base != active),
    ];
  }

  /// Builds a [Uri] by joining [baseUrl] with [path], ensuring exactly one '/'
  /// separator, and appending [queryParameters] when non-empty.
  Uri _buildUriForBase(
    String baseUrl,
    String path, [
    Map<String, String>? queryParameters,
  ]) {
    final normalizedPath = path.isEmpty
        ? ''
        : (path.startsWith('/') ? path : '/$path');
    return Uri.parse('$baseUrl$normalizedPath').replace(
      queryParameters: queryParameters?.isEmpty ?? true ? null : queryParameters,
    );
  }

  /// Prepends [attempt] to [_requestHistory] and trims the list to 12 entries.
  void _recordRequestAttempt(AdminApiAttempt attempt) {
    final next = <AdminApiAttempt>[attempt, ..._requestHistory];
    _requestHistory = next.take(12).toList();
  }

  // ─── Public API methods ──────────────────────────────────────────────────

  /// Probes each candidate base URL across a set of common endpoint paths
  /// (`/health`, `/docs`, `/`) and returns the first successful
  /// [ApiConnectionStatus].
  ///
  /// Any status code below 500 is treated as "reachable" — the API is up even
  /// if it returns 4xx. Updates [_activeBaseUrl] on success and stores the
  /// full attempt trace in [_lastConnectionTrace].
  Future<ApiConnectionStatus> checkConnection() async {
    AdminApiConfig.validate();
    final endpointCandidates = <String>['/health', '/docs', ''];
    final attempts = <AdminApiAttempt>[];

    for (final baseUrl in _candidateBaseUrls) {
      for (final endpoint in endpointCandidates) {
        try {
          final response = await _client
              .get(_buildUriForBase(baseUrl, endpoint))
              .timeout(AdminApiConfig.timeout);

          final attempt = AdminApiAttempt(
            method: 'GET',
            baseUrl: baseUrl,
            endpoint: endpoint.isEmpty ? '/' : endpoint,
            timestamp: DateTime.now(),
            statusCode: response.statusCode,
            // Treat anything below 500 as reachable.
            success: response.statusCode >= 200 && response.statusCode < 500,
          );
          attempts.add(attempt);

          if (attempt.success) {
            _activeBaseUrl = baseUrl;
            // Store the trace newest-first for easier display.
            _lastConnectionTrace = attempts.reversed.toList();
            return ApiConnectionStatus(
              isConnected: true,
              statusCode: response.statusCode,
              endpoint: endpoint.isEmpty ? '/' : endpoint,
              baseUrl: baseUrl,
              checkedAt: DateTime.now(),
            );
          }
        } catch (e) {
          attempts.add(
            AdminApiAttempt(
              method: 'GET',
              baseUrl: baseUrl,
              endpoint: endpoint.isEmpty ? '/' : endpoint,
              timestamp: DateTime.now(),
              error: e.toString(),
              success: false,
            ),
          );
        }
      }
    }

    // All candidates failed — build a human-readable summary for diagnostics.
    _lastConnectionTrace = attempts.reversed.toList();
    final lastError = attempts.isEmpty ? null : attempts.last.error;
    final lastBase = attempts.isEmpty ? null : attempts.last.baseUrl;
    final lastEndpoint = attempts.isEmpty ? null : attempts.last.endpoint;
    final summary = attempts
        .map((attempt) {
          final outcome = attempt.statusCode?.toString() ?? attempt.error ?? 'failed';
          return '${attempt.baseUrl}${attempt.endpoint}: $outcome';
        })
        .join('\n');

    return ApiConnectionStatus(
      isConnected: false,
      endpoint: lastEndpoint,
      baseUrl: lastBase,
      error: attempts.isEmpty
          ? 'Unknown API connection failure'
          : 'All API candidates failed.\n$summary\nLast error: ${lastError ?? 'n/a'}',
      checkedAt: DateTime.now(),
    );
  }

  /// Triggers bulk account creation on the admin API.
  ///
  /// [count] — number of accounts to create (default 100).
  /// [stopOnFail] — whether the server should abort on the first failure.
  /// [threads] — server-side concurrency level.
  ///
  /// The request has no timeout because bulk creation can take an arbitrarily
  /// long time.
  Future<AdminApiResult> createAccounts({
    int count = 100,
    bool stopOnFail = false,
    int threads = 1,
  }) async {
    final query = <String, String>{
      'count': '$count',
      'stop_on_fail': '$stopOnFail',
      'threads': '$threads',
    };

    return _postJson(
      '/create_accounts',
      queryParameters: query,
      disableTimeout: true,
    );
  }

  /// Sends a virtual try-on generation request using a multipart POST.
  ///
  /// [avatarPath] — local file path of the user avatar image.
  /// [garmentPaths] — local file paths of garment images to overlay.
  /// [useImagesField] — when `true`, all files are sent under a single
  ///   `"images"` field (avatar first, then garments). When `false`, the
  ///   avatar uses the `"avatar"` field and garments use `"garments"` — the
  ///   format expected by the standard endpoint.
  ///
  /// Tries each base URL in [_preferredBaseUrls] order and returns on the
  /// first successful response. Updates [_activeBaseUrl] on success.
  Future<AdminApiResult> generate({
    required String avatarPath,
    List<String> garmentPaths = const <String>[],
    bool useImagesField = false,
  }) async {
    final startedAt = DateTime.now();
    AdminApiResult? lastFailure;

    for (final baseUrl in _preferredBaseUrls) {
      final uri = _buildUriForBase(baseUrl, '/generate');
      try {
        final request = http.MultipartRequest('POST', uri);
        request.headers.addAll(const <String, String>{
          'Accept': '*/*',
          // Required to bypass the ngrok browser-warning redirect page.
          'ngrok-skip-browser-warning': 'true',
        });

        if (useImagesField) {
          // Merge avatar and garments into a single "images" field list.
          final images = <String>[avatarPath, ...garmentPaths];
          for (final path in images) {
            request.files.add(await http.MultipartFile.fromPath('images', path));
          }
        } else {
          // Send avatar and garments as separate named fields.
          request.files
              .add(await http.MultipartFile.fromPath('avatar', avatarPath));
          for (final path in garmentPaths) {
            request.files
                .add(await http.MultipartFile.fromPath('garments', path));
          }
        }

        final streamed = await request.send().timeout(AdminApiConfig.timeout);
        final response = await http.Response.fromStream(streamed);
        final result = AdminApiResult(
          ok: response.statusCode >= 200 && response.statusCode < 300,
          statusCode: response.statusCode,
          body: response.body,
          bodyBytes: response.bodyBytes,
          contentType: response.headers['content-type'],
          jsonBody: _tryDecodeJson(response.body),
          duration: DateTime.now().difference(startedAt),
          endpoint: '/generate',
          baseUrl: baseUrl,
          requestUri: uri.toString(),
        );
        _recordRequestAttempt(
          AdminApiAttempt(
            method: 'POST',
            baseUrl: baseUrl,
            endpoint: '/generate',
            timestamp: DateTime.now(),
            statusCode: response.statusCode,
            success: result.ok,
            error: result.ok ? null : response.body,
          ),
        );

        if (result.ok) {
          _activeBaseUrl = baseUrl;
          return result;
        }
        lastFailure = result;
      } catch (e) {
        // Network-level failure — record and try the next base URL.
        final result = AdminApiResult(
          ok: false,
          statusCode: 0,
          body: '',
          bodyBytes: Uint8List(0),
          duration: DateTime.now().difference(startedAt),
          endpoint: '/generate',
          baseUrl: baseUrl,
          requestUri: uri.toString(),
          error: e.toString(),
        );
        _recordRequestAttempt(
          AdminApiAttempt(
            method: 'POST',
            baseUrl: baseUrl,
            endpoint: '/generate',
            timestamp: DateTime.now(),
            error: e.toString(),
            success: false,
          ),
        );
        lastFailure = result;
      }
    }

    // All base URLs failed; return the last recorded failure or a generic error.
    return lastFailure ??
        AdminApiResult(
          ok: false,
          statusCode: 0,
          body: '',
          bodyBytes: Uint8List(0),
          duration: DateTime.now().difference(startedAt),
          endpoint: '/generate',
          error: 'No API base URLs available',
        );
  }

  /// Internal helper that sends a JSON POST to [endpoint] across all
  /// [_preferredBaseUrls], returning on the first 2xx response.
  ///
  /// [queryParameters] are appended to the URL (the request body is empty).
  /// [disableTimeout] skips [AdminApiConfig.timeout] for long-running
  /// operations such as bulk account creation.
  Future<AdminApiResult> _postJson(
    String endpoint, {
    Map<String, String>? queryParameters,
    bool disableTimeout = false,
  }) async {
    final startedAt = DateTime.now();
    AdminApiResult? lastFailure;

    for (final baseUrl in _preferredBaseUrls) {
      final uri = _buildUriForBase(baseUrl, endpoint, queryParameters);
      try {
        final responseFuture = _client.post(uri);
        final response = disableTimeout
            ? await responseFuture
            : await responseFuture.timeout(AdminApiConfig.timeout);
        final result = AdminApiResult(
          ok: response.statusCode >= 200 && response.statusCode < 300,
          statusCode: response.statusCode,
          body: response.body,
          bodyBytes: response.bodyBytes,
          contentType: response.headers['content-type'],
          jsonBody: _tryDecodeJson(response.body),
          duration: DateTime.now().difference(startedAt),
          endpoint: endpoint,
          baseUrl: baseUrl,
          requestUri: uri.toString(),
        );
        _recordRequestAttempt(
          AdminApiAttempt(
            method: 'POST',
            baseUrl: baseUrl,
            endpoint: endpoint,
            timestamp: DateTime.now(),
            statusCode: response.statusCode,
            success: result.ok,
            error: result.ok ? null : response.body,
          ),
        );

        if (result.ok) {
          _activeBaseUrl = baseUrl;
          return result;
        }
        lastFailure = result;
      } catch (e) {
        // Network-level failure — record and try the next base URL.
        final result = AdminApiResult(
          ok: false,
          statusCode: 0,
          body: '',
          bodyBytes: Uint8List(0),
          duration: DateTime.now().difference(startedAt),
          endpoint: endpoint,
          baseUrl: baseUrl,
          requestUri: uri.toString(),
          error: e.toString(),
        );
        _recordRequestAttempt(
          AdminApiAttempt(
            method: 'POST',
            baseUrl: baseUrl,
            endpoint: endpoint,
            timestamp: DateTime.now(),
            error: e.toString(),
            success: false,
          ),
        );
        lastFailure = result;
      }
    }

    // All base URLs failed; return the last recorded failure or a generic error.
    return lastFailure ??
        AdminApiResult(
          ok: false,
          statusCode: 0,
          body: '',
          bodyBytes: Uint8List(0),
          duration: DateTime.now().difference(startedAt),
          endpoint: endpoint,
          error: 'No API base URLs available',
        );
  }

  /// Attempts to JSON-decode [raw]; returns `null` if the string is blank or
  /// not valid JSON, rather than throwing.
  dynamic _tryDecodeJson(String raw) {
    if (raw.trim().isEmpty) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }
}
