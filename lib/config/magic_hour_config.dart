class MagicHourConfig {
  MagicHourConfig._();

  static const String baseUrl = String.fromEnvironment(
    'MAGIC_HOUR_BASE_URL',
    defaultValue: 'https://api.magichour.ai',
  );

  static const String _envKey =
      String.fromEnvironment('MAGIC_HOUR_API_KEY', defaultValue: '');
  static const String _envKeys =
      String.fromEnvironment('MAGIC_HOUR_API_KEYS', defaultValue: '');

  // Optional: hardcode keys here (NOT recommended for production).
  static const List<String> _hardcodedKeys = [
     'mhk_live_vtlbyKxzCrvxQjgB3ksD9eve2gqVu2Lhg10G9jWWpqGNW8sEwtf6PLvgd3yQaspikYoYrZoyShaciKAY',
     'mhk_live_AV7F3eUfqkvIGwaY4HOPonuiIIKowErM1Mii0s1iudWY0Gc34ItUyIC1Qovqqp2nrLQabeWnRxfLTdcH',
     'mhk_live_9YHHaSXsk0x4tiaCFSN7T9QLsWFpfTQz4N7yTOIG9GM4fk8ZwDOwESvYExQiYEbXZkzmoBYOaeKOZhNs',
     'mhk_live_Wfvfw6o6TtfWeNpvNjsUeJKHMjneXTqZ9TqCwOpjJnWyt5cZp4hx6f1Cj0HsoOGW4osyhiPkKKvSCczd',
     'mhk_live_Pp5hlZ3GhUILsC8SLQifqXBYf5Ld34CUocFQdqvSnrTTTjNJHutgQRarvCJjkAbTjY7OCkI5pmMGmIsM',
     'mhk_live_Ly7Xk7kwOF5nUwblxoPTQbAridyTXhEZdla4xSuXpySWYn2knO9tbQdj0uy8NEO296pMAzEvDvpSjY8V',
     '',
     '',
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
    return _hardcodedKeys.where((k) => k.trim().isNotEmpty).toList();
  }

  static void validate() {
    if (keys.isEmpty) {
      throw Exception(
        'Missing Magic Hour API key. Provide --dart-define=MAGIC_HOUR_API_KEY=... '
        'or --dart-define=MAGIC_HOUR_API_KEYS=key1,key2',
      );
    }
  }
}
