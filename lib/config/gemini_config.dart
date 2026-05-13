/// Configuration class for AI provider settings (Gemini & OpenRouter).
///
/// All values are resolved at **compile time** via `--dart-define` flags,
/// with hardcoded defaults for development builds so the app works
/// out-of-the-box without any extra setup.
///
/// Supported providers:
/// - `gemini`      — Google Gemini (default)
/// - `openrouter`  — OpenRouter proxy (access to many models via one key)
///
/// Example build command:
/// ```
/// flutter run \
///   --dart-define=AI_PROVIDER=gemini \
///   --dart-define=GEMINI_API_KEY=your_key_here
/// ```
class GeminiConfig {
  // Private constructor — this class holds only static members and
  // should never be instantiated directly.
  GeminiConfig._();

  // ── Generic / Provider-Agnostic Environment Variables ────────────
  // These act as universal overrides that take precedence over
  // provider-specific variables, making it easy to switch providers
  // with a single flag change at build time.

  /// Generic AI provider selector (`AI_PROVIDER`).
  /// Accepted values: `"gemini"`, `"google"`, `"openrouter"`, `"open_router"`.
  /// Defaults to empty string → falls back to `"gemini"` in [provider].
  static const String _envProvider = String.fromEnvironment(
    'AI_PROVIDER',
    defaultValue: '',
  );

  /// Generic model override (`AI_MODEL`).
  /// When set, takes precedence over both [geminiModel] and [openRouterModel].
  static const String _envModel = String.fromEnvironment(
    'AI_MODEL',
    defaultValue: '',
  );

  /// Generic single API key (`AI_API_KEY`).
  /// Applied to whichever provider is active; takes precedence over
  /// provider-specific single-key variables.
  static const String _envApiKey = String.fromEnvironment(
    'AI_API_KEY',
    defaultValue: '',
  );

  /// Generic comma-separated API key list (`AI_API_KEYS`).
  /// Highest-priority source for key rotation; applied to the active provider.
  static const String _envApiKeys = String.fromEnvironment(
    'AI_API_KEYS',
    defaultValue: '',
  );

  /// Generic base URL override (`AI_BASE_URL`).
  /// Applied to the active provider when no provider-specific override exists.
  static const String _envBaseUrl = String.fromEnvironment(
    'AI_BASE_URL',
    defaultValue: '',
  );

  // ── Provider-Specific Base URL Overrides ─────────────────────────

  /// Gemini-specific base URL override (`GEMINI_BASE_URL`).
  /// When set, takes precedence over [_envBaseUrl] for Gemini requests.
  static const String _geminiBaseUrlOverride = String.fromEnvironment(
    'GEMINI_BASE_URL',
    defaultValue: '',
  );

  /// OpenRouter-specific base URL override (`OPENROUTER_BASE_URL`).
  /// When set, takes precedence over [_envBaseUrl] for OpenRouter requests.
  static const String _openRouterBaseUrlOverride = String.fromEnvironment(
    'OPENROUTER_BASE_URL',
    defaultValue: '',
  );

  // ── Gemini-Specific Variables ─────────────────────────────────────

  /// Gemini model identifier (`GEMINI_MODEL`).
  /// Defaults to `gemini-2.0-flash` — a fast, cost-efficient model.
  static const String _geminiModel = String.fromEnvironment(
    'GEMINI_MODEL',
    defaultValue: 'gemini-2.0-flash',
  );

  /// Single Gemini API key (`GEMINI_API_KEY`).
  /// Used as the last-resort fallback when no other key source is provided.
  static const String _geminiApiKey = String.fromEnvironment(
    'GEMINI_API_KEY',
    defaultValue: 'AIzaSyDnn-NaM_RR0Zdct0lNkyYYj8bK92Y86Tw',
  );

  /// Comma-separated list of Gemini API keys (`GEMINI_API_KEYS`).
  /// Enables key rotation to distribute quota usage across multiple keys
  /// and reduce the chance of hitting per-key rate limits.
  static const String _geminiApiKeys = String.fromEnvironment(
    'GEMINI_API_KEYS',
    defaultValue:
        'AIzaSyAQAv0B5mq-0PGWnveYXaKfoik0tUwdDzs,'
        'AIzaSyDH8szvbK_PdL6jlI6r0SXaQgH6SzUKyBg,'
        'AIzaSyCWYG4FEhdjf2-IdM38FAV6wU73en0wIWU,'
        'AIzaSyDRKy7RNMVZ7-HLpa7e1Ctbl3X9Xtivz4w,'
        'AIzaSyDXxyB1WgIV6KKS06yPz4PzgMAS2Mj5014,'
        'AIzaSyA0xShal30Sbg10pyBXknYmnCY6KdNgbIF',
  );

  // ── OpenRouter-Specific Variables ─────────────────────────────────

  /// OpenRouter model identifier (`OPENROUTER_MODEL`).
  /// Defaults to a free-tier Nvidia Nemotron model for zero-cost development.
  static const String _openRouterModel = String.fromEnvironment(
    'OPENROUTER_MODEL',
    defaultValue: 'nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free',
  );

  /// Single OpenRouter API key (`OPENROUTER_API_KEY`).
  /// Last-resort fallback when no other OpenRouter key source is provided.
  static const String _openRouterApiKey = String.fromEnvironment(
    'OPENROUTER_API_KEY',
    defaultValue: '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',
  );

  /// Comma-separated list of OpenRouter API keys (`OPENROUTER_API_KEYS`).
  /// Supports key rotation across multiple OpenRouter accounts / credits.
  static const String _openRouterApiKeys = String.fromEnvironment(
    'OPENROUTER_API_KEYS',
    defaultValue: '',
  );

  /// HTTP `Referer` header sent with every OpenRouter request.
  /// Required by some OpenRouter models; leave empty to omit the header.
  static const String openRouterReferer = String.fromEnvironment(
    'OPENROUTER_HTTP_REFERER',
    defaultValue: '',
  );

  /// `X-Title` header value sent with every OpenRouter request.
  /// Identifies this app in OpenRouter's usage dashboard.
  static const String openRouterTitle = String.fromEnvironment(
    'OPENROUTER_X_TITLE',
    defaultValue: 'outfitadvisor',
  );

  // ── Provider Resolution ───────────────────────────────────────────

  /// Returns the active AI provider name (`"gemini"` or `"openrouter"`).
  ///
  /// Priority:
  /// 1. [_envProvider] — explicit override via `--dart-define=AI_PROVIDER=...`
  /// 2. Falls back to `"gemini"` when no valid provider string is supplied.
  static String get provider {
    final explicit = _normalizeProvider(_envProvider);
    if (explicit.isNotEmpty) {
      return explicit; // Use the explicitly configured provider
    }
    return 'gemini'; // Default to Gemini when no provider is specified
  }

  /// Convenience flag — `true` when the active provider is OpenRouter.
  static bool get useOpenRouter => provider == 'openrouter';

  /// `true` when `AI_PROVIDER` was explicitly set at compile time.
  /// Useful for guarding logic that should only run when the provider
  /// was intentionally chosen rather than defaulted.
  static bool get hasExplicitProvider => _envProvider.trim().isNotEmpty;

  // ── Model Resolution ──────────────────────────────────────────────

  /// Resolved Gemini model name.
  /// Uses `GEMINI_MODEL` if non-empty, otherwise falls back to `gemini-2.0-flash`.
  static String get geminiModel =>
      _geminiModel.trim().isNotEmpty ? _geminiModel.trim() : 'gemini-2.0-flash';

  /// Resolved OpenRouter model name.
  /// Uses `OPENROUTER_MODEL` if non-empty, otherwise falls back to the
  /// free Nemotron model.
  static String get openRouterModel => _openRouterModel.trim().isNotEmpty
      ? _openRouterModel.trim()
      : 'nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free';

  /// Resolved model for the **active provider**.
  ///
  /// Priority:
  /// 1. `AI_MODEL` — universal override (provider-agnostic)
  /// 2. Provider-specific model (`openRouterModel` or `geminiModel`)
  static String get model {
    if (_envModel.trim().isNotEmpty) {
      return _envModel.trim(); // Universal model override takes top priority
    }

    if (useOpenRouter) {
      return openRouterModel; // Use OpenRouter's resolved model
    }

    return geminiModel; // Fall back to Gemini's resolved model
  }

  // ── Base URL Resolution ───────────────────────────────────────────

  /// Resolved base URL for Gemini API requests.
  ///
  /// Priority:
  /// 1. `GEMINI_BASE_URL`  — Gemini-specific override
  /// 2. `AI_BASE_URL`      — generic override (only when Gemini is active)
  /// 3. Google's official Generative Language API endpoint
  static String get geminiBaseUrl {
    if (_geminiBaseUrlOverride.trim().isNotEmpty) {
      return _trimTrailingSlash(_geminiBaseUrlOverride.trim()); // Gemini-specific override
    }
    if (_envBaseUrl.trim().isNotEmpty && !useOpenRouter) {
      return _trimTrailingSlash(_envBaseUrl.trim()); // Generic override for Gemini
    }
    return 'https://generativelanguage.googleapis.com/v1beta'; // Official Gemini endpoint
  }

  /// Resolved base URL for OpenRouter API requests.
  ///
  /// Priority:
  /// 1. `OPENROUTER_BASE_URL` — OpenRouter-specific override
  /// 2. `AI_BASE_URL`         — generic override (only when OpenRouter is active)
  /// 3. OpenRouter's official API endpoint
  static String get openRouterBaseUrl {
    if (_openRouterBaseUrlOverride.trim().isNotEmpty) {
      return _trimTrailingSlash(_openRouterBaseUrlOverride.trim()); // OpenRouter-specific override
    }
    if (_envBaseUrl.trim().isNotEmpty && useOpenRouter) {
      return _trimTrailingSlash(_envBaseUrl.trim()); // Generic override for OpenRouter
    }
    return 'https://openrouter.ai/api/v1'; // Official OpenRouter endpoint
  }

  /// Resolved base URL for the **active provider**.
  /// Delegates to [openRouterBaseUrl] or [geminiBaseUrl] depending on [useOpenRouter].
  static String get baseUrl {
    if (useOpenRouter) {
      return openRouterBaseUrl;
    }

    return geminiBaseUrl;
  }

  // ── API Key Resolution ────────────────────────────────────────────

  /// Resolved list of Gemini API keys for key rotation.
  ///
  /// Priority (first non-empty source wins):
  /// 1. `AI_API_KEYS`    — generic multi-key override (when Gemini is active)
  /// 2. `AI_API_KEY`     — generic single-key override (when Gemini is active)
  /// 3. `GEMINI_API_KEYS` — Gemini-specific multi-key list
  /// 4. `GEMINI_API_KEY`  — Gemini-specific single key (last resort)
  static List<String> get geminiKeys {
    final raw = _firstNonEmpty([
      if (!useOpenRouter) _envApiKeys,  // Generic multi-key (Gemini context)
      if (!useOpenRouter) _envApiKey,   // Generic single key (Gemini context)
      _geminiApiKeys,                   // Gemini-specific multi-key list
      _geminiApiKey,                    // Gemini-specific single key fallback
    ]);
    return _splitKeys(raw);
  }

  /// Resolved list of OpenRouter API keys for key rotation.
  ///
  /// Priority (first non-empty source wins):
  /// 1. `AI_API_KEYS`         — generic multi-key override (when OpenRouter is active)
  /// 2. `AI_API_KEY`          — generic single-key override (when OpenRouter is active)
  /// 3. `OPENROUTER_API_KEYS` — OpenRouter-specific multi-key list
  /// 4. `OPENROUTER_API_KEY`  — OpenRouter-specific single key (last resort)
  static List<String> get openRouterKeys {
    final raw = _firstNonEmpty([
      if (useOpenRouter) _envApiKeys,   // Generic multi-key (OpenRouter context)
      if (useOpenRouter) _envApiKey,    // Generic single key (OpenRouter context)
      _openRouterApiKeys,               // OpenRouter-specific multi-key list
      _openRouterApiKey,                // OpenRouter-specific single key fallback
    ]);
    return _splitKeys(raw);
  }

  /// Resolved API key list for the **active provider**.
  /// Returns [openRouterKeys] or [geminiKeys] depending on [useOpenRouter].
  static List<String> get keys {
    return useOpenRouter ? openRouterKeys : geminiKeys;
  }

  // ── Validation ────────────────────────────────────────────────────

  /// Validates that at least one API key is configured for either provider.
  ///
  /// Call this once during app startup (e.g., in `main()`) to surface
  /// misconfigured builds immediately, before any API request is attempted.
  ///
  /// Throws an [Exception] with an actionable `--dart-define` hint when
  /// both key lists are empty.
  static void validate() {
    if (geminiKeys.isEmpty && openRouterKeys.isEmpty) {
      throw Exception(
        'Missing AI key. Provide --dart-define=GEMINI_API_KEY=... or '
        '--dart-define=OPENROUTER_API_KEY=...',
      );
    }
  }

  // ── Private Helpers ───────────────────────────────────────────────

  /// Normalizes a raw provider string to a canonical lowercase identifier.
  ///
  /// - `"gemini"` / `"google"`               → `"gemini"`
  /// - `"openrouter"` / `"open_router"`      → `"openrouter"`
  /// - Empty or unrecognized values           → `"gemini"` (safe default)
  static String _normalizeProvider(String raw) {
    final value = raw.trim().toLowerCase();
    if (value.isEmpty) return '';                              // Signal "not set" to callers
    if (value == 'openrouter' || value == 'open_router') {
      return 'openrouter';                                     // Normalize both spellings
    }
    if (value == 'gemini' || value == 'google') {
      return 'gemini';                                         // Accept "google" as an alias
    }
    return 'gemini';                                           // Unknown value → safe default
  }

  /// Removes one or more trailing `/` characters from a URL string.
  ///
  /// Prevents double-slash issues when path segments are appended to the
  /// base URL (e.g., `baseUrl + '/v1/models'`).
  static String _trimTrailingSlash(String value) {
    var out = value;
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1); // Strip one trailing slash per iteration
    }
    return out;
  }

  /// Returns the first non-empty, non-whitespace string from [values].
  ///
  /// Used to implement the priority-cascade logic for keys and URLs:
  /// whichever source appears first in the list and is non-empty wins.
  /// Returns an empty string if all values are blank.
  static String _firstNonEmpty(List<String> values) {
    for (final value in values) {
      if (value.trim().isNotEmpty) {
        return value; // First non-empty value wins
      }
    }
    return ''; // All values were empty
  }

  /// Splits a comma-separated key string into a clean list of key strings.
  ///
  /// - Trims whitespace around each key.
  /// - Filters out any empty segments produced by trailing commas or
  ///   double commas in the source string.
  /// - Returns an empty immutable list when the input is blank.
  static List<String> _splitKeys(String raw) {
    if (raw.trim().isEmpty) {
      return const <String>[]; // Nothing to split — return an empty list
    }
    return raw
        .split(',')              // Split on comma delimiter
        .map((k) => k.trim())   // Remove surrounding whitespace from each key
        .where((k) => k.isNotEmpty) // Drop empty segments (e.g., trailing commas)
        .toList();
  }
}
