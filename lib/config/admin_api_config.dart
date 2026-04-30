class AdminApiConfig {
  AdminApiConfig._();

  static const String baseUrl = String.fromEnvironment(
    'ADMIN_API_BASE_URL',
    defaultValue: 'https://unsent-party-luckless.ngrok-free.dev',
  );

  static const String baseUrls = String.fromEnvironment(
    'ADMIN_API_BASE_URLS',
    defaultValue: '',
  );

  static const String _timeoutSeconds = String.fromEnvironment(
    'ADMIN_API_TIMEOUT_SECONDS',
    defaultValue: '60',
  );

  static Duration get timeout {
    final seconds = int.tryParse(_timeoutSeconds) ?? 60;
    return Duration(seconds: seconds < 5 ? 5 : seconds);
  }

  static void validate() {
    if (baseUrl.trim().isEmpty) {
      throw Exception(
        'Missing ADMIN_API_BASE_URL. Add --dart-define=ADMIN_API_BASE_URL=...',
      );
    }
  }
}
