import 'supabase_service.dart';

/// Stateless service for determining whether an authenticated user has admin
/// privileges.
///
/// Admin status is resolved through three independent checks, any one of which
/// is sufficient to grant access:
/// 1. **Role-based** — `user_metadata` contains a role of `"admin"` or
///    `"super_admin"`.
/// 2. **Flag-based** — `user_metadata` contains a truthy `is_admin` / `admin`
///    / `isAdmin` field.
/// 3. **Email-based** — the user's email matches either the compile-time
///    `ADMIN_EMAILS` environment variable or the hard-coded [_seededAdminEmails]
///    set.
class AdminAccessService {
  // Private constructor — this class is purely static and should never be instantiated.
  AdminAccessService._();

  /// Hard-coded fallback admin emails used during development and seeding.
  /// For production, prefer the [_adminEmailsEnv] approach.
  static const Set<String> _seededAdminEmails = {
    'admin2002@gmail.com',
  };

  /// Comma-separated list of admin emails injected at compile time via
  /// `--dart-define=ADMIN_EMAILS=a@b.com,c@d.com`.
  /// Defaults to an empty string when the variable is not set.
  static const String _adminEmailsEnv = String.fromEnvironment(
    'ADMIN_EMAILS',
    defaultValue: '',
  );

  /// Returns `true` if [user] has admin privileges by any of the three checks
  /// described in the class doc. Returns `false` for a `null` user.
  static bool isAdmin(User? user) {
    if (user == null) return false;

    final metadata = user.userMetadata ?? const <String, dynamic>{};

    // Check 1 — role field (supports multiple common key names).
    final role = _readString(
      metadata['role'] ?? metadata['user_role'] ?? metadata['account_role'],
    ).toLowerCase();
    final roleBased = role == 'admin' || role == 'super_admin';

    // Check 2 — boolean flag (supports multiple common key names).
    final flagBased = _readBool(
      metadata['is_admin'] ?? metadata['admin'] ?? metadata['isAdmin'],
    );

    // Check 3 — email allowlist (env-configured or seeded).
    final normalizedEmail = (user.email ?? '').trim().toLowerCase();
    final emailBased = configuredAdminEmails.contains(normalizedEmail) ||
        _seededAdminEmails.contains(normalizedEmail);

    return roleBased || flagBased || emailBased;
  }

  /// Returns a diagnostic map useful for debugging admin-access decisions.
  ///
  /// [forceAdminAccess] simulates granting admin rights regardless of the
  /// user's actual metadata (useful in local development).
  /// [localAdminEmail] is an optional override email logged alongside the
  /// real auth email for comparison purposes.
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
      // final_is_admin mirrors the logic in isAdmin(), plus the force override.
      'final_is_admin': forceAdminAccess || roleBased || flag || envMatch || seededMatch,
    };
  }

  /// Parses [_adminEmailsEnv] into a normalised set of lowercase email strings.
  /// Returns an empty set when the environment variable was not provided.
  static Set<String> get configuredAdminEmails {
    return _adminEmailsEnv
        .split(',')
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toSet();
  }

  // ─── Private helpers ──────────────────────────────────────────────────────

  /// Returns the trimmed string value of [value], or `''` if it is not a String.
  static String _readString(dynamic value) {
    if (value is String) return value.trim();
    return '';
  }

  /// Converts a dynamic [value] to bool.
  /// Accepts actual booleans, numeric 0/1, and the strings "true", "1", "yes".
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
