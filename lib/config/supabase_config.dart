class SupabaseConfig {
  SupabaseConfig._();

  static const String supabaseUrl = 'https://yvrcvlolalxmqbiyaqyv.supabase.co';
  static const String supabaseAnonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inl2cmN2bG9sYWx4bXFiaXlhcXl2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzYwNDM3MzMsImV4cCI6MjA5MTYxOTczM30.MsFEyTGsTbdHaR2oZcBxsUjOwQwZiyLXhb5tqOW-8yw';

  static void validate() {
    if (supabaseUrl.isEmpty || supabaseAnonKey.isEmpty) {
      throw Exception(
        'Missing Supabase config. Run with '
        '--dart-define=SUPABASE_URL=... '
        '--dart-define=SUPABASE_ANON_KEY=...',
      );
    }
  }
}
