import 'supabase_service.dart';

class AdminAccessService {
  AdminAccessService._();

  static const Set<String> _seededAdminEmails = {
    'admin2002@gmail.com',
  };

  static const String _adminEmailsEnv = String.fromEnvironment(
    'ADMIN_EMAILS',
    defaultValue: '',
  );

  static bool isAdmin(User? user) {
    if (user == null) return false;

    final metadata = user.userMetadata ?? const <String, dynamic>{};
    final role = _readString(
      metadata['role'] ?? metadata['user_role'] ?? metadata['account_role'],
    ).toLowerCase();

    final roleBased = role == 'admin' || role == 'super_admin';
    final flagBased = _readBool(
      metadata['is_admin'] ?? metadata['admin'] ?? metadata['isAdmin'],
    );
    final normalizedEmail = (user.email ?? '').trim().toLowerCase();
    final emailBased = configuredAdminEmails.contains(normalizedEmail) ||
        _seededAdminEmails.contains(normalizedEmail);

    return roleBased || flagBased || emailBased;
  }

  static Map<String, dynamic> debugInfo(
    User? user, {
    bool forceAdminAccess = false,
    String? localAdminEmail,
  }) {
    final metadata = user?.userMetadata ?? const <String, dynamic>{};
    final role = _readString(
      metadata['role'] ?? metadata['user_role'] ?? metadata['account_role'],
    );
    final flag = _readBool(
      metadata['is_admin'] ?? metadata['admin'] ?? metadata['isAdmin'],
    );
    final normalizedEmail = (user?.email ?? '').trim().toLowerCase();
    final envMatch = configuredAdminEmails.contains(normalizedEmail);
    final seededMatch = _seededAdminEmails.contains(normalizedEmail);
    final roleBased =
        role.toLowerCase() == 'admin' || role.toLowerCase() == 'super_admin';

    return <String, dynamic>{
      'force_admin_access': forceAdminAccess,
      'local_admin_email': localAdminEmail,
      'auth_user_email': user?.email,
      'auth_user_id': user?.id,
      'metadata_role': role,
      'metadata_is_admin': flag,
      'configured_admin_emails': configuredAdminEmails.toList(),
      'seeded_admin_emails': _seededAdminEmails.toList(),
      'email_match_env': envMatch,
      'email_match_seeded': seededMatch,
      'role_based': roleBased,
      'flag_based': flag,
      'final_is_admin': forceAdminAccess || roleBased || flag || envMatch || seededMatch,
    };
  }

  static Set<String> get configuredAdminEmails {
    return _adminEmailsEnv
        .split(',')
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toSet();
  }

  static String _readString(dynamic value) {
    if (value is String) return value.trim();
    return '';
  }

  static bool _readBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      return normalized == 'true' || normalized == '1' || normalized == 'yes';
    }
    return false;
  }
}
