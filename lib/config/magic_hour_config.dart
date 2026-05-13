/// Configuration class for the Magic Hour AI API.
///
/// Manages the base URL and API key pool used to communicate with
/// [Magic Hour](https://magichour.ai) — the service powering virtual
/// try-on and AI image generation features in this app.
///
/// Keys are resolved at **compile time** from `--dart-define` flags.
/// Hardcoded development keys are provided as a last-resort fallback
/// so the feature works out-of-the-box without any extra setup.
///
/// Key resolution priority:
/// 1. `MAGIC_HOUR_API_KEYS` — comma-separated list (highest priority)
/// 2. `MAGIC_HOUR_API_KEY`  — single key override
/// 3. [_hardcodedKeys]      — built-in development pool (last resort)
///
/// Example build command:
/// ```
/// flutter run --dart-define=MAGIC_HOUR_API_KEY=mhk_live_your_key_here
/// ```
class MagicHourConfig {
  // Private constructor — this is a pure static config class and
  // should never be instantiated.
  MagicHourConfig._();

  // ── Base URL ──────────────────────────────────────────────────────

  /// Base URL for all Magic Hour API requests.
  ///
  /// Resolved from `MAGIC_HOUR_BASE_URL` at compile time.
  /// Defaults to the official Magic Hour API endpoint when not overridden,
  /// which suits both development and production builds.
  static const String baseUrl = String.fromEnvironment(
    'MAGIC_HOUR_BASE_URL',
    defaultValue: 'https://api.magichour.ai',
  );

  // ── Environment Key Sources ───────────────────────────────────────

  /// Single Magic Hour API key supplied via `--dart-define=MAGIC_HOUR_API_KEY=...`.
  ///
  /// Used as a fallback when [_envKeys] is empty. Defaults to an empty
  /// string, which signals that no runtime key was provided.
  static const String _envKey =
      String.fromEnvironment('MAGIC_HOUR_API_KEY', defaultValue: '');

  /// Comma-separated list of Magic Hour API keys via `--dart-define=MAGIC_HOUR_API_KEYS=...`.
  ///
  /// Takes precedence over [_envKey] when non-empty. Enables key rotation
  /// across multiple Magic Hour accounts to spread quota usage and reduce
  /// the risk of hitting per-key rate limits.
  static const String _envKeys =
      String.fromEnvironment('MAGIC_HOUR_API_KEYS', defaultValue: '');

  // ── Hardcoded Fallback Keys ───────────────────────────────────────

  /// Built-in development API key pool.
  ///
  /// **WARNING: NOT recommended for production.**
  /// These keys are compiled into the binary and visible to anyone who
  /// reverse-engineers the app. Always supply keys via `--dart-define`
  /// for staging and production builds.
  ///
  /// Empty strings at the end of the list are intentional placeholders —
  /// they are filtered out in [keys] and have no effect at runtime.
  static const List<String> _hardcodedKeys = [
    'mhk_live_vtlbyKxzCrvxQjgB3ksD9eve2gqVu2Lhg10G9jWWpqGNW8sEwtf6PLvgd3yQaspikYoYrZoyShaciKAY',
    'mhk_live_AV7F3eUfqkvIGwaY4HOPonuiIIKowErM1Mii0s1iudWY0Gc34ItUyIC1Qovqqp2nrLQabeWnRxfLTdcH',
    'mhk_live_9YHHaSXsk0x4tiaCFSN7T9QLsWFpfTQz4N7yTOIG9GM4fk8ZwDOwESvYExQiYEbXZkzmoBYOaeKOZhNs',
    'mhk_live_Wfvfw6o6TtfWeNpvNjsUeJKHMjneXTqZ9TqCwOpjJnWyt5cZp4hx6f1Cj0HsoOGW4osyhiPkKKvSCczd',
    'mhk_live_Pp5hlZ3GhUILsC8SLQifqXBYf5Ld34CUocFQdqvSnrTTTjNJHutgQRarvCJjkAbTjY7OCkI5pmMGmIsM',
    'mhk_live_Ly7Xk7kwOF5nUwblxoPTQbAridyTXhEZdla4xSuXpySWYn2knO9tbQdj0uy8NEO296pMAzEvDvpSjY8V',
    '', // Placeholder — filtered out at runtime
    '', // Placeholder — filtered out at runtime
  ];

  // ── Key Resolution ────────────────────────────────────────────────

  /// Returns the active list of Magic Hour API keys for key rotation.
  ///
  /// Resolution order (first non-empty source wins):
  /// 1. `MAGIC_HOUR_API_KEYS` — comma-separated multi-key list (highest priority)
  /// 2. `MAGIC_HOUR_API_KEY`  — single key override
  /// 3. [_hardcodedKeys]      — built-in pool, with empty entries filtered out
  ///
  /// The returned list always contains only non-empty, trimmed key strings.
  static List<String> get keys {
    // Prefer the multi-key env var; fall back to the single-key env var.
    final raw = _envKeys.trim().isNotEmpty ? _envKeys : _envKey;

    if (raw.trim().isNotEmpty) {
      // Parse the comma-separated string, trim whitespace, and drop empty segments.
      return raw
          .split(',')               // Split on comma delimiter
          .map((k) => k.trim())    // Remove surrounding whitespace from each key
          .where((k) => k.isNotEmpty) // Drop empty entries from double commas / trailing comma
          .toList();
    }

    // No env keys provided — fall back to the hardcoded development pool,
    // filtering out the empty placeholder strings.
    return _hardcodedKeys.where((k) => k.trim().isNotEmpty).toList();
  }

  // ── Validation ────────────────────────────────────────────────────

  /// Validates that at least one usable API key is available.
  ///
  /// Call this once during app initialization (e.g., in `main()`) to
  /// catch misconfigured builds before any Magic Hour request is made.
  ///
  /// Throws an [Exception] with an actionable `--dart-define` hint when
  /// no keys are found from any source.
  static void validate() {
    if (keys.isEmpty) {
      throw Exception(
        'Missing Magic Hour API key. Provide --dart-define=MAGIC_HOUR_API_KEY=... '
        'or --dart-define=MAGIC_HOUR_API_KEYS=key1,key2',
      );
    }
  }
}
