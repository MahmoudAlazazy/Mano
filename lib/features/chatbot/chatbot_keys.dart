/// Holds API credentials used by the chatbot layer.
///
/// Keys are stored here as compile-time constants so they can be
/// obfuscated by the build toolchain. Do not commit real keys to
/// version control — replace these with environment-injected values
/// or a secrets manager before going to production.
class ChatbotKeys {
  // Pure-static class; instantiation is intentionally disallowed.
  ChatbotKeys._();

  /// Gemini API keys used exclusively by the chatbot service.
  ///
  /// Multiple keys are provided so the service can rotate to the next
  /// one when a key hits its quota limit or is reported invalid.
  /// Order does not matter — the service iterates through all of them.
  static const List<String> geminiApiKeys = [
    'AIzaSyAQAv0B5mq-0PGWnveYXaKfoik0tUwdDzs',
    'AIzaSyDH8szvbK_PdL6jll6r0SXaQgH6SzUKyBg',
    'AIzaSyCWYG4FEhdjf2-IdM38FAV6wU73en0wIWU',
    'AIzaSyDRKy7RNMVZ7-HLpa7e1Ctbl3X9Xtivz4w',
    'AIzaSyDXxyB1WglV6KKS06yPz4PzgMAS2Mj5014',
    'AIzaSyA0xShal30SbgI0pyBXknYmnCY6KdNgbIF',
    'AIzaSyDm9aYpnRB-Z3cF900nee3RX8JNd5-mHes',
    'AIzaSyD5aYzSokpE5G-mK8HMf_6w0lat38cDM6I',
    'AIzaSyDyjEDibJH4cYJsdeVDAgjctvqeUMWlnq0',
  ];
}
