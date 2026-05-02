import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../providers/supabase_provider.dart';
import '../services/admin_access_service.dart';
import '../services/admin_api_service.dart';
import '../services/clothing_image_service.dart';
import '../services/supabase_service.dart';
import '../theme/app_theme.dart';

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({
    super.key,
    this.forceAdminAccess = false,
    this.localAdminEmail,
  });

  final bool forceAdminAccess;
  final String? localAdminEmail;

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  final AdminApiService _api = AdminApiService();
  final ClothingImageService _clothingImageService = ClothingImageService();
  final SupabaseService _supabase = SupabaseService();
  final ImagePicker _picker = ImagePicker();

  final TextEditingController _countCtrl =
      TextEditingController(text: '100');
  final TextEditingController _threadsCtrl =
      TextEditingController(text: '1');

  bool _stopOnFail = false;
  bool _isAdmin = false;
  bool _checkingAccess = true;
  bool _isRefreshingDashboard = false;
  bool _isCreatingAccounts = false;
  bool _isGenerating = false;
  bool _isCheckingClothingSearch = false;
  bool _useImagesField = false;
  bool _showDebugConsole = true;

  DateTime? _lastRefreshAt;
  String _opsSummary = 'No operations yet';

  String? _avatarPath;
  final List<String> _garmentPaths = <String>[];
  final List<String> _operationErrors = <String>[];

  ApiConnectionStatus? _apiStatus;
  ClothingImageHealthStatus? _clothingImageStatus;
  AdminApiResult? _lastResult;
  Map<String, dynamic>? _systemSnapshot;
  String? _systemSnapshotError;

  @override
  void initState() {
    super.initState();
    _initAccess();
  }

  @override
  void dispose() {
    _countCtrl.dispose();
    _threadsCtrl.dispose();
    super.dispose();
  }

  Future<void> _initAccess() async {
    final user = context.read<AuthProvider>().user;
    final isAdmin =
        widget.forceAdminAccess || AdminAccessService.isAdmin(user);

    if (!mounted) return;
    setState(() {
      _isAdmin = isAdmin;
      _checkingAccess = false;
      _opsSummary = isAdmin
          ? 'Admin access granted'
          : 'Admin access denied';
    });

    if (isAdmin) {
      await _refreshDashboard();
    }
  }

  Future<void> _refreshDashboard() async {
    final auth = context.read<AuthProvider>();
    final userId = auth.user?.id;
    final profileProvider = context.read<ProfileProvider>();
    final wardrobeProvider = context.read<WardrobeProvider>();
    final outfitProvider = context.read<OutfitProvider>();
    final statsProvider = context.read<StatsProvider>();

    setState(() => _isRefreshingDashboard = true);

    final apiStatusFuture = _api.checkConnection();
    final clothingStatusFuture = _clothingImageService.checkHealth();
    final systemSnapshotFuture = _supabase.getAdminSystemSnapshot();

    final apiStatus = await apiStatusFuture;
    final clothingStatus = await clothingStatusFuture;

    Map<String, dynamic>? systemSnapshot;
    String? systemSnapshotError;
    try {
      systemSnapshot = await systemSnapshotFuture;
    } catch (e) {
      systemSnapshotError = e.toString();
    }

    if (userId != null) {
      await Future.wait([
        profileProvider.loadProfile(userId),
        wardrobeProvider.loadWardrobe(userId),
        outfitProvider.loadOutfits(userId),
        statsProvider.loadStats(userId),
      ]);
    }

    if (!mounted) return;

    setState(() {
      _apiStatus = apiStatus;
      _clothingImageStatus = clothingStatus;
      _systemSnapshot = systemSnapshot;
      _systemSnapshotError = systemSnapshotError;
      _lastRefreshAt = DateTime.now();
      _isRefreshingDashboard = false;
      final hasSnapshot = systemSnapshot != null;
      final tableErrors =
          (systemSnapshot?['errors'] as Map<dynamic, dynamic>?) ?? const {};
      final accessScope = systemSnapshot?['access_scope']?.toString() ?? 'unknown';
      final snapshotState = !hasSnapshot
          ? 'without system snapshot'
          : tableErrors.isNotEmpty
              ? 'with partial snapshot (${tableErrors.length} table errors)'
              : accessScope == 'system_scoped'
              ? 'with full system snapshot'
              : 'with $accessScope snapshot';
      _opsSummary = userId == null
          ? 'Dashboard refreshed in local admin mode $snapshotState at ${_formatTime(_lastRefreshAt!)}'
          : 'Dashboard refreshed $snapshotState at ${_formatTime(_lastRefreshAt!)}';
    });
  }

  Future<void> _checkClothingImageSearch() async {
    setState(() => _isCheckingClothingSearch = true);

    final status = await _clothingImageService.checkHealth();

    if (!mounted) return;
    setState(() {
      _clothingImageStatus = status;
      _isCheckingClothingSearch = false;
      _opsSummary = status.isHealthy
          ? 'Clothing image search healthy at ${_formatTime(status.checkedAt)}'
          : 'Clothing image search issue at ${_formatTime(status.checkedAt)}';
    });

    _showSnack(
      status.isHealthy
          ? 'Clothing image search is healthy'
          : 'Clothing image search has an issue',
    );
  }

  Future<void> _pickAvatar() async {
    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 90,
    );
    if (file == null || !mounted) return;
    setState(() => _avatarPath = file.path);
  }

  Future<void> _addGarments() async {
    final files = await _picker.pickMultiImage(imageQuality: 90);
    if (!mounted || files.isEmpty) return;
    setState(() => _garmentPaths.addAll(files.map((f) => f.path)));
  }

  Future<void> _runCreateAccounts() async {
    final count = int.tryParse(_countCtrl.text.trim()) ?? 0;
    final threads = int.tryParse(_threadsCtrl.text.trim()) ?? 0;

    if (count <= 0 || threads <= 0) {
      _showSnack('Please enter valid count and threads');
      return;
    }

    setState(() => _isCreatingAccounts = true);
    final result = await _api.createAccounts(
      count: count,
      stopOnFail: _stopOnFail,
      threads: threads,
    );

    if (!mounted) return;
    setState(() {
      _isCreatingAccounts = false;
      _lastResult = result;
      _opsSummary = result.ok
          ? '/create_accounts success (${result.statusCode})'
          : '/create_accounts failed (${result.statusCode})';
    });

    if (!result.ok) {
      _addPersistentError(_formatApiError(result));
    }

    _showSnack(
      result.ok
          ? '/create_accounts completed'
          : '/create_accounts failed (${result.statusCode})',
    );
  }

  Future<void> _runGenerate() async {
    if (_avatarPath == null || _avatarPath!.isEmpty) {
      _showSnack('Please pick an avatar image first');
      return;
    }

    if (!_useImagesField && _garmentPaths.isEmpty) {
      _showSnack('Add at least one garment image');
      return;
    }

    setState(() => _isGenerating = true);
    final result = await _api.generate(
      avatarPath: _avatarPath!,
      garmentPaths: _garmentPaths,
      useImagesField: _useImagesField,
    );

    if (!mounted) return;
    setState(() {
      _isGenerating = false;
      _lastResult = result;
      _opsSummary = result.ok
          ? '/generate success (${result.statusCode})'
          : '/generate failed (${result.statusCode})';
    });

    if (!result.ok) {
      _addPersistentError(_formatApiError(result));
    }

    _showSnack(
      result.ok
          ? '/generate completed'
          : '/generate failed (${result.statusCode})',
    );
  }

  void _addPersistentError(String message) {
    final normalized = message.trim();
    if (normalized.isEmpty) return;
    if (_operationErrors.contains(normalized)) return;
    setState(() => _operationErrors.add(normalized));
  }

  void _removePersistentError(String message) {
    setState(() => _operationErrors.remove(message));
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  String _formatApiError(AdminApiResult result) {
    if (result.error != null && result.error!.trim().isNotEmpty) {
      return '${result.endpoint} [${result.baseUrl ?? '-'}]: ${result.error}';
    }
    final body = result.body.trim();
    if (body.isNotEmpty) {
      return '${result.endpoint} [${result.baseUrl ?? '-'}]: HTTP ${result.statusCode} - $body';
    }
    return '${result.endpoint} [${result.baseUrl ?? '-'}]: HTTP ${result.statusCode}';
  }

  String _formatResultBody(AdminApiResult result) {
    if (result.error != null && result.error!.trim().isNotEmpty) {
      return result.error!;
    }
    if (result.jsonBody != null) {
      return _prettyJson(result.jsonBody);
    }
    if (result.body.trim().isNotEmpty) {
      return result.body;
    }
    return 'No response body';
  }

  String _prettyJson(Object? value) {
    const encoder = JsonEncoder.withIndent('  ');
    try {
      return encoder.convert(value);
    } catch (_) {
      return value?.toString() ?? 'null';
    }
  }

  String _short(String? value) {
    if (value == null || value.isEmpty) return '-';
    if (value.length <= 26) return value;
    return '${value.substring(0, 13)}...${value.substring(value.length - 10)}';
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  String _formatClothingStatusValue() {
    final status = _clothingImageStatus;
    if (status == null) return 'Not checked yet';
    if (status.isHealthy) {
      return 'Healthy (${status.searchEngine ?? '-'})';
    }
    return 'Problem detected';
  }

  String? _formatClothingStatusDetail() {
    final status = _clothingImageStatus;
    if (status == null) return null;
    if (status.isHealthy) {
      return '${status.resultCount} URLs, ${status.sampleBytes ?? 0} bytes, ${status.duration.inMilliseconds}ms';
    }
    return status.error ?? 'Search or download check failed';
  }

  String _metricValue(
    Map<String, dynamic>? stats,
    List<String> candidates,
    String fallback,
  ) {
    if (stats == null || stats.isEmpty) return fallback;
    for (final key in candidates) {
      if (stats.containsKey(key) && stats[key] != null) {
        return stats[key].toString();
      }
    }
    return fallback;
  }

  Map<String, dynamic> _snapshotCounts() {
    final counts = _systemSnapshot?['counts'];
    if (counts is Map) {
      return Map<String, dynamic>.from(counts);
    }
    return const <String, dynamic>{};
  }

  String _snapshotCount(String key, {String fallback = '-'}) {
    final counts = _snapshotCounts();
    final value = counts[key];
    if (value == null) return fallback;
    return value.toString();
  }

  String _topCategoriesPreview() {
    final top = _systemSnapshot?['top_categories'];
    if (top is! Map || top.isEmpty) return '-';
    final entries = top.entries.take(3).map((entry) => '${entry.key}:${entry.value}');
    return entries.join(' | ');
  }

  String _snapshotStatusValue() {
    if (_systemSnapshotError != null && _systemSnapshotError!.trim().isNotEmpty) {
      return 'Failed';
    }
    if (_systemSnapshot == null) return 'Not loaded';
    final scope = _systemSnapshot?['access_scope']?.toString() ?? 'unknown';
    switch (scope) {
      case 'system_scoped':
        return 'System scoped';
      case 'user_scoped':
        return 'User scoped (not full system)';
      case 'anonymous':
        return 'Anonymous (limited)';
      default:
        return 'Unknown scope';
    }
  }

  String? _snapshotStatusDetail() {
    if (_systemSnapshotError != null && _systemSnapshotError!.trim().isNotEmpty) {
      return _systemSnapshotError;
    }
    final generatedAt = _systemSnapshot?['generated_at']?.toString();
    final warnings = _systemSnapshot?['warnings'];
    if (warnings is List && warnings.isNotEmpty) {
      return warnings.first.toString();
    }
    final errors = _systemSnapshot?['errors'];
    final hasErrors = errors is Map && errors.isNotEmpty;
    if (hasErrors) {
      return '${errors.length} table errors (check Debug Console)';
    }
    if (generatedAt == null || generatedAt.isEmpty) return null;
    return 'Generated at $generatedAt';
  }

  List<String> _providerErrors({
    required AuthProvider auth,
    required ProfileProvider profile,
    required WardrobeProvider wardrobe,
    required OutfitProvider outfit,
    required StatsProvider stats,
  }) {
    final apiSummary = (_apiStatus?.isConnected ?? false)
        ? null
        : 'API unreachable. Open Debug Console for the full connection trace.';
    final clothingSummary = (_clothingImageStatus == null ||
            _clothingImageStatus!.isHealthy)
        ? null
        : 'Clothing image search: ${_clothingImageStatus!.error ?? 'check failed'}';
    final snapshotErrors = _systemSnapshot?['errors'];
    final snapshotSummary = (snapshotErrors is Map && snapshotErrors.isNotEmpty)
        ? 'System snapshot has ${snapshotErrors.length} table errors (Debug Console has details).'
        : null;

    final errors = <String>[
      if (auth.error != null && auth.error!.trim().isNotEmpty)
        'Auth: ${auth.error!}',
      if (profile.error != null && profile.error!.trim().isNotEmpty)
        'Profile: ${profile.error!}',
      if (wardrobe.error != null && wardrobe.error!.trim().isNotEmpty)
        'Wardrobe: ${wardrobe.error!}',
      if (outfit.error != null && outfit.error!.trim().isNotEmpty)
        'Outfit: ${outfit.error!}',
      if (stats.error != null && stats.error!.trim().isNotEmpty)
        'Stats: ${stats.error!}',
      if (_systemSnapshotError != null && _systemSnapshotError!.trim().isNotEmpty)
        'System snapshot: ${_systemSnapshotError!}',
      ?apiSummary,
      ?clothingSummary,
      ?snapshotSummary,
      ..._operationErrors,
    ];
    return errors.toSet().toList();
  }

  Map<String, dynamic> _buildAccessDebug(AuthProvider auth) {
    return AdminAccessService.debugInfo(
      auth.user,
      forceAdminAccess: widget.forceAdminAccess,
      localAdminEmail: widget.localAdminEmail,
    );
  }

  Map<String, dynamic> _buildProviderDebug({
    required AuthProvider auth,
    required ProfileProvider profile,
    required WardrobeProvider wardrobe,
    required OutfitProvider outfit,
    required StatsProvider stats,
  }) {
    return <String, dynamic>{
      'auth': <String, dynamic>{
        'is_authenticated': auth.isAuthenticated,
        'is_initialized': auth.isInitialized,
        'is_loading': auth.isLoading,
        'remaining_wait_seconds': auth.remainingWaitSeconds,
        'error': auth.error,
      },
      'profile': <String, dynamic>{
        'is_loading': profile.isLoading,
        'error': profile.error,
        'name': profile.profile?.name,
        'favorite_colors_count': profile.profile?.favoriteColors.length ?? 0,
        'occasions_count': profile.profile?.occasions.length ?? 0,
      },
      'wardrobe': <String, dynamic>{
        'is_loading': wardrobe.isLoading,
        'error': wardrobe.error,
        'items_count': wardrobe.items.length,
        'category_counts': wardrobe.categoryCounts,
        'sample_items': wardrobe.items.take(3).toList(),
      },
      'outfit': <String, dynamic>{
        'is_loading': outfit.isLoading,
        'error': outfit.error,
        'outfits_count': outfit.outfits.length,
        'sample_outfits': outfit.outfits.take(3).toList(),
      },
      'stats': <String, dynamic>{
        'is_loading': stats.isLoading,
        'error': stats.error,
        'stats': stats.stats,
        'least_worn_count': stats.leastWornItems.length,
        'least_worn_items': stats.leastWornItems.take(3).toList(),
      },
      'system_snapshot': <String, dynamic>{
        'error': _systemSnapshotError,
        'is_loaded': _systemSnapshot != null,
        'is_authenticated': _systemSnapshot?['is_authenticated'],
        'access_scope': _systemSnapshot?['access_scope'],
        'has_full_access': _systemSnapshot?['has_full_access'],
        'is_likely_rls_limited': _systemSnapshot?['is_likely_rls_limited'],
        'warnings': _systemSnapshot?['warnings'],
        'counts': _systemSnapshot?['counts'],
        'top_categories': _systemSnapshot?['top_categories'],
        'table_errors': _systemSnapshot?['errors'],
      },
    };
  }

  Map<String, dynamic> _buildApiDebug() {
    return <String, dynamic>{
      'candidate_base_urls': _api.candidateBaseUrls,
      'active_base_url': _api.activeBaseUrl,
      'api_status': <String, dynamic>{
        'is_connected': _apiStatus?.isConnected,
        'status_code': _apiStatus?.statusCode,
        'base_url': _apiStatus?.baseUrl,
        'endpoint': _apiStatus?.endpoint,
        'checked_at': _apiStatus?.checkedAt?.toIso8601String(),
        'error': _apiStatus?.error,
      },
      'clothing_image_search': <String, dynamic>{
        'mode': 'internal_dart',
        'status': _clothingImageStatus?.toMap(),
      },
      'connection_trace': _api.lastConnectionTrace
          .map((attempt) => attempt.toMap())
          .toList(),
      'request_history': _api.requestHistory
          .map((attempt) => attempt.toMap())
          .toList(),
      'last_result': _lastResult == null
          ? null
          : <String, dynamic>{
              'ok': _lastResult!.ok,
              'status_code': _lastResult!.statusCode,
              'endpoint': _lastResult!.endpoint,
              'base_url': _lastResult!.baseUrl,
              'request_uri': _lastResult!.requestUri,
              'duration_ms': _lastResult!.duration.inMilliseconds,
              'error': _lastResult!.error,
              'body_preview': _lastResult!.body.length > 400
                  ? _lastResult!.body.substring(0, 400)
                  : _lastResult!.body,
            },
    };
  }

  Widget _buildDebugConsole({
    required AuthProvider auth,
    required ProfileProvider profile,
    required WardrobeProvider wardrobe,
    required OutfitProvider outfit,
    required StatsProvider stats,
  }) {
    final accessDebug = _buildAccessDebug(auth);
    final providerDebug = _buildProviderDebug(
      auth: auth,
      profile: profile,
      wardrobe: wardrobe,
      outfit: outfit,
      stats: stats,
    );
    final apiDebug = _buildApiDebug();

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: _showDebugConsole,
          onExpansionChanged: (value) {
            setState(() => _showDebugConsole = value);
          },
          title: const Text(
            'Debug Console',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          subtitle: const Text(
            'Access, API trace, provider state, and raw dumps',
            style: TextStyle(fontSize: 12),
          ),
          childrenPadding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            0,
            AppSpacing.md,
            AppSpacing.md,
          ),
          children: [
            _DebugBlock(
              title: 'Access Diagnostics',
              body: _prettyJson(accessDebug),
            ),
            const SizedBox(height: AppSpacing.sm),
            _DebugBlock(
              title: 'API Trace',
              body: _prettyJson(apiDebug),
            ),
            const SizedBox(height: AppSpacing.sm),
            _DebugBlock(
              title: 'Provider State',
              body: _prettyJson(providerDebug),
            ),
            const SizedBox(height: AppSpacing.sm),
            _DebugBlock(
              title: 'System Snapshot (All Users)',
              body: _prettyJson(
                _systemSnapshot ?? <String, dynamic>{'error': _systemSnapshotError ?? 'not loaded'},
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final profileProvider = context.watch<ProfileProvider>();
    final wardrobeProvider = context.watch<WardrobeProvider>();
    final outfitProvider = context.watch<OutfitProvider>();
    final statsProvider = context.watch<StatsProvider>();

    final user = auth.user;
    final adminEmail = widget.localAdminEmail ?? user?.email;
    final profile = profileProvider.profile;
    final snapshotCounts = _snapshotCounts();
    final snapshotScope = _systemSnapshot?['access_scope']?.toString();
    final snapshotWarningsRaw = _systemSnapshot?['warnings'];
    final snapshotWarnings = snapshotWarningsRaw is List
        ? snapshotWarningsRaw.map((e) => e.toString()).toList()
        : const <String>[];
    final isSystemScoped = snapshotScope == 'system_scoped';
    final isDataScopeLimited =
        !auth.isAuthenticated || snapshotScope != 'system_scoped';
    final activeProviderLoads = <bool>[
      profileProvider.isLoading,
      wardrobeProvider.isLoading,
      outfitProvider.isLoading,
      statsProvider.isLoading,
    ].where((isLoading) => isLoading).length;
    final providerLoadDetails =
        'Profile:${profileProvider.isLoading ? 'loading' : 'ready'} | '
        'Wardrobe:${wardrobeProvider.isLoading ? 'loading' : 'ready'} | '
        'Outfit:${outfitProvider.isLoading ? 'loading' : 'ready'} | '
        'Stats:${statsProvider.isLoading ? 'loading' : 'ready'}';
    final allErrors = _providerErrors(
      auth: auth,
      profile: profileProvider,
      wardrobe: wardrobeProvider,
      outfit: outfitProvider,
      stats: statsProvider,
    );

    if (_checkingAccess) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (!_isAdmin) {
      return Scaffold(
        appBar: AppBar(title: const Text('Admin Dashboard')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.lock_outline_rounded, size: 52, color: AppColors.error),
                SizedBox(height: AppSpacing.md),
                Text(
                  'Access denied. Admin only.',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Admin Dashboard'),
        actions: [
          IconButton(
            onPressed: _isRefreshingDashboard ? null : _refreshDashboard,
            icon: _isRefreshingDashboard
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'System Health',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppSpacing.sm),
            if (isDataScopeLimited)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(
                    color: AppColors.warning.withValues(alpha: 0.45),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.info_outline_rounded,
                      color: AppColors.warning,
                      size: 18,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        snapshotWarnings.isNotEmpty
                            ? snapshotWarnings.first
                            : 'Dashboard is not system-scoped yet. Current data may be empty or user-limited.',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            _StatusCard(title: 'Admin Email', value: adminEmail ?? '-'),
            _StatusCard(title: 'User ID', value: _short(user?.id)),
            _StatusCard(
              title: 'Auth State',
              value: auth.isAuthenticated ? 'Authenticated' : 'Not authenticated',
              subValue: widget.forceAdminAccess
                  ? 'Local admin bypass is active'
                  : 'Initialized: ${auth.isInitialized}',
            ),
            _StatusCard(
              title: 'API Connection',
              value: _apiStatus == null
                  ? 'Not checked yet'
                  : (_apiStatus!.isConnected
                      ? 'Connected (${_apiStatus!.statusCode ?? '-'})'
                      : 'Disconnected'),
              subValue: _apiStatus == null
                  ? null
                  : '${_apiStatus!.baseUrl ?? '-'} ${_apiStatus!.endpoint ?? ''}'
                      .trim(),
            ),
            _StatusCard(
              title: 'Clothes Image Search',
              value: _formatClothingStatusValue(),
              subValue: _formatClothingStatusDetail(),
            ),
            _StatusCard(
              title: 'System Snapshot',
              value: _snapshotStatusValue(),
              subValue: _snapshotStatusDetail(),
            ),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _isCheckingClothingSearch
                    ? null
                    : _checkClothingImageSearch,
                icon: _isCheckingClothingSearch
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.image_search_rounded),
                label: Text(
                  _isCheckingClothingSearch
                      ? 'Checking clothing search...'
                      : 'Check Clothing Image Search',
                ),
              ),
            ),
            _StatusCard(
              title: 'Last Refresh',
              value: _lastRefreshAt == null ? '-' : _formatTime(_lastRefreshAt!),
              subValue: _isRefreshingDashboard ? 'Refreshing now...' : null,
            ),
            _StatusCard(
              title: 'Provider Loads',
              value: activeProviderLoads > 0
                  ? '$activeProviderLoads active request(s)'
                  : 'No active requests',
              subValue: providerLoadDetails,
            ),
            const SizedBox(height: AppSpacing.lg),

            const Text(
              'Business Metrics',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppSpacing.sm),
            _StatusCard(
              title: 'Metrics Scope',
              value: isSystemScoped ? 'Global system data' : 'Limited scope',
              subValue: isSystemScoped
                  ? 'You are seeing all users data.'
                  : 'Global metrics are unavailable in current session scope.',
            ),
            if (isSystemScoped) ...[
              _StatusCard(
                title: 'Total Users',
                value: _snapshotCount('users'),
              ),
              _StatusCard(
                title: 'Users With Wardrobe',
                value: _snapshotCount('users_with_wardrobe'),
              ),
              _StatusCard(
                title: 'Users With Outfits',
                value: _snapshotCount('users_with_outfits'),
              ),
              _StatusCard(
                title: 'Users With Wear History',
                value: _snapshotCount('users_with_wear_history'),
              ),
              _StatusCard(
                title: 'Clothing Items (Global)',
                value: _snapshotCount('clothing_items'),
              ),
              _StatusCard(
                title: 'Saved Outfits (Global)',
                value: _snapshotCount('saved_outfits'),
              ),
              _StatusCard(
                title: 'Outfit Items Links',
                value: _snapshotCount('outfit_items'),
              ),
              _StatusCard(
                title: 'Wear Events (Global)',
                value: _snapshotCount('wear_history'),
              ),
              _StatusCard(
                title: 'Favorite Clothing Items',
                value: _snapshotCount('favorite_clothing_items'),
              ),
              _StatusCard(
                title: 'Favorite Outfits',
                value: _snapshotCount('favorite_outfits'),
              ),
              _StatusCard(
                title: 'Most Worn Category (Global)',
                value: snapshotCounts['top_category']?.toString() ?? '-',
                subValue: 'Count: ${snapshotCounts['top_category_count'] ?? '-'}',
              ),
              _StatusCard(
                title: 'Top Categories',
                value: _topCategoriesPreview(),
              ),
            ] else ...[
              _StatusCard(
                title: 'Current Session Profile',
                value: profile == null ? 'Missing' : profile.name,
              ),
              _StatusCard(
                title: 'Session Wardrobe Items',
                value: wardrobeProvider.items.length.toString(),
              ),
              _StatusCard(
                title: 'Session Saved Outfits',
                value: outfitProvider.outfits.length.toString(),
              ),
              _StatusCard(
                title: 'Session Wear Events',
                value: _metricValue(
                  statsProvider.stats,
                  const ['total_wears', 'wear_events', 'total_wear_events'],
                  '0',
                ),
              ),
              _StatusCard(
                title: 'Global Metrics',
                value: 'Locked by RLS scope',
                subValue: snapshotWarnings.isNotEmpty
                    ? snapshotWarnings.first
                    : 'Sign in with an account that has system-scoped policy access.',
              ),
            ],
            const SizedBox(height: AppSpacing.lg),

            const Text(
              'Ops Summary',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppSpacing.sm),
            _StatusCard(
              title: 'Summary',
              value: _opsSummary,
            ),
            const SizedBox(height: AppSpacing.sm),
            _buildDebugConsole(
              auth: auth,
              profile: profileProvider,
              wardrobe: wardrobeProvider,
              outfit: outfitProvider,
              stats: statsProvider,
            ),
            const SizedBox(height: AppSpacing.lg),

            if (allErrors.isNotEmpty) ...[
              const Text(
                'Persistent Errors',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: AppSpacing.sm),
              ...allErrors.map((error) {
                final dismissible = _operationErrors.contains(error);
                return Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: AppColors.error.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    border: Border.all(color: AppColors.error.withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.error_outline_rounded,
                        color: AppColors.error,
                        size: 18,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          error,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      if (dismissible)
                        IconButton(
                          onPressed: () => _removePersistentError(error),
                          icon: const Icon(Icons.close_rounded, size: 16),
                        ),
                    ],
                  ),
                );
              }),
              const SizedBox(height: AppSpacing.md),
            ],

            const Text(
              'Create Accounts API',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _countCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'count'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: TextField(
                    controller: _threadsCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'threads'),
                  ),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _stopOnFail,
              onChanged: (value) => setState(() => _stopOnFail = value),
              title: const Text('stop_on_fail'),
            ),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isCreatingAccounts ? null : _runCreateAccounts,
                icon: _isCreatingAccounts
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.group_add_rounded, color: Colors.white),
                label: Text(
                  _isCreatingAccounts ? 'Running...' : 'Run /create_accounts',
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),

            const Text(
              'Generate API',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppSpacing.sm),
            _StatusCard(
              title: 'Avatar',
              value: _avatarPath == null ? 'Not selected' : _short(_avatarPath),
            ),
            _StatusCard(
              title: 'Garments',
              value: '${_garmentPaths.length} selected',
            ),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: _garmentPaths.asMap().entries.map((entry) {
                final index = entry.key;
                final path = entry.value;
                return Chip(
                  label: Text(_short(path)),
                  onDeleted: () => setState(() => _garmentPaths.removeAt(index)),
                );
              }).toList(),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _pickAvatar,
                    child: const Text('Pick Avatar'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _addGarments,
                    child: const Text('Add Garments'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            OutlinedButton(
              onPressed: () {
                setState(() {
                  _avatarPath = null;
                  _garmentPaths.clear();
                });
              },
              child: const Text('Clear Images'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _useImagesField,
              onChanged: (value) => setState(() => _useImagesField = value),
              title: const Text('Use images[] mode'),
              subtitle: const Text(
                'If enabled: first image is avatar, rest are garments',
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isGenerating ? null : _runGenerate,
                icon: _isGenerating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.auto_awesome_rounded, color: Colors.white),
                label: Text(_isGenerating ? 'Running...' : 'Run /generate'),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),

            if (_lastResult != null) ...[
              const Text(
                'Last API Response',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: AppSpacing.sm),
              _StatusCard(
                title: 'Endpoint',
                value: _lastResult!.endpoint,
                subValue: _lastResult!.requestUri,
              ),
              _StatusCard(
                title: 'Status',
                value: _lastResult!.statusCode == 0
                    ? 'Request failed'
                    : _lastResult!.statusCode.toString(),
                subValue:
                    'Base: ${_lastResult!.baseUrl ?? '-'} | Duration: ${_lastResult!.duration.inMilliseconds}ms',
              ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(color: AppColors.border),
                ),
                child: SelectableText(
                  _formatResultBody(_lastResult!),
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.title,
    required this.value,
    this.subValue,
  });

  final String title;
  final String value;
  final String? subValue;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          if (subValue != null && subValue!.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              subValue!,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _DebugBlock extends StatelessWidget {
  const _DebugBlock({
    required this.title,
    required this.body,
  });

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          SelectableText(
            body,
            style: const TextStyle(
              fontSize: 11.5,
              height: 1.45,
              fontFamily: 'monospace',
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
