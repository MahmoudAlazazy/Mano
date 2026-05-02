class GeminiConfig {
  GeminiConfig._();

  static const String _envProvider = String.fromEnvironment(
    'AI_PROVIDER',
    defaultValue: '',
  );
  static const String _envModel = String.fromEnvironment(
    'AI_MODEL',
    defaultValue: '',
  );
  static const String _envApiKey = String.fromEnvironment(
    'AI_API_KEY',
    defaultValue: '',
  );
  static const String _envApiKeys = String.fromEnvironment(
    'AI_API_KEYS',
    defaultValue: '',
  );
  static const String _envBaseUrl = String.fromEnvironment(
    'AI_BASE_URL',
    defaultValue: '',
  );
  static const String _geminiBaseUrlOverride = String.fromEnvironment(
    'GEMINI_BASE_URL',
    defaultValue: '',
  );
  static const String _openRouterBaseUrlOverride = String.fromEnvironment(
    'OPENROUTER_BASE_URL',
    defaultValue: '',
  );

  static const String _geminiModel = String.fromEnvironment(
    'GEMINI_MODEL',
    defaultValue: 'gemini-2.0-flash',
  );
  static const String _geminiApiKey = String.fromEnvironment(
    'GEMINI_API_KEY',
    defaultValue: 'AIzaSyDnn-NaM_RR0Zdct0lNkyYYj8bK92Y86Tw',
  );
  static const String _geminiApiKeys = String.fromEnvironment(
    'GEMINI_API_KEYS',
    defaultValue: '',
  );

  static const String _openRouterModel = String.fromEnvironment(
    'OPENROUTER_MODEL',
    defaultValue: 'nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free',
  );
  static const String _openRouterApiKey = String.fromEnvironment(
    'OPENROUTER_API_KEY',
    defaultValue: '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',
  );
  static const String _openRouterApiKeys = String.fromEnvironment(
    'OPENROUTER_API_KEYS',
    defaultValue: '',
  );
  static const String openRouterReferer = String.fromEnvironment(
    'OPENROUTER_HTTP_REFERER',
    defaultValue: '',
  );
  static const String openRouterTitle = String.fromEnvironment(
    'OPENROUTER_X_TITLE',
    defaultValue: 'Mano',
  );

  static String get provider {
    final explicit = _normalizeProvider(_envProvider);
    if (explicit.isNotEmpty) {
      return explicit;
    }
    return 'gemini';
  }

  static bool get useOpenRouter => provider == 'openrouter';
  static bool get hasExplicitProvider => _envProvider.trim().isNotEmpty;

  static String get geminiModel =>
      _geminiModel.trim().isNotEmpty ? _geminiModel.trim() : 'gemini-2.0-flash';

  static String get openRouterModel => _openRouterModel.trim().isNotEmpty
      ? _openRouterModel.trim()
      : 'nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free';

  static String get model {
    if (_envModel.trim().isNotEmpty) {
      return _envModel.trim();
    }

    if (useOpenRouter) {
      return openRouterModel;
    }

    return geminiModel;
  }

  static String get geminiBaseUrl {
    if (_geminiBaseUrlOverride.trim().isNotEmpty) {
      return _trimTrailingSlash(_geminiBaseUrlOverride.trim());
    }
    if (_envBaseUrl.trim().isNotEmpty && !useOpenRouter) {
      return _trimTrailingSlash(_envBaseUrl.trim());
    }
    return 'https://generativelanguage.googleapis.com/v1beta';
  }

  static String get openRouterBaseUrl {
    if (_openRouterBaseUrlOverride.trim().isNotEmpty) {
      return _trimTrailingSlash(_openRouterBaseUrlOverride.trim());
    }
    if (_envBaseUrl.trim().isNotEmpty && useOpenRouter) {
      return _trimTrailingSlash(_envBaseUrl.trim());
    }
    return 'https://openrouter.ai/api/v1';
  }

  static String get baseUrl {
    if (useOpenRouter) {
      return openRouterBaseUrl;
    }

    return geminiBaseUrl;
  }

  static List<String> get geminiKeys {
    final raw = _firstNonEmpty([
      if (!useOpenRouter) _envApiKeys,
      if (!useOpenRouter) _envApiKey,
      _geminiApiKeys,
      _geminiApiKey,
    ]);
    return _splitKeys(raw);
  }

  static List<String> get openRouterKeys {
    final raw = _firstNonEmpty([
      if (useOpenRouter) _envApiKeys,
      if (useOpenRouter) _envApiKey,
      _openRouterApiKeys,
      _openRouterApiKey,
    ]);
    return _splitKeys(raw);
  }

  static List<String> get keys {
    return useOpenRouter ? openRouterKeys : geminiKeys;
  }

  static void validate() {
    if (geminiKeys.isEmpty && openRouterKeys.isEmpty) {
      throw Exception(
        'Missing AI key. Provide --dart-define=GEMINI_API_KEY=... or '
        '--dart-define=OPENROUTER_API_KEY=...',
      );
    }
  }

  static String _normalizeProvider(String raw) {
    final value = raw.trim().toLowerCase();
    if (value.isEmpty) return '';
    if (value == 'openrouter' || value == 'open_router') {
      return 'openrouter';
    }
    if (value == 'gemini' || value == 'google') {
      return 'gemini';
    }
    return 'gemini';
  }

  static String _trimTrailingSlash(String value) {
    var out = value;
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  static String _firstNonEmpty(List<String> values) {
    for (final value in values) {
      if (value.trim().isNotEmpty) {
        return value;
      }
    }
    return '';
  }

  static List<String> _splitKeys(String raw) {
    if (raw.trim().isEmpty) {
      return const <String>[];
    }
    return raw
        .split(',')
        .map((k) => k.trim())
        .where((k) => k.isNotEmpty)
        .toList();
  }
}
