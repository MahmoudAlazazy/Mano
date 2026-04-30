class GeminiConfig {
  GeminiConfig._();

  static const String model =
      String.fromEnvironment('GEMINI_MODEL', defaultValue: 'gemini-2.0-flash');

  static const String _envKey =
      String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');
  static const String _envKeys =
      String.fromEnvironment('GEMINI_API_KEYS', defaultValue: '');

  static const List<String> _fallbackKeys = [
    'AIzaSyDnn-NaM_RR0Zdct0lNkyYYj8bK92Y86Tw',
  ];

  static List<String> get keys {
    final raw = _envKeys.trim().isNotEmpty ? _envKeys : _envKey;
    if (raw.trim().isNotEmpty) {
      return raw
          .split(',')
          .map((k) => k.trim())
          .where((k) => k.isNotEmpty)
          .toList();
    }
    return _fallbackKeys.where((k) => k.trim().isNotEmpty).toList();
  }

  static void validate() {
    if (keys.isEmpty) {
      throw Exception(
        'Missing Gemini API key. Provide --dart-define=GEMINI_API_KEY=...',
      );
    }
  }
}
