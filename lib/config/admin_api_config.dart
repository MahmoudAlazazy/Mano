/// Configuration class for the Admin API.
///
/// All values are resolved at compile time via `--dart-define` flags,
/// with sensible defaults for local / development builds.
///
/// Usage example (build / run):
/// ```
/// flutter run --dart-define=ADMIN_API_BASE_URL=https://your-api.example.com
/// ```
class AdminApiConfig {
  // Private constructor prevents instantiation — this is a pure static config class.
  AdminApiConfig._();

  // ── Base URLs ────────────────────────────────────────────────────

  /// Primary base URL for all Admin API requests.
  ///
  /// Resolved from the `ADMIN_API_BASE_URL` compile-time environment variable.
  /// Falls back to the ngrok dev tunnel URL when no value is supplied,
  /// making local development possible without any extra setup.
  static const String baseUrl = String.fromEnvironment(
    'ADMIN_API_BASE_URL',
    defaultValue: 'https://unsent-party-luckless.ngrok-free.dev',
  );

  /// Optional secondary / fallback base URL for the Admin API.
  ///
  /// Resolved from `ADMIN_API_BASE_URLS`. Defaults to an empty string,
  /// meaning no fallback is active unless explicitly provided at build time.
  /// Can be used for load-balancing, failover, or staging environments.
  static const String baseUrls = String.fromEnvironment(
    'ADMIN_API_BASE_URLS',
    defaultValue: '',
  );

  // ── Timeout ──────────────────────────────────────────────────────

  /// Raw timeout value (in seconds) read from the environment as a string.
  ///
  /// Kept private because consumers should use the [timeout] getter,
  /// which performs parsing, validation, and conversion to [Duration].
  static const String _timeoutSeconds = String.fromEnvironment(
    'ADMIN_API_TIMEOUT_SECONDS',
    defaultValue: '180', // 3 minutes — suits large admin payloads
  );

  /// Request timeout parsed from [_timeoutSeconds] and returned as a [Duration].
  ///
  /// - Falls back to **180 seconds** if the env value cannot be parsed as an integer.
  /// - Enforces a **minimum of 5 seconds** to prevent accidental near-zero timeouts
  ///   that would cause every request to fail immediately.
  static Duration get timeout {
    final seconds = int.tryParse(_timeoutSeconds) ?? 180; // Default to 180 s on parse failure
    return Duration(seconds: seconds < 5 ? 5 : seconds);  // Clamp: never below 5 s
  }

  // ── Validation ───────────────────────────────────────────────────

  /// Validates that the required Admin API configuration is present.
  ///
  /// Call this once during app initialization (e.g., in `main()`) to
  /// catch misconfigured builds early — before any network request is made.
  ///
  /// Throws an [Exception] with an actionable message if [baseUrl] is empty,
  /// guiding developers to supply the correct `--dart-define` flag.
  static void validate() {
    if (baseUrl.trim().isEmpty) {
      throw Exception(
        'Missing ADMIN_API_BASE_URL. Add --dart-define=ADMIN_API_BASE_URL=...',
      );
    }
  }
}
