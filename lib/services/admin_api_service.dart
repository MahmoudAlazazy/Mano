import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config/admin_api_config.dart';

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
  final int? statusCode;
  final String? error;
  final bool success;

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

class ApiConnectionStatus {
  const ApiConnectionStatus({
    required this.isConnected,
    this.statusCode,
    this.endpoint,
    this.baseUrl,
    this.error,
    this.checkedAt,
  });

  final bool isConnected;
  final int? statusCode;
  final String? endpoint;
  final String? baseUrl;
  final String? error;
  final DateTime? checkedAt;
}

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

  final bool ok;
  final int statusCode;
  final String body;
  final Uint8List bodyBytes;
  final String? contentType;
  final dynamic jsonBody;
  final Duration duration;
  final String endpoint;
  final String? baseUrl;
  final String? requestUri;
  final String? error;
}

class AdminApiService {
  AdminApiService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  String? _activeBaseUrl;
  List<AdminApiAttempt> _lastConnectionTrace = const <AdminApiAttempt>[];
  List<AdminApiAttempt> _requestHistory = const <AdminApiAttempt>[];

  List<String> get candidateBaseUrls => List<String>.from(_candidateBaseUrls);
  String? get activeBaseUrl => _activeBaseUrl;
  List<AdminApiAttempt> get lastConnectionTrace =>
      List<AdminApiAttempt>.from(_lastConnectionTrace);
  List<AdminApiAttempt> get requestHistory =>
      List<AdminApiAttempt>.from(_requestHistory);

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

  List<String> get _preferredBaseUrls {
    final candidates = _candidateBaseUrls;
    final active = _activeBaseUrl;
    if (active == null || active.trim().isEmpty) return candidates;
    return <String>[
      active,
      ...candidates.where((base) => base != active),
    ];
  }

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

  void _recordRequestAttempt(AdminApiAttempt attempt) {
    final next = <AdminApiAttempt>[attempt, ..._requestHistory];
    _requestHistory = next.take(12).toList();
  }

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
            success: response.statusCode >= 200 && response.statusCode < 500,
          );
          attempts.add(attempt);

          if (attempt.success) {
            _activeBaseUrl = baseUrl;
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
          'ngrok-skip-browser-warning': 'true',
        });

        if (useImagesField) {
          final images = <String>[avatarPath, ...garmentPaths];
          for (final path in images) {
            request.files.add(await http.MultipartFile.fromPath('images', path));
          }
        } else {
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

  dynamic _tryDecodeJson(String raw) {
    if (raw.trim().isEmpty) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }
}
