import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';
import 'package:outfitadvisor/providers/supabase_provider.dart';
import 'package:provider/provider.dart';
import 'package:geolocator/geolocator.dart';
import '../main.dart' show AppRoutes;
import '../theme/app_theme.dart';
import '../widgets/bottom_nav_bar.dart';
import '../widgets/outfit_option_card.dart';
import '../services/supabase_service.dart';
import '../services/weather_service.dart';
import '../services/outfit_suggestion_service.dart';
import '../services/clothing_image_service.dart';
part 'outfit_screen/ui_components.dart';
part 'outfit_screen/generated_outfit_sheet.dart';
part 'outfit_screen/models.dart';
part 'outfit_screen/save_outfit_page.dart';

/// The main outfit generation screen.
///
/// Lets the user choose a recommendation mode (wardrobe-only, full AI, or
/// mix-and-match), an occasion, an audience (men/women), and a location for
/// live weather context, then calls Gemini to generate an outfit. Falls back
/// to locally-seeded suggestions when the AI request fails.
class OutfitScreen extends StatefulWidget {
  const OutfitScreen({super.key});

  @override
  State<OutfitScreen> createState() => _OutfitScreenState();
}

class _OutfitScreenState extends State<OutfitScreen>
    with SingleTickerProviderStateMixin {
  // ── Selection state ───────────────────────────────────────────
  int _selectedOption = 0; // index into [_options]
  int _selectedOccasion = 0; // index into [_occasions]
  int _selectedAudience = 0; // 0 = Men, 1 = Women

  // ── Generation state ──────────────────────────────────────────
  bool _isGenerating = false;
  String? _generationStatus; // progress label shown below the button
  String? _errorMessage;

  // ── Weather state ─────────────────────────────────────────────
  String _selectedGovernorate = 'Cairo';
  double _temperatureC = 24.0;
  bool _isWeatherLoading = false;
  String? _weatherError;
  DateTime? _weatherUpdatedAt;
  String? _weatherSummary;
  String _weatherLocationLabel = 'Detecting location...';
  bool _usingDeviceLocation = true;

  // Prevents route arguments from being applied more than once.
  bool _didReadRouteArgs = false;

  // ── Services ──────────────────────────────────────────────────
  final WeatherService _weatherService = WeatherService();
  final ClothingImageService _clothingImageService = ClothingImageService();

  /// Cache of resolved coordinates keyed by governorate name, to avoid
  /// repeated geocoding calls for the same location.
  final Map<String, WeatherCoordinates> _coordinatesCache = {};

  // ── Animation ─────────────────────────────────────────────────
  late final AnimationController _controller;
  late final Animation<double> _fadeAnim;
  late final Animation<Offset> _slideAnim;

  // ── Static option definitions ─────────────────────────────────

  /// The three recommendation modes available to the user.
  static const List<_OutfitOption> _options = [
    _OutfitOption(
      icon: Icons.shopping_bag_outlined,
      title: 'Use My Wardrobe',
      description: 'Suggest an outfit using only my own clothes.',
    ),
    _OutfitOption(
      icon: Icons.auto_awesome_rounded,
      title: 'Full Outfit Suggestion',
      description: 'Suggest new items outside my wardrobe.',
    ),
    _OutfitOption(
      icon: Icons.shuffle_rounded,
      title: 'Mix & Match',
      description: 'Combine my wardrobe with AI-suggested pieces.',
    ),
  ];

  static const List<String> _occasions = [
    'Casual',
    'Business',
    'Formal',
    'Sport',
  ];

  static const List<_AudienceOption> _audiences = [
    _AudienceOption(label: 'Men', searchValue: 'men', icon: Icons.male_rounded),
    _AudienceOption(
      label: 'Women',
      searchValue: 'women',
      icon: Icons.female_rounded,
    ),
  ];

  /// Complete list of Egyptian governorates used in the location picker.
  static const List<String> _governorates = [
    'Cairo',
    'Giza',
    'Alexandria',
    'Dakahlia',
    'Red Sea',
    'Beheira',
    'Fayoum',
    'Gharbia',
    'Ismailia',
    'Menofia',
    'Minya',
    'Qalyubia',
    'New Valley',
    'Suez',
    'Aswan',
    'Assiut',
    'Beni Suef',
    'Port Said',
    'Damietta',
    'Sharkia',
    'South Sinai',
    'Kafr El Sheikh',
    'Matrouh',
    'Luxor',
    'Qena',
    'North Sinai',
    'Sohag',
  ];

  // ── Lifecycle ──────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();

    // Fade + slide-up entrance animation for the screen content.
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _fadeAnim = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.05),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    _loadWeather();

    Future.delayed(const Duration(milliseconds: 80), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Apply route arguments exactly once; they are available after the first
    // frame when the ModalRoute is attached.
    if (_didReadRouteArgs) return;
    _didReadRouteArgs = true;
    _hydrateSelectionFromRouteArgs();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // ── Navigation ────────────────────────────────────────────────

  /// Pops the current route if possible; otherwise navigates to Home,
  /// preventing an empty back-stack.
  Future<bool> _handleBackNavigation() async {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
      return false;
    }
    navigator.pushReplacementNamed(AppRoutes.home);
    return false;
  }

  // ── Debug helpers ─────────────────────────────────────────────

  /// Updates the generation status label and emits a debug log entry.
  void _setGenerationStatus(String? status) {
    if (!mounted) return;
    setState(() => _generationStatus = status);
    if (status != null && status.trim().isNotEmpty) {
      _terminalDebug(status, tag: 'OutfitScreen');
    }
  }

  /// Logs [message] via both `dart:developer` and `print` for visibility
  /// in both DevTools and raw terminal output.
  void _terminalDebug(String message, {String tag = 'OutfitDebug'}) {
    developer.log(message, name: tag);
    // ignore: avoid_print
    print('[$tag] $message');
  }

  /// Normalises a debug string to lowercase alphanumeric + spaces
  /// so comparisons are not thrown off by punctuation or casing.
  String _normalizeDebugValue(String? value) {
    if (value == null) return '';
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Truncates [value] to [max] characters for compact log lines.
  String _shortDebug(String? value, {int max = 180}) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty) return '-';
    if (raw.length <= max) return raw;
    return '${raw.substring(0, max)}...';
  }

  /// Extracts the `name` and `type` query parameters from an image URL
  /// that was previously composed by the clothing image service.
  ({String? name, String? type}) _queryFromImagePath(String? imagePath) {
    final raw = imagePath?.trim();
    if (raw == null || raw.isEmpty) {
      return (name: null, type: null);
    }
    final uri = Uri.tryParse(raw);
    if (uri == null) {
      return (name: null, type: null);
    }
    final name = uri.queryParameters['name']?.trim();
    final type = uri.queryParameters['type']?.trim();
    return (
      name: (name != null && name.isNotEmpty) ? name : null,
      type: (type != null && type.isNotEmpty) ? type : null,
    );
  }

  /// Checks whether the image URL's query params match what Gemini suggested.
  /// Returns `null` for wardrobe items (no AI query to compare against).
  bool? _isRequestQueryAlignedWithGemini(_OutfitPiece piece) {
    if (piece.wardrobeId != null && piece.wardrobeId!.isNotEmpty) {
      return null;
    }
    final geminiName = _normalizeDebugValue(piece.apiImageName ?? piece.name);
    final geminiType = _normalizeDebugValue(
      piece.apiImageType ?? piece.category,
    );
    if (geminiName.isEmpty && geminiType.isEmpty) {
      return null;
    }

    final query = _queryFromImagePath(piece.imagePath);
    final queryName = _normalizeDebugValue(query.name);
    final queryType = _normalizeDebugValue(query.type);

    if (queryName.isEmpty && queryType.isEmpty) {
      return null;
    }

    final nameMatch = geminiName.isEmpty || queryName == geminiName;
    final typeMatch = geminiType.isEmpty || queryType == geminiType;
    return nameMatch && typeMatch;
  }

  /// Checks whether the search query sent to the image API contains
  /// the name/type that Gemini originally specified.
  /// Returns `null` for wardrobe items or when data is unavailable.
  bool? _isApiSearchAlignedWithGemini(_OutfitPiece piece) {
    if (piece.wardrobeId != null && piece.wardrobeId!.isNotEmpty) {
      return null;
    }
    final geminiName = _normalizeDebugValue(piece.apiImageName ?? piece.name);
    final geminiType = _normalizeDebugValue(
      piece.apiImageType ?? piece.category,
    );
    if (geminiName.isEmpty && geminiType.isEmpty) {
      return null;
    }

    final apiSearch = _normalizeDebugValue(piece.apiSearchQuery);
    if (apiSearch.isEmpty) {
      return null;
    }

    final nameMatch = geminiName.isEmpty || apiSearch.contains(geminiName);
    final typeMatch = geminiType.isEmpty || apiSearch.contains(geminiType);
    return nameMatch && typeMatch;
  }

  /// Logs a summary of every item Gemini resolved (name, category, source, etc.).
  void _logGeminiSuggestedItems(OutfitSuggestion suggestion) {
    _terminalDebug(
      'Gemini resolved ${suggestion.items.length} outfit items.',
      tag: 'OutfitDebug',
    );
    for (var i = 0; i < suggestion.items.length; i++) {
      final item = suggestion.items[i];
      _terminalDebug(
        '[GeminiItem ${i + 1}] source=${item.source} name="${_shortDebug(item.name)}" '
        'category="${_shortDebug(item.category)}" wardrobeId="${_shortDebug(item.wardrobeId)}" '
        'image_name="${_shortDebug(item.imageName)}" image_type="${_shortDebug(item.imageType)}" '
        'image_index=${item.imageIndex ?? 0}',
        tag: 'OutfitDebug',
      );
    }
  }

  /// Logs per-item image alignment diagnostics at a named pipeline [stage]
  /// (e.g. `'mapped_before_images'`, `'primary'`, `'fallback'`).
  void _logGeminiImageAlignment({
    required String stage,
    required List<_OutfitPiece> items,
  }) {
    _terminalDebug(
      '[GeminiImageCheck][$stage] items=${items.length}',
      tag: 'OutfitDebug',
    );
    for (var i = 0; i < items.length; i++) {
      final piece = items[i];
      final query = _queryFromImagePath(piece.imagePath);
      final requestAligned = _isRequestQueryAlignedWithGemini(piece);
      final apiSearchAligned = _isApiSearchAlignedWithGemini(piece);
      final requestAlignmentText = requestAligned == null
          ? 'unknown'
          : requestAligned.toString();
      final apiSearchAlignmentText = apiSearchAligned == null
          ? 'unknown'
          : apiSearchAligned.toString();
      final source = piece.wardrobeId != null && piece.wardrobeId!.isNotEmpty
          ? 'wardrobe'
          : 'ai';
      final apiSourceHost = piece.apiSourceImageUrl == null
          ? null
          : Uri.tryParse(piece.apiSourceImageUrl!)?.host;
      _terminalDebug(
        '[GeminiImageCheck][$stage][${i + 1}] source=$source '
        'piece="${_shortDebug(piece.name)}" category="${_shortDebug(piece.category)}" '
        'gemini_query="${_shortDebug(piece.apiImageName)}" gemini_type="${_shortDebug(piece.apiImageType)}" '
        'request_query="${_shortDebug(query.name)}" request_type="${_shortDebug(query.type)}" '
        'api_search_query="${_shortDebug(piece.apiSearchQuery)}" '
        'api_search_engine="${_shortDebug(piece.apiSearchEngine)}" '
        'api_source_url="${_shortDebug(piece.apiSourceImageUrl, max: 220)}" '
        'api_source_host="${_shortDebug(apiSourceHost)}" api_result_index=${piece.apiResultIndex ?? -1} '
        'generic_fallback=${piece.usedGenericFallback} '
        'image_path="${_shortDebug(piece.imagePath, max: 220)}" has_bytes=${piece.imageBytes != null} '
        'request_match=$requestAlignmentText api_search_match=$apiSearchAlignmentText',
        tag: 'OutfitDebug',
      );
    }
  }

  // ── Route argument hydration ──────────────────────────────────

  /// Reads `selected_option`, `select_full_outfit`, and `selected_occasion`
  /// from the route arguments and applies them to the current selection state.
  /// No-ops when the values would not change anything.
  void _hydrateSelectionFromRouteArgs() {
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is! Map) return;

    final selectedOption = args['selected_option'];
    final selectFullOutfit = args['select_full_outfit'] == true;
    final selectedOccasion = args['selected_occasion'];

    var nextOption = _selectedOption;
    var nextOccasion = _selectedOccasion;

    if (selectFullOutfit) {
      nextOption = 1; // Force "Full Outfit Suggestion"
    } else if (selectedOption is int &&
        selectedOption >= 0 &&
        selectedOption < _options.length) {
      nextOption = selectedOption;
    }

    if (selectedOccasion is int &&
        selectedOccasion >= 0 &&
        selectedOccasion < _occasions.length) {
      nextOccasion = selectedOccasion;
    }

    if (nextOption == _selectedOption && nextOccasion == _selectedOccasion) {
      return;
    }

    setState(() {
      _selectedOption = nextOption;
      _selectedOccasion = nextOccasion;
    });
  }

  // ── Weather loading ───────────────────────────────────────────

  /// Requests the GPS position, reverse-geocodes it, and returns a
  /// [WeatherCoordinates] object with both coordinates and a resolved name.
  Future<WeatherCoordinates> _getDeviceCoordinates() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw Exception('Location services are disabled.');
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied) {
      throw Exception('Location permission denied.');
    }
    if (permission == LocationPermission.deniedForever) {
      throw Exception('Location permission permanently denied.');
    }

    final position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );
    final details = await _weatherService.reverseGeocodeLocation(
      latitude: position.latitude,
      longitude: position.longitude,
    );

    return WeatherCoordinates(
      latitude: position.latitude,
      longitude: position.longitude,
      resolvedName: details?.resolvedName,
      governorateName: details?.governorateName,
    );
  }

  /// Strips the word "governorate" and all non-alphanumeric characters from
  /// [raw] so that names can be compared case- and punctuation-insensitively.
  String _normalizeGovernorateKey(String raw) {
    return raw
        .toLowerCase()
        .replaceAll(RegExp(r'governorate', caseSensitive: false), '')
        .replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  /// Maps a raw geocoder governorate name (Arabic transliteration or English
  /// variant) to the canonical name used in [_governorates].
  /// Returns `null` when no match is found.
  String? _matchGovernorate(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final key = _normalizeGovernorateKey(raw);
    if (key.isEmpty) return null;

    // Well-known Arabic-transliteration aliases mapped to display names.
    const aliases = <String, String>{
      'alqahirah': 'Cairo',
      'cairo': 'Cairo',
      'aliskandariyah': 'Alexandria',
      'alexandria': 'Alexandria',
      'portsaid': 'Port Said',
      'ashsharqiyah': 'Sharkia',
      'sharkia': 'Sharkia',
      'asyut': 'Assiut',
      'asysut': 'Assiut',
      'assiut': 'Assiut',
      'aswan': 'Aswan',
      'giza': 'Giza',
      'suez': 'Suez',
      'damietta': 'Damietta',
      'luxor': 'Luxor',
      'sohag': 'Sohag',
      'qena': 'Qena',
      'matrouh': 'Matrouh',
      'menofia': 'Menofia',
      'minya': 'Minya',
      'dakahlia': 'Dakahlia',
      'beheira': 'Beheira',
      'fayoum': 'Fayoum',
      'gharbia': 'Gharbia',
      'ismailia': 'Ismailia',
      'qalyubia': 'Qalyubia',
      'newvalley': 'New Valley',
      'benisuef': 'Beni Suef',
      'southsinai': 'South Sinai',
      'northsinai': 'North Sinai',
      'redsea': 'Red Sea',
      'kafrelsheikh': 'Kafr El Sheikh',
    };

    final aliasMatch = aliases[key];
    if (aliasMatch != null) return aliasMatch;

    // Fall back to a substring match against the full governorate list.
    for (final governorate in _governorates) {
      final governorateKey = _normalizeGovernorateKey(governorate);
      if (governorateKey == key ||
          governorateKey.contains(key) ||
          key.contains(governorateKey)) {
        return governorate;
      }
    }
    return null;
  }

  /// Builds a human-readable location label from [cityName] and/or
  /// [governorateName], avoiding redundancy when they are the same.
  /// Falls back to [fallbackLabel], then `'Location unavailable'`.
  String _composeLocationLabel({
    String? cityName,
    String? governorateName,
    String? fallbackLabel,
  }) {
    final city = cityName?.trim();
    final governorate = governorateName?.trim();
    if (city != null &&
        city.isNotEmpty &&
        governorate != null &&
        governorate.isNotEmpty) {
      final cityKey = _normalizeGovernorateKey(city);
      final governorateKey = _normalizeGovernorateKey(governorate);
      // Show "City, Governorate" only when they are genuinely different.
      if (cityKey != governorateKey) {
        return '$city, $governorate';
      }
      return governorate;
    }
    if (governorate != null && governorate.isNotEmpty) return governorate;
    if (city != null && city.isNotEmpty) return city;
    if (fallbackLabel != null && fallbackLabel.trim().isNotEmpty) {
      return fallbackLabel.trim();
    }
    return 'Location unavailable';
  }

  /// Fetches current weather and updates all weather-related state.
  ///
  /// When [preferDevice] is `true`, GPS is tried first; on failure the
  /// selected governorate is geocoded instead. Coordinates are cached per
  /// governorate to reduce redundant API calls.
  Future<void> _loadWeather({bool preferDevice = true}) async {
    setState(() {
      _isWeatherLoading = true;
      _weatherError = null;
      if (preferDevice) {
        _usingDeviceLocation = true;
        _weatherLocationLabel = 'Detecting location...';
      } else {
        _weatherLocationLabel = _selectedGovernorate;
      }
    });

    String? locationError;

    try {
      WeatherCoordinates? coords;
      bool usedDevice = false;
      String? fallbackLabel;

      if (preferDevice) {
        try {
          coords = await _getDeviceCoordinates();
          usedDevice = true;
        } catch (e) {
          // GPS failed; surface the reason as a soft warning and fall through
          // to governorate-based geocoding below.
          locationError = e.toString().replaceFirst('Exception: ', '').trim();
        }
      }

      if (coords == null) {
        // Use cached coords when available; otherwise geocode the governorate.
        final cacheKey = _selectedGovernorate;
        final cached = _coordinatesCache[cacheKey];
        coords =
            cached ??
            await _weatherService.resolveCoordinates(
              '$_selectedGovernorate, Egypt',
            );
        _coordinatesCache[cacheKey] = coords;
        fallbackLabel = _selectedGovernorate;
      }

      final resolvedCoords = coords;
      final weather = await _weatherService.fetchCurrentWeather(
        latitude: resolvedCoords.latitude,
        longitude: resolvedCoords.longitude,
      );
      final matchedGovernorate = _matchGovernorate(
        resolvedCoords.governorateName ?? fallbackLabel,
      );
      final locationLabel = _composeLocationLabel(
        cityName: resolvedCoords.resolvedName,
        governorateName: matchedGovernorate ?? resolvedCoords.governorateName,
        fallbackLabel: fallbackLabel,
      );

      if (!mounted) return;
      setState(() {
        _temperatureC = weather.temperatureC;
        _weatherUpdatedAt = weather.observationTime ?? DateTime.now();
        _weatherSummary = _weatherSummaryFromCode(weather.weatherCode);
        _weatherLocationLabel = locationLabel;
        if (matchedGovernorate != null) {
          _selectedGovernorate = matchedGovernorate;
        }
        _usingDeviceLocation = usedDevice;
        _isWeatherLoading = false;
        // Keep any soft location error visible even on successful weather fetch.
        _weatherError = locationError;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isWeatherLoading = false;
        _weatherError = 'Unable to load current weather.';
        _usingDeviceLocation = false;
        _weatherLocationLabel = _selectedGovernorate;
      });
    }
  }

  // ── Weather helpers ───────────────────────────────────────────

  /// Classifies [tempC] into one of three weather bands.
  /// Thresholds: ≤ 18 °C → cold, ≥ 28 °C → hot, otherwise mild.
  _WeatherBand _weatherBandFor(double tempC) {
    if (tempC <= 18) return _WeatherBand.cold;
    if (tempC >= 28) return _WeatherBand.hot;
    return _WeatherBand.mild;
  }

  /// Returns the display label for a given temperature band.
  String _weatherBandLabel(double tempC) {
    switch (_weatherBandFor(tempC)) {
      case _WeatherBand.cold:
        return 'Cold';
      case _WeatherBand.hot:
        return 'Hot';
      case _WeatherBand.mild:
        return 'Mild';
    }
  }

  /// Returns a short dressing recommendation for the current temperature.
  String _weatherRecommendation(double tempC) {
    switch (_weatherBandFor(tempC)) {
      case _WeatherBand.hot:
        return 'Hot weather: choose light, breathable fabrics.';
      case _WeatherBand.cold:
        return 'Cold weather: go for heavier layers and jackets.';
      case _WeatherBand.mild:
        return 'Mild weather: light layers work best.';
    }
  }

  /// Maps an Open-Meteo WMO weather code to a human-readable condition string.
  String? _weatherSummaryFromCode(int? code) {
    if (code == null) return null;
    if (code == 0) return 'Clear';
    if (code >= 1 && code <= 3) return 'Partly cloudy';
    if (code == 45 || code == 48) return 'Fog';
    if (code >= 51 && code <= 57) return 'Drizzle';
    if (code >= 61 && code <= 67) return 'Rain';
    if (code >= 71 && code <= 77) return 'Snow';
    if (code >= 80 && code <= 82) return 'Rain showers';
    if (code >= 95) return 'Thunderstorm';
    return 'Weather';
  }

  // ── Image type inference ──────────────────────────────────────

  /// Infers the clothing image search type from [name] and [category].
  /// Falls back to `'clothes'` when no keyword matches.
  String _inferImageType({required String name, required String category}) {
    final text = '${name.toLowerCase()} ${category.toLowerCase()}';

    if (text.contains('watch')) return 'watch';
    if (text.contains('sunglass')) return 'sunglasses';
    if (text.contains('cap') || text.contains('hat')) return 'cap';
    if (text.contains('bag') ||
        text.contains('tote') ||
        text.contains('clutch')) {
      return 'bag';
    }
    if (text.contains('boot')) return 'boots';
    if (text.contains('sandal')) return 'sandals';
    if (text.contains('heel')) return 'heels';
    if (text.contains('flat')) return 'flats';
    if (text.contains('loafer')) return 'loafers';
    if (text.contains('sneaker') || text.contains('shoe')) return 'shoes';
    if (text.contains('short')) return 'shorts';
    if (text.contains('skirt')) return 'skirt';
    if (text.contains('legging')) return 'leggings';
    if (text.contains('pant') ||
        text.contains('trouser') ||
        text.contains('jean') ||
        text.contains('jogger') ||
        text.contains('chino') ||
        text.contains('bottom')) {
      return 'pants';
    }
    if (text.contains('jacket') ||
        text.contains('coat') ||
        text.contains('hoodie') ||
        text.contains('blazer')) {
      return 'jacket';
    }
    if (text.contains('dress')) return 'dress';
    if (text.contains('tee') ||
        text.contains('t-shirt') ||
        text.contains('shirt') ||
        text.contains('blouse') ||
        text.contains('top') ||
        text.contains('sweater') ||
        text.contains('cardigan')) {
      return 'top';
    }
    if (text.contains('acc') || text.contains('accessory')) return 'accessory';
    return 'clothes';
  }

  // ── Occasion helpers ──────────────────────────────────────────

  /// Normalises an occasion label to one of `'casual'`, `'business'`,
  /// `'formal'`, or `'sport'`.
  String _occasionKey(String occasion) {
    final v = occasion.toLowerCase().trim();
    if (v.contains('business')) return 'business';
    if (v.contains('formal')) return 'formal';
    if (v.contains('sport')) return 'sport';
    return 'casual';
  }

  // ── Outfit seed tables ────────────────────────────────────────
  // Each method returns a list of [_ApiSuggestionSeed]s used as a fallback
  // when Gemini is unavailable or its response is incomplete.
  // Seeds are split by audience, occasion, and weather band.

  /// Returns audience-qualified seeds for the currently selected audience,
  /// applying [_audienceQualifiedSearchName] to every search name.
  List<_ApiSuggestionSeed> _fullSuggestionSeedsForContext({
    required _WeatherBand band,
    required String occasion,
  }) {
    final seeds = _selectedAudience == 1
        ? _womenFullSuggestionSeedsForContext(band: band, occasion: occasion)
        : _baseFullSuggestionSeedsForContext(band: band, occasion: occasion);

    return seeds
        .map(
          (seed) => seed.copyWith(
            searchName: _audienceQualifiedSearchName(seed.searchName),
          ),
        )
        .toList();
  }

  /// Women-specific outfit seeds, organised by occasion then weather band.
  List<_ApiSuggestionSeed> _womenFullSuggestionSeedsForContext({
    required _WeatherBand band,
    required String occasion,
  }) {
    final occ = _occasionKey(occasion);

    if (occ == 'formal') {
      switch (band) {
        case _WeatherBand.hot:
          return const [
            _ApiSuggestionSeed(
              searchName: 'champagne satin midi dress',
              type: 'dress',
              name: 'Midi Dress',
              category: 'Dress',
              emoji: '\u{1F457}',
            ),
            _ApiSuggestionSeed(
              searchName: 'nude strappy block heels',
              type: 'heels',
              name: 'Block Heels',
              category: 'Shoes',
              emoji: '\u{1F460}',
            ),
            _ApiSuggestionSeed(
              searchName: 'cream formal blazer',
              type: 'blazer',
              name: 'Formal Blazer',
              category: 'Jacket',
              emoji: '\u{1F9E5}',
            ),
            _ApiSuggestionSeed(
              searchName: 'champagne clutch bag',
              type: 'bag',
              name: 'Clutch Bag',
              category: 'Accessory',
              emoji: '\u{1F45C}',
            ),
          ];
        case _WeatherBand.cold:
          return const [
            _ApiSuggestionSeed(
              searchName: 'black knit turtleneck dress',
              type: 'dress',
              name: 'Knit Dress',
              category: 'Dress',
              emoji: '\u{1F457}',
            ),
            _ApiSuggestionSeed(
              searchName: 'black leather ankle boots',
              type: 'boots',
              name: 'Ankle Boots',
              category: 'Shoes',
              emoji: '\u{1F97E}',
            ),
            _ApiSuggestionSeed(
              searchName: 'camel tailored wool coat',
              type: 'coat',
              name: 'Wool Coat',
              category: 'Jacket',
              emoji: '\u{1F9E5}',
            ),
            _ApiSuggestionSeed(
              searchName: 'black structured handbag',
              type: 'bag',
              name: 'Handbag',
              category: 'Accessory',
              emoji: '\u{1F45C}',
            ),
          ];
        case _WeatherBand.mild:
          return const [
            _ApiSuggestionSeed(
              searchName: 'ivory silk blouse',
              type: 'blouse',
              name: 'Silk Blouse',
              category: 'Top',
              emoji: '\u{1F45A}',
            ),
            _ApiSuggestionSeed(
              searchName: 'black tailored midi skirt',
              type: 'skirt',
              name: 'Midi Skirt',
              category: 'Bottom',
              emoji: '\u{1F45A}',
            ),
            _ApiSuggestionSeed(
              searchName: 'black pointed toe heels',
              type: 'heels',
              name: 'Pointed Heels',
              category: 'Shoes',
              emoji: '\u{1F460}',
            ),
            _ApiSuggestionSeed(
              searchName: 'black classic blazer',
              type: 'blazer',
              name: 'Classic Blazer',
              category: 'Jacket',
              emoji: '\u{1F9E5}',
            ),
          ];
      }
    }

    if (occ == 'business') {
      switch (band) {
        case _WeatherBand.hot:
          return const [
            _ApiSuggestionSeed(
              searchName: 'white linen blouse',
              type: 'blouse',
              name: 'Linen Blouse',
              category: 'Top',
              emoji: '\u{1F45A}',
            ),
            _ApiSuggestionSeed(
              searchName: 'beige tailored wide leg trousers',
              type: 'trousers',
              name: 'Wide Leg Trousers',
              category: 'Bottom',
              emoji: '\u{1F456}',
            ),
            _ApiSuggestionSeed(
              searchName: 'tan pointed flats',
              type: 'flats',
              name: 'Pointed Flats',
              category: 'Shoes',
              emoji: '\u{1F97F}',
            ),
            _ApiSuggestionSeed(
              searchName: 'tan minimal leather tote',
              type: 'bag',
              name: 'Leather Tote',
              category: 'Accessory',
              emoji: '\u{1F45C}',
            ),
          ];
        case _WeatherBand.cold:
          return const [
            _ApiSuggestionSeed(
              searchName: 'cream ribbed turtleneck sweater',
              type: 'sweater',
              name: 'Turtleneck Sweater',
              category: 'Top',
              emoji: '\u{1F9E5}',
            ),
            _ApiSuggestionSeed(
              searchName: 'charcoal wool tailored trousers',
              type: 'trousers',
              name: 'Wool Trousers',
              category: 'Bottom',
              emoji: '\u{1F456}',
            ),
            _ApiSuggestionSeed(
              searchName: 'black leather ankle boots',
              type: 'boots',
              name: 'Ankle Boots',
              category: 'Shoes',
              emoji: '\u{1F97E}',
            ),
            _ApiSuggestionSeed(
              searchName: 'camel belted wool coat',
              type: 'coat',
              name: 'Belted Coat',
              category: 'Jacket',
              emoji: '\u{1F9E5}',
            ),
          ];
        case _WeatherBand.mild:
          return const [
            _ApiSuggestionSeed(
              searchName: 'white cotton button blouse',
              type: 'blouse',
              name: 'Button Blouse',
              category: 'Top',
              emoji: '\u{1F45A}',
            ),
            _ApiSuggestionSeed(
              searchName: 'navy straight leg trousers',
              type: 'trousers',
              name: 'Straight Trousers',
              category: 'Bottom',
              emoji: '\u{1F456}',
            ),
            _ApiSuggestionSeed(
              searchName: 'black leather loafers',
              type: 'loafers',
              name: 'Leather Loafers',
              category: 'Shoes',
              emoji: '\u{1F45E}',
            ),
            _ApiSuggestionSeed(
              searchName: 'navy soft blazer',
              type: 'blazer',
              name: 'Soft Blazer',
              category: 'Jacket',
              emoji: '\u{1F9E5}',
            ),
          ];
      }
    }

    if (occ == 'sport') {
      switch (band) {
        case _WeatherBand.hot:
          return const [
            _ApiSuggestionSeed(
              searchName: 'white training tank top',
              type: 'top',
              name: 'Training Tank',
              category: 'Top',
              emoji: '\u{1F45A}',
            ),
            _ApiSuggestionSeed(
              searchName: 'black biker shorts',
              type: 'shorts',
              name: 'Biker Shorts',
              category: 'Bottom',
              emoji: '\u{1FA73}',
            ),
            _ApiSuggestionSeed(
              searchName: 'white training sneakers',
              type: 'sneakers',
              name: 'Training Sneakers',
              category: 'Shoes',
              emoji: '\u{1F45F}',
            ),
            _ApiSuggestionSeed(
              searchName: 'black sports cap',
              type: 'cap',
              name: 'Sports Cap',
              category: 'Accessory',
              emoji: '\u{1F9E2}',
            ),
          ];
        case _WeatherBand.cold:
          return const [
            _ApiSuggestionSeed(
              searchName: 'black thermal training top',
              type: 'top',
              name: 'Thermal Top',
              category: 'Top',
              emoji: '\u{1F9E5}',
            ),
            _ApiSuggestionSeed(
              searchName: 'black high waist leggings',
              type: 'leggings',
              name: 'Leggings',
              category: 'Bottom',
              emoji: '\u{1F456}',
            ),
            _ApiSuggestionSeed(
              searchName: 'white running sneakers',
              type: 'sneakers',
              name: 'Running Sneakers',
              category: 'Shoes',
              emoji: '\u{1F45F}',
            ),
            _ApiSuggestionSeed(
              searchName: 'black training jacket',
              type: 'jacket',
              name: 'Training Jacket',
              category: 'Jacket',
              emoji: '\u{1F9E5}',
            ),
          ];
        case _WeatherBand.mild:
          return const [
            _ApiSuggestionSeed(
              searchName: 'white athletic crop top',
              type: 'top',
              name: 'Athletic Top',
              category: 'Top',
              emoji: '\u{1F45A}',
            ),
            _ApiSuggestionSeed(
              searchName: 'black track leggings',
              type: 'leggings',
              name: 'Track Leggings',
              category: 'Bottom',
              emoji: '\u{1F456}',
            ),
            _ApiSuggestionSeed(
              searchName: 'white gym sneakers',
              type: 'sneakers',
              name: 'Gym Sneakers',
              category: 'Shoes',
              emoji: '\u{1F45F}',
            ),
            _ApiSuggestionSeed(
              searchName: 'black lightweight sports jacket',
              type: 'jacket',
              name: 'Sports Jacket',
              category: 'Jacket',
              emoji: '\u{1F9E5}',
            ),
          ];
      }
    }

    // Default women casual seeds by weather band.
    switch (band) {
      case _WeatherBand.hot:
        return const [
          _ApiSuggestionSeed(
            searchName: 'ivory linen sleeveless blouse',
            type: 'blouse',
            name: 'Linen Blouse',
            category: 'Top',
            emoji: '\u{1F45A}',
          ),
          _ApiSuggestionSeed(
            searchName: 'beige high waisted summer shorts',
            type: 'shorts',
            name: 'Summer Shorts',
            category: 'Bottom',
            emoji: '\u{1FA73}',
          ),
          _ApiSuggestionSeed(
            searchName: 'tan flat summer sandals',
            type: 'sandals',
            name: 'Flat Sandals',
            category: 'Shoes',
            emoji: '\u{1F461}',
          ),
          _ApiSuggestionSeed(
            searchName: 'tortoise sunglasses',
            type: 'sunglasses',
            name: 'Sunglasses',
            category: 'Accessory',
            emoji: '\u{1F576}',
          ),
        ];
      case _WeatherBand.cold:
        return const [
          _ApiSuggestionSeed(
            searchName: 'cream knit turtleneck sweater',
            type: 'sweater',
            name: 'Knit Sweater',
            category: 'Top',
            emoji: '\u{1F9E5}',
          ),
          _ApiSuggestionSeed(
            searchName: 'dark straight leg jeans',
            type: 'jeans',
            name: 'Straight Jeans',
            category: 'Bottom',
            emoji: '\u{1F456}',
          ),
          _ApiSuggestionSeed(
            searchName: 'black leather ankle boots',
            type: 'boots',
            name: 'Ankle Boots',
            category: 'Shoes',
            emoji: '\u{1F97E}',
          ),
          _ApiSuggestionSeed(
            searchName: 'camel wool wrap coat',
            type: 'coat',
            name: 'Wrap Coat',
            category: 'Jacket',
            emoji: '\u{1F9E5}',
          ),
        ];
      case _WeatherBand.mild:
        return const [
          _ApiSuggestionSeed(
            searchName: 'white cotton button blouse',
            type: 'blouse',
            name: 'Button Blouse',
            category: 'Top',
            emoji: '\u{1F45A}',
          ),
          _ApiSuggestionSeed(
            searchName: 'sand wide leg trousers',
            type: 'trousers',
            name: 'Wide Leg Trousers',
            category: 'Bottom',
            emoji: '\u{1F456}',
          ),
          _ApiSuggestionSeed(
            searchName: 'white fashion sneakers',
            type: 'sneakers',
            name: 'Fashion Sneakers',
            category: 'Shoes',
            emoji: '\u{1F45F}',
          ),
          _ApiSuggestionSeed(
            searchName: 'oatmeal cardigan sweater',
            type: 'cardigan',
            name: 'Cardigan',
            category: 'Jacket',
            emoji: '\u{1F9E5}',
          ),
        ];
    }
  }

  /// Men-specific outfit seeds, organised by occasion then weather band.
  List<_ApiSuggestionSeed> _baseFullSuggestionSeedsForContext({
    required _WeatherBand band,
    required String occasion,
  }) {
    final occ = _occasionKey(occasion);

    if (occ == 'formal') {
      switch (band) {
        case _WeatherBand.hot:
          return const [
            _ApiSuggestionSeed(
              searchName: 'white linen dress shirt',
              type: 'shirt',
              name: 'Linen Dress Shirt',
              category: 'Top',
              emoji: '\u{1F454}',
            ),
            _ApiSuggestionSeed(
              searchName: 'navy linen trousers',
              type: 'pants',
              name: 'Navy Trousers',
              category: 'Bottom',
              emoji: '\u{1F456}',
            ),
            _ApiSuggestionSeed(
              searchName: 'brown oxford leather shoes',
              type: 'shoes',
              name: 'Brown Oxfords',
              category: 'Shoes',
              emoji: '\u{1F45E}',
            ),
            _ApiSuggestionSeed(
              searchName: 'navy formal blazer',
              type: 'blazer',
              name: 'Navy Blazer',
              category: 'Jacket',
              emoji: '\u{1F9E5}',
            ),
          ];
        case _WeatherBand.cold:
          return const [
            _ApiSuggestionSeed(
              searchName: 'black formal turtleneck',
              type: 'top',
              name: 'Turtleneck',
              category: 'Top',
              emoji: '\u{1F9E5}',
            ),
            _ApiSuggestionSeed(
              searchName: 'charcoal wool trousers',
              type: 'pants',
              name: 'Wool Trousers',
              category: 'Bottom',
              emoji: '\u{1F456}',
            ),
            _ApiSuggestionSeed(
              searchName: 'black leather chelsea boots',
              type: 'boots',
              name: 'Formal Boots',
              category: 'Shoes',
              emoji: '\u{1F97E}',
            ),
            _ApiSuggestionSeed(
              searchName: 'charcoal long wool coat',
              type: 'coat',
              name: 'Long Coat',
              category: 'Jacket',
              emoji: '\u{1F9E5}',
            ),
          ];
        case _WeatherBand.mild:
          return const [
            _ApiSuggestionSeed(
              searchName: 'white formal dress shirt',
              type: 'shirt',
              name: 'White Shirt',
              category: 'Top',
              emoji: '\u{1F454}',
            ),
            _ApiSuggestionSeed(
              searchName: 'charcoal tailored pants',
              type: 'pants',
              name: 'Tailored Pants',
              category: 'Bottom',
              emoji: '\u{1F456}',
            ),
            _ApiSuggestionSeed(
              searchName: 'black derby shoes',
              type: 'shoes',
              name: 'Derby Shoes',
              category: 'Shoes',
              emoji: '\u{1F45E}',
            ),
            _ApiSuggestionSeed(
              searchName: 'navy formal blazer',
              type: 'blazer',
              name: 'Navy Blazer',
              category: 'Jacket',
              emoji: '\u{1F9E5}',
            ),
          ];
      }
    }

    if (occ == 'business') {
      switch (band) {
        case _WeatherBand.hot:
          return const [
            _ApiSuggestionSeed(
              searchName: 'white linen shirt',
              type: 'shirt',
              name: 'Linen Shirt',
              category: 'Top',
              emoji: '\u{1F454}',
            ),
            _ApiSuggestionSeed(
              searchName: 'beige tailored trousers',
              type: 'pants',
              name: 'Tailored Trousers',
              category: 'Bottom',
              emoji: '\u{1F456}',
            ),
            _ApiSuggestionSeed(
              searchName: 'brown suede loafers',
              type: 'loafers',
              name: 'Loafers',
              category: 'Shoes',
              emoji: '\u{1F45E}',
            ),
            _ApiSuggestionSeed(
              searchName: 'brown leather watch',
              type: 'watch',
              name: 'Watch',
              category: 'Accessory',
              emoji: '\u{231A}',
            ),
          ];
        case _WeatherBand.cold:
          return const [
            _ApiSuggestionSeed(
              searchName: 'cream turtleneck sweater',
              type: 'sweater',
              name: 'Turtleneck',
              category: 'Top',
              emoji: '\u{1F9E5}',
            ),
            _ApiSuggestionSeed(
              searchName: 'charcoal wool trousers',
              type: 'pants',
              name: 'Wool Trousers',
              category: 'Bottom',
              emoji: '\u{1F456}',
            ),
            _ApiSuggestionSeed(
              searchName: 'black leather chelsea boots',
              type: 'boots',
              name: 'Leather Boots',
              category: 'Shoes',
              emoji: '\u{1F97E}',
            ),
            _ApiSuggestionSeed(
              searchName: 'charcoal long wool coat',
              type: 'coat',
              name: 'Wool Coat',
              category: 'Jacket',
              emoji: '\u{1F9E5}',
            ),
          ];
        case _WeatherBand.mild:
          return const [
            _ApiSuggestionSeed(
              searchName: 'light blue oxford shirt',
              type: 'shirt',
              name: 'Oxford Shirt',
              category: 'Top',
              emoji: '\u{1F454}',
            ),
            _ApiSuggestionSeed(
              searchName: 'navy slim fit chinos',
              type: 'pants',
              name: 'Chinos',
              category: 'Bottom',
              emoji: '\u{1F456}',
            ),
            _ApiSuggestionSeed(
              searchName: 'brown derby shoes',
              type: 'shoes',
              name: 'Derby Shoes',
              category: 'Shoes',
              emoji: '\u{1F45E}',
            ),
            _ApiSuggestionSeed(
              searchName: 'brown leather watch',
              type: 'watch',
              name: 'Classic Watch',
              category: 'Accessory',
              emoji: '\u{231A}',
            ),
          ];
      }
    }

    if (occ == 'sport') {
      switch (band) {
        case _WeatherBand.hot:
          return const [
            _ApiSuggestionSeed(
              searchName: 'white dry fit t shirt',
              type: 'tshirt',
              name: 'Dry-Fit Tee',
              category: 'Top',
              emoji: '\u{1F455}',
            ),
            _ApiSuggestionSeed(
              searchName: 'black running shorts',
              type: 'shorts',
              name: 'Running Shorts',
              category: 'Bottom',
              emoji: '\u{1FA73}',
            ),
            _ApiSuggestionSeed(
              searchName: 'white training sneakers',
              type: 'sneakers',
              name: 'Training Sneakers',
              category: 'Shoes',
              emoji: '\u{1F45F}',
            ),
            _ApiSuggestionSeed(
              searchName: 'black sports cap',
              type: 'cap',
              name: 'Sports Cap',
              category: 'Accessory',
              emoji: '\u{1F9E2}',
            ),
          ];
        case _WeatherBand.cold:
          return const [
            _ApiSuggestionSeed(
              searchName: 'black thermal training top',
              type: 'top',
              name: 'Thermal Top',
              category: 'Top',
              emoji: '\u{1F9E5}',
            ),
            _ApiSuggestionSeed(
              searchName: 'black running joggers',
              type: 'pants',
              name: 'Joggers',
              category: 'Bottom',
              emoji: '\u{1F456}',
            ),
            _ApiSuggestionSeed(
              searchName: 'white running shoes',
              type: 'shoes',
              name: 'Running Shoes',
              category: 'Shoes',
              emoji: '\u{1F45F}',
            ),
            _ApiSuggestionSeed(
              searchName: 'black training jacket',
              type: 'jacket',
              name: 'Training Jacket',
              category: 'Jacket',
              emoji: '\u{1F9E5}',
            ),
          ];
        case _WeatherBand.mild:
          return const [
            _ApiSuggestionSeed(
              searchName: 'white athletic t shirt',
              type: 'tshirt',
              name: 'Athletic Tee',
              category: 'Top',
              emoji: '\u{1F455}',
            ),
            _ApiSuggestionSeed(
              searchName: 'black track joggers',
              type: 'pants',
              name: 'Track Joggers',
              category: 'Bottom',
              emoji: '\u{1F456}',
            ),
            _ApiSuggestionSeed(
              searchName: 'white gym sneakers',
              type: 'sneakers',
              name: 'Gym Sneakers',
              category: 'Shoes',
              emoji: '\u{1F45F}',
            ),
            _ApiSuggestionSeed(
              searchName: 'black sports cap',
              type: 'cap',
              name: 'Sports Cap',
              category: 'Accessory',
              emoji: '\u{1F9E2}',
            ),
          ];
      }
    }

    // Default men casual seeds by weather band.
    switch (band) {
      case _WeatherBand.hot:
        return const [
          _ApiSuggestionSeed(
            searchName: 'white cotton t-shirt',
            type: 'tshirt',
            name: 'T-shirt',
            category: 'Top',
            emoji: '\u{1F455}',
          ),
          _ApiSuggestionSeed(
            searchName: 'beige chino shorts',
            type: 'shorts',
            name: 'Shorts',
            category: 'Bottom',
            emoji: '\u{1FA73}',
          ),
          _ApiSuggestionSeed(
            searchName: 'white low top sneakers',
            type: 'sneakers',
            name: 'Sneakers',
            category: 'Shoes',
            emoji: '\u{1F45F}',
          ),
          _ApiSuggestionSeed(
            searchName: 'tortoise sunglasses',
            type: 'sunglasses',
            name: 'Sunglasses',
            category: 'Accessory',
            emoji: '\u{1F576}',
          ),
        ];
      case _WeatherBand.cold:
        return const [
          _ApiSuggestionSeed(
            searchName: 'charcoal warm hoodie',
            type: 'hoodie',
            name: 'Warm Hoodie',
            category: 'Top',
            emoji: '\u{1F9E5}',
          ),
          _ApiSuggestionSeed(
            searchName: 'dark denim jeans',
            type: 'jeans',
            name: 'Dark Jeans',
            category: 'Bottom',
            emoji: '\u{1F456}',
          ),
          _ApiSuggestionSeed(
            searchName: 'brown leather boots',
            type: 'boots',
            name: 'Leather Boots',
            category: 'Shoes',
            emoji: '\u{1F97E}',
          ),
          _ApiSuggestionSeed(
            searchName: 'black puffer jacket',
            type: 'jacket',
            name: 'Puffer Jacket',
            category: 'Jacket',
            emoji: '\u{1F9E5}',
          ),
        ];
      case _WeatherBand.mild:
        return const [
          _ApiSuggestionSeed(
            searchName: 'white cotton tee',
            type: 'tshirt',
            name: 'Cotton Tee',
            category: 'Top',
            emoji: '\u{1F455}',
          ),
          _ApiSuggestionSeed(
            searchName: 'dark slim jeans',
            type: 'jeans',
            name: 'Slim Jeans',
            category: 'Bottom',
            emoji: '\u{1F456}',
          ),
          _ApiSuggestionSeed(
            searchName: 'white clean sneakers',
            type: 'sneakers',
            name: 'Clean Sneakers',
            category: 'Shoes',
            emoji: '\u{1F45F}',
          ),
          _ApiSuggestionSeed(
            searchName: 'navy baseball cap',
            type: 'cap',
            name: 'Cap',
            category: 'Accessory',
            emoji: '\u{1F9E2}',
          ),
        ];
    }
  }

  // ── Image fetching ─────────────────────────────────────────────

  /// Fetches clothing images for the current weather band + occasion seeds.
  /// Used as a pre-flight check when Gemini's outfit lacks enough visuals.
  Future<_PreviewLoadResult> _buildFullSuggestionPreviewItems({
    required String occasion,
    void Function(String status)? onProgress,
    bool preferFastFallback = false,
  }) async {
    final seeds = _fullSuggestionSeedsForContext(
      band: _weatherBandFor(_temperatureC),
      occasion: occasion,
    );
    String? firstApiError;
    var started = 0;
    final pieces = await Future.wait(
      seeds.map((seed) async {
        final requestNumber = ++started;
        onProgress?.call(
          'Checking fallback image $requestNumber/${seeds.length}...',
        );
        final stopwatch = Stopwatch()..start();
        final result = await _clothingImageService.fetchClothingImage(
          name: seed.searchName,
          type: seed.type,
          audience: _audienceSearchValue,
          index: 0,
          allowGenericFallback: false,
          skipMetadataSearch: false,
          minConfidenceScore: 8,
        );
        developer.log(
          'Fallback preview image for ${seed.name} finished in ${stopwatch.elapsedMilliseconds}ms '
          '(success=${result.isSuccess}, error=${result.error ?? "none"})',
          name: 'OutfitScreen',
        );
        firstApiError ??= result.error;
        return _OutfitPiece(
          emoji: seed.emoji,
          name: seed.name,
          category: seed.category,
          imageBytes: result.bytes,
          imagePath: result.isSuccess ? result.requestUri?.toString() : null,
          apiImageName: seed.searchName,
          apiImageType: seed.type,
          apiImageIndex: 0,
          apiSourceImageUrl: result.sourceImageUrl,
          apiSearchQuery: result.apiSearchQuery,
          apiSearchEngine: result.apiSearchEngine,
          apiResultIndex: result.apiResultIndex,
          usedGenericFallback: result.isGenericFallback,
        );
      }),
    );
    return _PreviewLoadResult(items: pieces, firstApiError: firstApiError);
  }

  /// Returns `true` when [piece] has either raw bytes or a non-empty image URL.
  bool _hasVisualImage(_OutfitPiece piece) {
    final hasBytes = piece.imageBytes != null && piece.imageBytes!.isNotEmpty;
    final hasPath =
        piece.imagePath != null && piece.imagePath!.trim().isNotEmpty;
    return hasBytes || hasPath;
  }

  /// Returns `true` when [piece] represents a dress or gown (single-piece outfit).
  bool _isDressPiece(_OutfitPiece piece) {
    final text = '${piece.name} ${piece.category} ${piece.apiImageType ?? ''}'
        .toLowerCase();
    return text.contains('dress') || text.contains('gown');
  }

  /// Verifies that [items] form a structurally complete outfit.
  ///
  /// For dresses: requires shoes + at least one layer/accessory.
  /// For separates: requires top + bottom + shoes + at least one layer/accessory.
  bool _hasCompleteOutfitStructure(List<_OutfitPiece> items) {
    final hasDress = items.any(_isDressPiece);
    final hasShoes = items.any((piece) {
      return _bucketForCategory(piece.category) == _WardrobeBucket.shoes;
    });
    final hasLayerOrAccessory = items.any((piece) {
      final bucket = _bucketForCategory(piece.category);
      return bucket == _WardrobeBucket.jacket ||
          bucket == _WardrobeBucket.accessory;
    });

    if (hasDress) {
      return hasShoes && hasLayerOrAccessory;
    }

    final hasTop = items.any((piece) {
      return _bucketForCategory(piece.category) == _WardrobeBucket.top;
    });
    final hasBottom = items.any((piece) {
      return _bucketForCategory(piece.category) == _WardrobeBucket.bottom;
    });
    return hasTop && hasBottom && hasShoes && hasLayerOrAccessory;
  }

  /// Returns a prioritised list of image type strings to try for [baseType]
  /// and [category], broadening the search when the primary type fails.
  List<String> _imageTypeCandidates({
    required String baseType,
    required String category,
  }) {
    final out = <String>[baseType];
    final c = category.toLowerCase();
    if (c.contains('shoe') ||
        c.contains('sneaker') ||
        c.contains('boot') ||
        c.contains('heel') ||
        c.contains('flat') ||
        c.contains('sandal')) {
      out.addAll(['shoes', 'sneakers', 'boots', 'heels', 'flats', 'sandals']);
    } else if (c.contains('pant') ||
        c.contains('bottom') ||
        c.contains('jean') ||
        c.contains('short') ||
        c.contains('skirt') ||
        c.contains('legging')) {
      out.addAll(['pants', 'jeans', 'shorts', 'skirt', 'leggings', 'bottom']);
    } else if (c.contains('top') ||
        c.contains('shirt') ||
        c.contains('tee') ||
        c.contains('blouse')) {
      out.addAll(['top', 'shirt', 'tshirt']);
    } else if (c.contains('jacket') ||
        c.contains('coat') ||
        c.contains('outer')) {
      out.addAll(['jacket', 'coat']);
    } else if (c.contains('access') ||
        c.contains('bag') ||
        c.contains('tote') ||
        c.contains('clutch')) {
      out.addAll(['accessory', 'watch', 'bag']);
    }
    out.add('clothes'); // ultimate fallback
    return out.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet().toList();
  }

  /// Fetches clothing images for every [items] entry that currently has neither
  /// bytes nor a URL. Tries the primary query first, then a grid of broader
  /// query/type combinations with decreasing confidence thresholds (8 → 6).
  ///
  /// [onProgress] receives status strings suitable for the generation label.
  /// When [preferFastFallback] is `true`, the method accepts any successful
  /// result from the first attempt without trying broader queries.
  Future<List<_OutfitPiece>> _enrichAiItemsWithImages(
    List<_OutfitPiece> items, {
    void Function(String status)? onProgress,
    bool preferFastFallback = false,
  }) async {
    final pendingItems = items
        .where((piece) => piece.imagePath == null && piece.imageBytes == null)
        .toList();
    var started = 0;
    var completed = 0;

    return Future.wait(
      items.map((piece) async {
        // Skip pieces that already have an image.
        if (piece.imagePath != null || piece.imageBytes != null) {
          return piece;
        }
        final total = pendingItems.length;
        final current = ++started;
        onProgress?.call('Loading image $current/$total...');
        final apiName =
            (piece.apiImageName != null &&
                piece.apiImageName!.trim().isNotEmpty)
            ? piece.apiImageName!.trim()
            : piece.name;
        final apiType =
            (piece.apiImageType != null &&
                piece.apiImageType!.trim().isNotEmpty)
            ? piece.apiImageType!.trim()
            : _inferImageType(name: piece.name, category: piece.category);
        final stopwatch = Stopwatch()..start();
        developer.log(
          'Image enrichment started for ${piece.name} (${piece.category}) '
          'with name="$apiName" type="$apiType"',
          name: 'OutfitScreen',
        );

        // First attempt: use the exact name and type from Gemini.
        final directResult = await _clothingImageService.fetchClothingImage(
          name: apiName,
          type: apiType,
          audience: _audienceSearchValue,
          index: piece.apiImageIndex,
          allowGenericFallback: false,
          skipMetadataSearch: false,
          minConfidenceScore: 8,
        );
        if (directResult.bytes != null && directResult.bytes!.isNotEmpty) {
          completed++;
          onProgress?.call('Loaded images $completed/$total');
          developer.log(
            'Image enrichment succeeded for ${piece.name} in ${stopwatch.elapsedMilliseconds}ms',
            name: 'OutfitScreen',
          );
          return piece.copyWith(
            imageBytes: directResult.bytes,
            imagePath: directResult.requestUri?.toString(),
            apiImageName: apiName,
            apiImageType: apiType,
            apiImageIndex: piece.apiImageIndex,
            apiSourceImageUrl: directResult.sourceImageUrl,
            apiSearchQuery: directResult.apiSearchQuery,
            apiSearchEngine: directResult.apiSearchEngine,
            apiResultIndex: directResult.apiResultIndex,
            usedGenericFallback: directResult.isGenericFallback,
          );
        }

        // Fast-fallback path: accept any URL result, skip broader search.
        if (preferFastFallback && directResult.isSuccess) {
          completed++;
          onProgress?.call('Loaded images $completed/$total');
          developer.log(
            'Fast fallback mode finished for ${piece.name} in ${stopwatch.elapsedMilliseconds}ms '
            '(success=${directResult.isSuccess}, error=${directResult.error ?? "none"})',
            name: 'OutfitScreen',
          );
          return piece.copyWith(
            imageBytes: directResult.bytes,
            imagePath: directResult.isSuccess
                ? directResult.requestUri?.toString()
                : piece.imagePath,
            apiImageName: apiName,
            apiImageType: apiType,
            apiImageIndex: piece.apiImageIndex,
            apiSourceImageUrl: directResult.sourceImageUrl,
            apiSearchQuery: directResult.apiSearchQuery,
            apiSearchEngine: directResult.apiSearchEngine,
            apiResultIndex: directResult.apiResultIndex,
            usedGenericFallback: directResult.isGenericFallback,
          );
        }

        // Broader search: try multiple query/type pairs at decreasing scores.
        final queryCandidates = <String>[
          apiName,
          '${piece.name} ${piece.category}',
          piece.name,
          '${piece.category} clothing',
        ].map((e) => e.trim()).where((e) => e.isNotEmpty).toSet().toList();
        final typeCandidates = _imageTypeCandidates(
          baseType: apiType,
          category: piece.category,
        );

        ClothingImageFetchResult? pickedResult;
        String? pickedQueryName;
        String? pickedQueryType;
        for (final minScore in const [8, 6]) {
          for (final query in queryCandidates) {
            for (final t in typeCandidates) {
              final candidate = await _clothingImageService.fetchClothingImage(
                name: query,
                type: t,
                audience: _audienceSearchValue,
                index: piece.apiImageIndex,
                allowGenericFallback: false,
                minConfidenceScore: minScore,
              );
              if (candidate.bytes != null && candidate.bytes!.isNotEmpty) {
                pickedResult = candidate;
                pickedQueryName = query;
                pickedQueryType = t;
                break;
              }
            }
            if (pickedResult != null) break;
          }
          if (pickedResult != null) break;
        }

        completed++;
        onProgress?.call('Loaded images $completed/$total');
        developer.log(
          'Image enrichment finished for ${piece.name} in ${stopwatch.elapsedMilliseconds}ms '
          '(success=${pickedResult?.isSuccess == true}, error=${pickedResult?.error ?? directResult.error ?? "none"})',
          name: 'OutfitScreen',
        );

        return piece.copyWith(
          imageBytes: pickedResult?.bytes,
          imagePath: pickedResult?.isSuccess == true
              ? pickedResult?.requestUri?.toString()
              : piece.imagePath,
          apiImageName: pickedQueryName ?? apiName,
          apiImageType: pickedQueryType ?? apiType,
          apiImageIndex: piece.apiImageIndex,
          apiSourceImageUrl: pickedResult?.sourceImageUrl,
          apiSearchQuery: pickedResult?.apiSearchQuery,
          apiSearchEngine: pickedResult?.apiSearchEngine,
          apiResultIndex: pickedResult?.apiResultIndex,
          usedGenericFallback:
              pickedResult?.isGenericFallback ?? piece.usedGenericFallback,
        );
      }),
    );
  }

  /// Ensures the final "Full Outfit Suggestion" has at least 4 items with
  /// real visuals. When [items] already contains ≥ 4 visual pieces, the
  /// first 4 are returned immediately. Otherwise, the method fills the gap
  /// from the weather-based seed previews, then from the original items
  /// (without images) as a last resort.
  Future<List<_OutfitPiece>> _ensureFullOutfitHasRealImages(
    List<_OutfitPiece> items, {
    required String occasion,
    void Function(String status)? onProgress,
    bool preferFastFallback = false,
  }) async {
    final ready = items.where(_hasVisualImage).toList();
    if (ready.length >= 4) {
      return ready.take(4).toList();
    }

    onProgress?.call('Validating final outfit images...');
    final preview = await _buildFullSuggestionPreviewItems(
      occasion: occasion,
      onProgress: onProgress,
      preferFastFallback: preferFastFallback,
    );
    if (preview.firstApiError != null) {
      developer.log(
        'Full outfit preview fallback first error: ${preview.firstApiError}',
        name: 'OutfitScreen',
      );
    }
    // Add preview items that have visuals and don't duplicate an existing piece.
    for (final candidate in preview.items) {
      if (!_hasVisualImage(candidate)) continue;
      final exists = ready.any(
        (e) =>
            e.name.toLowerCase() == candidate.name.toLowerCase() &&
            e.category.toLowerCase() == candidate.category.toLowerCase(),
      );
      if (exists) continue;
      ready.add(candidate);
      if (ready.length >= 4) break;
    }

    // Last resort: pad with imageless original items so the sheet is not empty.
    if (ready.length < 4) {
      for (final original in items) {
        final exists = ready.any(
          (e) =>
              e.name.toLowerCase() == original.name.toLowerCase() &&
              e.category.toLowerCase() == original.category.toLowerCase(),
        );
        if (exists) continue;
        ready.add(original);
        if (ready.length >= 4) break;
      }
    }

    return ready.take(4).toList();
  }

  // ── Selection callbacks ───────────────────────────────────────

  void _onOptionSelected(int index) {
    if (_selectedOption == index) return;
    setState(() => _selectedOption = index);
  }

  void _onOccasionSelected(int index) {
    if (_selectedOccasion == index) return;
    setState(() => _selectedOccasion = index);
  }

  void _onAudienceSelected(int index) {
    if (_selectedAudience == index) return;
    setState(() => _selectedAudience = index);
  }

  /// The search value (`'men'` or `'women'`) for the selected audience.
  String get _audienceSearchValue => _audiences[_selectedAudience].searchValue;

  /// Removes opposing-gender keywords from [value] and prepends the
  /// correct gender prefix, so image queries are always audience-appropriate.
  String _audienceQualifiedSearchName(String value) {
    var trimmed = value.trim();
    if (_selectedAudience == 0) {
      trimmed = trimmed
          .replaceAll(
            RegExp(
              r"\bwomen'?s?\b|\bfemale\b|\bgirls?\b",
              caseSensitive: false,
            ),
            '',
          )
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    } else {
      trimmed = trimmed
          .replaceAll(
            RegExp(r"\bmen'?s?\b|\bmale\b|\bboys?\b", caseSensitive: false),
            '',
          )
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }
    final lower = trimmed.toLowerCase();
    final hasTargetAudience = _selectedAudience == 0
        ? (lower.contains('men') ||
              lower.contains('male') ||
              lower.contains('boy'))
        : (lower.contains('women') ||
              lower.contains('female') ||
              lower.contains('girl'));
    if (hasTargetAudience) {
      return trimmed;
    }
    final prefix = _selectedAudience == 0 ? "men's" : "women's";
    return '$prefix $trimmed';
  }

  // ── Wardrobe category helpers ─────────────────────────────────

  /// Maps a clothing [category] string to its [_WardrobeBucket] enum value.
  _WardrobeBucket _bucketForCategory(String? category) {
    final c = (category ?? '').toLowerCase();
    if (c.contains('top') ||
        c.contains('shirt') ||
        c.contains('t-shirt') ||
        c.contains('tee') ||
        c.contains('blouse') ||
        c.contains('hoodie') ||
        c.contains('sweater') ||
        c.contains('cardigan')) {
      return _WardrobeBucket.top;
    }
    if (c.contains('bottom') ||
        c.contains('pant') ||
        c.contains('trouser') ||
        c.contains('jean') ||
        c.contains('skirt') ||
        c.contains('short') ||
        c.contains('legging')) {
      return _WardrobeBucket.bottom;
    }
    if (c.contains('shoe') ||
        c.contains('sneaker') ||
        c.contains('boot') ||
        c.contains('loafer') ||
        c.contains('sandal') ||
        c.contains('heel') ||
        c.contains('flat')) {
      return _WardrobeBucket.shoes;
    }
    if (c.contains('jacket') ||
        c.contains('coat') ||
        c.contains('blazer') ||
        c.contains('outer')) {
      return _WardrobeBucket.jacket;
    }
    if (c.contains('acc') ||
        c.contains('access') ||
        c.contains('hat') ||
        c.contains('cap') ||
        c.contains('belt') ||
        c.contains('bag') ||
        c.contains('watch') ||
        c.contains('scarf') ||
        c.contains('glove')) {
      return _WardrobeBucket.accessory;
    }
    return _WardrobeBucket.other;
  }

  /// Returns the default emoji for a [_WardrobeBucket].
  String _emojiForBucket(_WardrobeBucket bucket) {
    switch (bucket) {
      case _WardrobeBucket.top:
        return '\u{1F455}';
      case _WardrobeBucket.bottom:
        return '\u{1F456}';
      case _WardrobeBucket.shoes:
        return '\u{1F45F}';
      case _WardrobeBucket.jacket:
        return '\u{1F9E5}';
      case _WardrobeBucket.accessory:
        return '\u{1F9E2}';
      case _WardrobeBucket.other:
        return '\u{2728}';
    }
  }

  /// Returns the desired set of wardrobe buckets for an outfit, taking into
  /// account the [occasion] and current [band]. Sport outfits swap the jacket
  /// slot for an accessory in hot/mild weather; business/formal always include
  /// a jacket.
  List<_WardrobeBucket> _desiredBucketsForOccasion({
    required _WeatherBand band,
    required String occasion,
  }) {
    final occ = _occasionKey(occasion);

    if (occ == 'sport') {
      switch (band) {
        case _WeatherBand.hot:
          return const [
            _WardrobeBucket.top,
            _WardrobeBucket.bottom,
            _WardrobeBucket.shoes,
            _WardrobeBucket.accessory,
          ];
        case _WeatherBand.cold:
          return const [
            _WardrobeBucket.top,
            _WardrobeBucket.bottom,
            _WardrobeBucket.shoes,
            _WardrobeBucket.jacket,
          ];
        case _WeatherBand.mild:
          return const [
            _WardrobeBucket.top,
            _WardrobeBucket.bottom,
            _WardrobeBucket.shoes,
            _WardrobeBucket.accessory,
          ];
      }
    }

    if (occ == 'business' || occ == 'formal') {
      switch (band) {
        case _WeatherBand.hot:
          return const [
            _WardrobeBucket.top,
            _WardrobeBucket.bottom,
            _WardrobeBucket.shoes,
            _WardrobeBucket.accessory,
          ];
        case _WeatherBand.cold:
          return const [
            _WardrobeBucket.top,
            _WardrobeBucket.bottom,
            _WardrobeBucket.shoes,
            _WardrobeBucket.jacket,
          ];
        case _WeatherBand.mild:
          return const [
            _WardrobeBucket.top,
            _WardrobeBucket.bottom,
            _WardrobeBucket.shoes,
            _WardrobeBucket.jacket,
          ];
      }
    }

    // Default (casual) bucket lists.
    switch (band) {
      case _WeatherBand.hot:
        return const [
          _WardrobeBucket.top,
          _WardrobeBucket.bottom,
          _WardrobeBucket.shoes,
          _WardrobeBucket.accessory,
        ];
      case _WeatherBand.cold:
        return const [
          _WardrobeBucket.top,
          _WardrobeBucket.bottom,
          _WardrobeBucket.shoes,
          _WardrobeBucket.jacket,
        ];
      case _WeatherBand.mild:
        return const [
          _WardrobeBucket.top,
          _WardrobeBucket.bottom,
          _WardrobeBucket.shoes,
          _WardrobeBucket.jacket,
        ];
    }
  }

  // ── Occasion scoring ──────────────────────────────────────────

  /// Returns keywords associated with [occasion] used by the scoring functions.
  List<String> _occasionKeywords(String occasion) {
    final occ = _occasionKey(occasion);
    switch (occ) {
      case 'business':
        return const [
          'business',
          'office',
          'formal',
          'shirt',
          'trouser',
          'blazer',
          'loafer',
          'oxford',
          'derby',
        ];
      case 'formal':
        return const [
          'formal',
          'suit',
          'blazer',
          'shirt',
          'oxford',
          'derby',
          'heel',
          'dress',
        ];
      case 'sport':
        return const [
          'sport',
          'gym',
          'running',
          'training',
          'jogger',
          'track',
          'sneaker',
          'athletic',
          'dry-fit',
        ];
      default:
        return const [
          'casual',
          'tee',
          'shirt',
          'jean',
          'chino',
          'sneaker',
          'hoodie',
          'cotton',
        ];
    }
  }

  /// Scores a wardrobe [item] for how well it fits the [occasion].
  /// Positive score = good match; penalties are applied for clear mismatches
  /// (e.g. formal shoes scored against a sport occasion).
  int _wardrobeOccasionScore({
    required Map<String, dynamic> item,
    required String occasion,
  }) {
    final name = item['name']?.toString().toLowerCase() ?? '';
    final category = item['category']?.toString().toLowerCase() ?? '';
    final text = '$name $category';
    final occ = _occasionKey(occasion);
    final keywords = _occasionKeywords(occasion);

    var score = 0;
    for (final kw in keywords) {
      if (text.contains(kw)) score += 3;
    }

    // Heavy penalty for formal items in a sport context.
    if (occ == 'sport' &&
        (text.contains('formal') ||
            text.contains('blazer') ||
            text.contains('oxford') ||
            text.contains('derby') ||
            text.contains('loafer') ||
            text.contains('chino') ||
            text.contains('trouser') ||
            text.contains('watch'))) {
      score -= 7;
    }

    // Moderate penalty for sportswear in business/formal context.
    if ((occ == 'business' || occ == 'formal') &&
        (text.contains('sport') ||
            text.contains('gym') ||
            text.contains('running') ||
            text.contains('training'))) {
      score -= 4;
    }

    if (occ == 'casual' && text.contains('formal')) {
      score -= 2;
    }

    return score;
  }

  /// Returns `true` when an [item]'s name/category is so mismatched with
  /// [occasion] that it should be excluded entirely (not just down-scored).
  bool _isStrictOccasionMismatch({
    required Map<String, dynamic> item,
    required String occasion,
  }) {
    final name = item['name']?.toString().toLowerCase() ?? '';
    final category = item['category']?.toString().toLowerCase() ?? '';
    final text = '$name $category';
    final occ = _occasionKey(occasion);

    if (occ == 'sport') {
      return text.contains('formal') ||
          text.contains('blazer') ||
          text.contains('oxford') ||
          text.contains('derby') ||
          text.contains('loafer') ||
          text.contains('chino') ||
          text.contains('trouser') ||
          text.contains('watch');
    }

    if (occ == 'business') {
      return text.contains('sport') ||
          text.contains('gym') ||
          text.contains('running') ||
          text.contains('training') ||
          text.contains('track') ||
          text.contains('jogger') ||
          text.contains('short') ||
          text.contains('hoodie');
    }

    if (occ == 'formal') {
      return text.contains('sport') ||
          text.contains('gym') ||
          text.contains('running') ||
          text.contains('training') ||
          text.contains('track') ||
          text.contains('jogger') ||
          text.contains('hoodie') ||
          text.contains('tee') ||
          text.contains('t-shirt') ||
          text.contains('jean') ||
          text.contains('sneaker');
    }

    // Casual: only hard-block extremely formal attire.
    return text.contains('tuxedo') ||
        text.contains('gown') ||
        text.contains('oxford') ||
        text.contains('derby') ||
        text.contains('formal suit') ||
        text.contains('wedding');
  }

  /// Returns the minimum occasion score an item must reach to be included
  /// in a wardrobe outfit. Higher for sport/business to keep suggestions coherent.
  int _minimumOccasionScore(String occasion) {
    switch (_occasionKey(occasion)) {
      case 'sport':
        return 2;
      case 'business':
        return 1;
      case 'formal':
        return 1;
      case 'casual':
      default:
        return 0;
    }
  }

  // ── Wardrobe outfit builder ───────────────────────────────────

  /// Selects up to 4 items from the user's [items] to form a coherent outfit.
  ///
  /// Items are distributed across the desired buckets for [band] and [occasion].
  /// Each bucket is filled by the highest-scoring, non-mismatched candidate.
  /// When a bucket yields nothing, remaining scored items are used as padding.
  List<_OutfitPiece> _buildOutfitFromWardrobe(
    List<Map<String, dynamic>> items,
    _WeatherBand band,
    String occasion,
  ) {
    if (items.isEmpty) return [];

    // Group wardrobe items by clothing bucket.
    final buckets = <_WardrobeBucket, List<Map<String, dynamic>>>{
      _WardrobeBucket.top: [],
      _WardrobeBucket.bottom: [],
      _WardrobeBucket.shoes: [],
      _WardrobeBucket.jacket: [],
      _WardrobeBucket.accessory: [],
      _WardrobeBucket.other: [],
    };

    for (final item in items) {
      final bucket = _bucketForCategory(item['category']?.toString());
      buckets[bucket]!.add(item);
    }

    final selected = <Map<String, dynamic>>[];
    final usedIds = <String>{};

    // Inner helper: picks the best occasion-appropriate item from [bucket].
    Map<String, dynamic>? takeFrom(_WardrobeBucket bucket) {
      final list = buckets[bucket] ?? const [];
      final candidates = list.where((item) {
        final id = item['id']?.toString();
        return id != null && !usedIds.contains(id);
      }).toList();
      if (candidates.isEmpty) return null;

      final strictCandidates = candidates
          .where(
            (item) =>
                !_isStrictOccasionMismatch(item: item, occasion: occasion),
          )
          .toList();
      if (strictCandidates.isEmpty) return null;

      strictCandidates.sort((a, b) {
        final sb = _wardrobeOccasionScore(item: b, occasion: occasion);
        final sa = _wardrobeOccasionScore(item: a, occasion: occasion);
        return sb.compareTo(sa);
      });

      final bestScore = _wardrobeOccasionScore(
        item: strictCandidates.first,
        occasion: occasion,
      );
      if (bestScore < _minimumOccasionScore(occasion)) {
        return null;
      }

      final picked = strictCandidates.first;
      final id = picked['id']?.toString();
      if (id != null) usedIds.add(id);
      return picked;
    }

    // Fill primary buckets in the desired order.
    for (final bucket in _desiredBucketsForOccasion(
      band: band,
      occasion: occasion,
    )) {
      final item = takeFrom(bucket);
      if (item != null) selected.add(item);
    }

    // Pad with remaining scored items when fewer than 4 were found.
    if (selected.length < 4) {
      final remaining = items.where((item) {
        final id = item['id']?.toString();
        return id != null && !usedIds.contains(id);
      }).toList();
      remaining.sort((a, b) {
        final sb = _wardrobeOccasionScore(item: b, occasion: occasion);
        final sa = _wardrobeOccasionScore(item: a, occasion: occasion);
        return sb.compareTo(sa);
      });
      for (final item in remaining) {
        if (_isStrictOccasionMismatch(item: item, occasion: occasion)) {
          continue;
        }
        final s = _wardrobeOccasionScore(item: item, occasion: occasion);
        if (s < _minimumOccasionScore(occasion)) {
          continue;
        }
        final id = item['id']?.toString();
        if (id == null) continue;
        usedIds.add(id);
        selected.add(item);
        if (selected.length == 4) break;
      }
    }

    return selected.map((item) {
      final name = item['name']?.toString().trim();
      final category = item['category']?.toString().trim();
      final emojiRaw = item['emoji']?.toString().trim();
      final bucket = _bucketForCategory(category);
      final imageUrl = item['image_url']?.toString().trim();
      final imagePath = item['image_path']?.toString().trim();
      return _OutfitPiece(
        emoji: (emojiRaw != null && emojiRaw.isNotEmpty)
            ? emojiRaw
            : _emojiForBucket(bucket),
        name: (name != null && name.isNotEmpty) ? name : 'Item',
        category: (category != null && category.isNotEmpty)
            ? category
            : 'Clothing',
        // Prefer the remote image URL over a local path.
        imagePath: imageUrl?.isNotEmpty == true
            ? imageUrl
            : (imagePath?.isNotEmpty == true ? imagePath : null),
        wardrobeId: item['id']?.toString(),
      );
    }).toList();
  }

  /// Filters [ids] to only those that exist in [wardrobeItems],
  /// so pre-selected IDs passed to the bottom sheet are always valid.
  List<String> _filterWardrobeIds(
    List<String> ids,
    List<Map<String, dynamic>> wardrobeItems,
  ) {
    final existing = wardrobeItems
        .map((e) => e['id'])
        .whereType<String>()
        .toSet();
    return ids.where((id) => existing.contains(id)).toList();
  }

  /// Maps an [OutfitSuggestion] from Gemini to a list of [_OutfitPiece]s,
  /// resolving wardrobe items from [wardrobeItems] when their IDs are present.
  ///
  /// In mode 1 (Full Outfit Suggestion) every item is treated as AI-generated
  /// even if Gemini returned wardrobe references.
  List<_OutfitPiece> _mapSuggestionItems(
    OutfitSuggestion suggestion,
    List<Map<String, dynamic>> wardrobeItems,
    int mode,
  ) {
    final wardrobeById = <String, Map<String, dynamic>>{};
    for (final item in wardrobeItems) {
      final id = item['id']?.toString();
      if (id != null && id.isNotEmpty) {
        wardrobeById[id] = item;
      }
    }

    final pieces = <_OutfitPiece>[];

    for (final item in suggestion.items) {
      final isWardrobe =
          mode != 1 &&
          item.source == 'wardrobe' &&
          item.wardrobeId != null &&
          wardrobeById.containsKey(item.wardrobeId);

      if (isWardrobe) {
        // Use the live wardrobe record for name, category, and image.
        final ward = wardrobeById[item.wardrobeId]!;
        final name = ward['name']?.toString().trim();
        final category = ward['category']?.toString().trim();
        final emojiRaw = ward['emoji']?.toString().trim();
        final bucket = _bucketForCategory(category);
        final imageUrl = ward['image_url']?.toString().trim();
        final imagePath = ward['image_path']?.toString().trim();
        pieces.add(
          _OutfitPiece(
            emoji: (emojiRaw != null && emojiRaw.isNotEmpty)
                ? emojiRaw
                : _emojiForBucket(bucket),
            name: (name != null && name.isNotEmpty) ? name : item.name,
            category: (category != null && category.isNotEmpty)
                ? category
                : item.category,
            imagePath: imageUrl?.isNotEmpty == true
                ? imageUrl
                : (imagePath?.isNotEmpty == true ? imagePath : null),
            wardrobeId: ward['id']?.toString(),
          ),
        );
      } else {
        // AI-generated item; image will be fetched later by [_enrichAiItemsWithImages].
        pieces.add(
          _OutfitPiece(
            emoji: item.emoji.isNotEmpty ? item.emoji : '\u{2728}',
            name: item.name,
            category: item.category,
            imagePath: null,
            apiImageName: item.imageName,
            apiImageType: item.imageType,
            apiImageIndex: item.imageIndex,
          ),
        );
      }
    }

    return pieces;
  }

  // ── Generate outfit ───────────────────────────────────────────

  /// Orchestrates the full outfit generation pipeline:
  ///
  /// 1. Loads the wardrobe from Supabase.
  /// 2. Calls Gemini for suggestions; falls back to local seeds on error.
  /// 3. Enriches AI items with clothing images (with a broader retry loop).
  /// 4. For "Full Outfit" mode, validates that ≥ 4 visual pieces are present.
  /// 5. Opens the [_GeneratedOutfitSheet] with the final item list.
  Future<void> _onGenerateOutfit() async {
    final totalStopwatch = Stopwatch()..start();
    setState(() {
      _isGenerating = true;
      _generationStatus = 'Preparing outfit generation...';
      _errorMessage = null;
    });
    developer.log(
      'Generate outfit started: mode=${_options[_selectedOption].title}, '
      'occasion=${_occasions[_selectedOccasion]}, '
      'audience=$_audienceSearchValue, temp=$_temperatureC',
      name: 'OutfitScreen',
    );

    try {
      final supabase = SupabaseService();
      final userId = supabase.currentUserId;

      if (userId == null) {
        _showError('User not authenticated');
        return;
      }

      _setGenerationStatus('Loading your wardrobe...');
      final wardrobeStopwatch = Stopwatch()..start();
      final wardrobeItems = await supabase.getUserClothingItems(userId);
      developer.log(
        'Wardrobe loaded in ${wardrobeStopwatch.elapsedMilliseconds}ms '
        '(items=${wardrobeItems.length})',
        name: 'OutfitScreen',
      );

      final modeName = _options[_selectedOption].title;
      final locationLabel = _weatherLocationLabel.isNotEmpty
          ? _weatherLocationLabel
          : _selectedGovernorate;

      final suggestionService = OutfitSuggestionService();
      OutfitSuggestion suggestion;

      try {
        _setGenerationStatus('Asking Gemini for outfit ideas...');
        final geminiStopwatch = Stopwatch()..start();
        suggestion = await suggestionService.generate(
          mode: modeName,
          occasion: _occasions[_selectedOccasion],
          wardrobeItems: wardrobeItems,
          governorate: locationLabel,
          temperatureC: _temperatureC,
          audience: _audienceSearchValue,
        );
        _logGeminiSuggestedItems(suggestion);
        developer.log(
          'Gemini suggestion resolved in ${geminiStopwatch.elapsedMilliseconds}ms '
          '(items=${suggestion.items.length})',
          name: 'OutfitScreen',
        );
      } catch (e) {
        // Gemini failed — use locally-seeded fallback outfit immediately.
        developer.log(
          'Gemini suggestion failed after ${totalStopwatch.elapsedMilliseconds}ms: $e',
          name: 'OutfitScreen',
        );
        _showError('AI request failed. Showing fallback suggestions.');
        var fallbackItems = _generateOutfitItems(
          mode: _selectedOption,
          occasion: _occasions[_selectedOccasion],
          wardrobeItems: wardrobeItems,
          temperatureC: _temperatureC,
        );
        if (_selectedOption == 2) {
          fallbackItems = _enforceMixAndMatchComposition(
            items: fallbackItems,
            wardrobeItems: wardrobeItems,
            band: _weatherBandFor(_temperatureC),
            occasion: _occasions[_selectedOccasion],
          );
        }
        _setGenerationStatus('Loading fallback outfit images...');
        fallbackItems = await _enrichAiItemsWithImages(
          fallbackItems,
          onProgress: _setGenerationStatus,
          preferFastFallback: _selectedOption == 1,
        );
        if (_selectedOption == 1) {
          _setGenerationStatus('Validating full outfit images...');
          fallbackItems = await _ensureFullOutfitHasRealImages(
            fallbackItems,
            occasion: _occasions[_selectedOccasion],
            onProgress: _setGenerationStatus,
            preferFastFallback: true,
          );
          if (fallbackItems.length < 4 ||
              fallbackItems.any((e) => !_hasVisualImage(e))) {
            developer.log(
              'Fallback full outfit has partial visuals: '
              'visual=${fallbackItems.where(_hasVisualImage).length}/${fallbackItems.length}',
              name: 'OutfitScreen',
            );
          }
        }
        if (!mounted) return;
        setState(() {
          _isGenerating = false;
          _generationStatus = null;
        });
        _logGeminiImageAlignment(stage: 'fallback', items: fallbackItems);
        developer.log(
          'Fallback outfit ready in ${totalStopwatch.elapsedMilliseconds}ms',
          name: 'OutfitScreen',
        );
        final fallbackSelectedIds = _selectedOption == 1
            ? const <String>[]
            : fallbackItems
                  .map((piece) => piece.wardrobeId)
                  .whereType<String>()
                  .where((id) => id.isNotEmpty)
                  .toSet()
                  .toList();
        _showGeneratedOutfitSheet(
          fallbackItems,
          wardrobeItems,
          fallbackSelectedIds,
        );
        return;
      }

      // Map Gemini's suggestion to internal pieces.
      var outfitItems = _mapSuggestionItems(
        suggestion,
        wardrobeItems,
        _selectedOption,
      );
      if (_selectedOption == 2) {
        outfitItems = _enforceMixAndMatchComposition(
          items: outfitItems,
          wardrobeItems: wardrobeItems,
          band: _weatherBandFor(_temperatureC),
          occasion: _occasions[_selectedOccasion],
        );
      }
      // If the full-outfit response was structurally incomplete, replace it
      // with locally-coordinated seeds rather than showing a broken outfit.
      if (_selectedOption == 1 && !_hasCompleteOutfitStructure(outfitItems)) {
        developer.log(
          'Gemini full outfit structure was incomplete; using coordinated local outfit seeds.',
          name: 'OutfitScreen',
        );
        outfitItems = _aiFullOutfitItems(
          _weatherBandFor(_temperatureC),
          _occasions[_selectedOccasion],
        );
      }
      _logGeminiImageAlignment(
        stage: 'mapped_before_images',
        items: outfitItems,
      );

      _setGenerationStatus('Loading outfit images...');
      final imageStopwatch = Stopwatch()..start();
      outfitItems = await _enrichAiItemsWithImages(
        outfitItems,
        onProgress: _setGenerationStatus,
        preferFastFallback: _selectedOption == 1,
      );
      developer.log(
        'Primary image enrichment finished in ${imageStopwatch.elapsedMilliseconds}ms',
        name: 'OutfitScreen',
      );

      if (_selectedOption == 1) {
        _setGenerationStatus('Validating full outfit images...');
        outfitItems = await _ensureFullOutfitHasRealImages(
          outfitItems,
          occasion: _occasions[_selectedOccasion],
          onProgress: _setGenerationStatus,
          preferFastFallback: true,
        );
        if (outfitItems.length < 4 ||
            outfitItems.any((e) => !_hasVisualImage(e))) {
          developer.log(
            'Primary full outfit has partial visuals: '
            'visual=${outfitItems.where(_hasVisualImage).length}/${outfitItems.length}',
            name: 'OutfitScreen',
          );
        }
      }

      // Wardrobe IDs pre-selected in the bottom sheet (not relevant for full AI).
      final preselectedIds = _selectedOption != 1
          ? (_selectedOption == 2
                ? outfitItems
                      .map((piece) => piece.wardrobeId)
                      .whereType<String>()
                      .where((id) => id.isNotEmpty)
                      .toList()
                : _filterWardrobeIds(
                    suggestion.suggestedWardrobeIds,
                    wardrobeItems,
                  ))
          : const <String>[];

      if (!mounted) return;
      setState(() {
        _isGenerating = false;
        _generationStatus = null;
      });
      _logGeminiImageAlignment(stage: 'primary', items: outfitItems);
      developer.log(
        'Generate outfit completed in ${totalStopwatch.elapsedMilliseconds}ms '
        '(items=${outfitItems.length}, visual=${outfitItems.where(_hasVisualImage).length})',
        name: 'OutfitScreen',
      );

      _showGeneratedOutfitSheet(outfitItems, wardrobeItems, preselectedIds);
    } catch (e) {
      developer.log(
        'Generate outfit failed after ${totalStopwatch.elapsedMilliseconds}ms: $e',
        name: 'OutfitScreen',
      );
      _showError('Failed to generate outfit: ${e.toString()}');
    } finally {
      if (mounted) {
        setState(() {
          _isGenerating = false;
          _generationStatus = null;
        });
      }
    }
  }

  /// Selects outfit items using the local (non-Gemini) strategy for [mode]:
  ///
  /// - Mode 0 (Wardrobe): picks from real wardrobe items; falls back to AI seeds.
  /// - Mode 1 (Full AI): returns AI-seed pieces directly.
  /// - Mode 2 (Mix & Match): combines 1-2 real items with AI seeds.
  List<_OutfitPiece> _generateOutfitItems({
    required int mode,
    required String occasion,
    required List<Map<String, dynamic>> wardrobeItems,
    required double temperatureC,
  }) {
    final band = _weatherBandFor(temperatureC);
    if (mode == 0) {
      final realItems = _buildOutfitFromWardrobe(wardrobeItems, band, occasion);
      if (realItems.length >= 4) return realItems.take(4).toList();
      return _wardrobeBasedItems(band, occasion);
    } else if (mode == 1) {
      return _aiFullOutfitItems(band, occasion);
    } else {
      final realItems = _buildOutfitFromWardrobe(wardrobeItems, band, occasion);
      final aiItems = _mixAndMatchItems(band, occasion);
      final seeded = <_OutfitPiece>[...realItems.take(2), ...aiItems];
      return _enforceMixAndMatchComposition(
        items: seeded,
        wardrobeItems: wardrobeItems,
        band: band,
        occasion: occasion,
      );
    }
  }

  /// Ensures Mix & Match always returns a blended outfit:
  /// - Use 1 or 2 wardrobe anchors (any category).
  /// - Fill remaining slots with AI pieces that complete missing buckets.
  List<_OutfitPiece> _enforceMixAndMatchComposition({
    required List<_OutfitPiece> items,
    required List<Map<String, dynamic>> wardrobeItems,
    required _WeatherBand band,
    required String occasion,
  }) {
    final desiredBuckets = _desiredBucketsForOccasion(
      band: band,
      occasion: occasion,
    );

    final wardrobeCandidates = <_OutfitPiece>[];
    final wardrobeIds = <String>{};
    void addWardrobeCandidate(_OutfitPiece piece) {
      final id = piece.wardrobeId;
      if (id == null || id.isEmpty) return;
      if (wardrobeIds.add(id)) {
        wardrobeCandidates.add(piece);
      }
    }

    for (final piece in items) {
      addWardrobeCandidate(piece);
    }
    for (final piece in _buildOutfitFromWardrobe(
      wardrobeItems,
      band,
      occasion,
    )) {
      addWardrobeCandidate(piece);
    }

    final inputWardrobeCount = items
        .where(
          (piece) => piece.wardrobeId != null && piece.wardrobeId!.isNotEmpty,
        )
        .length;
    final targetWardrobeCount = wardrobeCandidates.isEmpty
        ? 0
        : (inputWardrobeCount >= 2 ? 2 : 1);
    final selectedWardrobe = <_OutfitPiece>[];
    final selectedWardrobeIds = <String>{};

    void selectWardrobe(_OutfitPiece piece) {
      final id = piece.wardrobeId;
      if (id == null || id.isEmpty) return;
      if (selectedWardrobeIds.add(id)) {
        selectedWardrobe.add(piece);
      }
    }

    _OutfitPiece? firstByBucket(_WardrobeBucket bucket) {
      for (final piece in wardrobeCandidates) {
        final id = piece.wardrobeId;
        if (id == null || selectedWardrobeIds.contains(id)) continue;
        if (_bucketForCategory(piece.category) == bucket) return piece;
      }
      return null;
    }

    for (final bucket in desiredBuckets) {
      if (selectedWardrobe.length >= targetWardrobeCount) break;
      final next = firstByBucket(bucket);
      if (next != null) selectWardrobe(next);
    }

    for (final piece in wardrobeCandidates) {
      if (selectedWardrobe.length >= targetWardrobeCount) break;
      selectWardrobe(piece);
    }

    final aiCandidates = <_OutfitPiece>[];
    final aiCandidateKeys = <String>{};
    String aiKey(_OutfitPiece piece) {
      final imageRef = piece.apiImageName ?? piece.imagePath ?? '';
      return '${piece.name}|${piece.category}|$imageRef'.toLowerCase();
    }

    void addAiCandidate(_OutfitPiece piece) {
      if (piece.wardrobeId != null && piece.wardrobeId!.isNotEmpty) return;
      final key = aiKey(piece);
      if (aiCandidateKeys.add(key)) {
        aiCandidates.add(piece);
      }
    }

    for (final piece in items) {
      addAiCandidate(piece);
    }
    for (final piece in _mixAndMatchItems(band, occasion)) {
      addAiCandidate(piece);
    }

    final targetAiCount = 4 - selectedWardrobe.length;
    final selectedAi = <_OutfitPiece>[];
    final selectedAiKeys = <String>{};
    final occupiedBuckets = selectedWardrobe
        .map((piece) => _bucketForCategory(piece.category))
        .toSet();

    bool selectAiByBucket(_WardrobeBucket bucket) {
      for (final candidate in aiCandidates) {
        final key = aiKey(candidate);
        if (selectedAiKeys.contains(key)) continue;
        if (_bucketForCategory(candidate.category) == bucket) {
          selectedAiKeys.add(key);
          selectedAi.add(candidate);
          occupiedBuckets.add(bucket);
          return true;
        }
      }
      return false;
    }

    for (final bucket in desiredBuckets) {
      if (selectedAi.length >= targetAiCount) break;
      if (occupiedBuckets.contains(bucket)) continue;
      selectAiByBucket(bucket);
    }

    while (selectedAi.length < targetAiCount) {
      _OutfitPiece? preferred;
      for (final candidate in aiCandidates) {
        final key = aiKey(candidate);
        if (selectedAiKeys.contains(key)) continue;
        final bucket = _bucketForCategory(candidate.category);
        if (!occupiedBuckets.contains(bucket)) {
          preferred = candidate;
          break;
        }
      }
      preferred ??= aiCandidates.firstWhere(
        (candidate) => !selectedAiKeys.contains(aiKey(candidate)),
        orElse: () => _OutfitPiece(
          emoji: '\u{2728}',
          name: 'AI Suggestion',
          category: 'Accessory',
          apiImageName: _audienceQualifiedSearchName('minimal accessory'),
          apiImageType: 'accessory',
          apiImageIndex: 0,
        ),
      );

      final key = aiKey(preferred);
      if (!selectedAiKeys.add(key)) break;
      selectedAi.add(preferred);
      occupiedBuckets.add(_bucketForCategory(preferred.category));
    }

    final out = <_OutfitPiece>[...selectedWardrobe, ...selectedAi];
    return out.take(4).toList();
  }

  // ── Generated outfit bottom sheet ─────────────────────────────

  /// Opens the result bottom sheet with [items] and marks the wardrobe pieces
  /// indicated by [preselectedIds] as already selected.
  void _showGeneratedOutfitSheet(
    List<_OutfitPiece> items,
    List<Map<String, dynamic>> wardrobeItems,
    List<String> preselectedIds,
  ) {
    final modeName = _options[_selectedOption].title;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _GeneratedOutfitSheet(
        modeName: modeName,
        occasion: _occasions[_selectedOccasion],
        items: items,
        wardrobeItems: wardrobeItems,
        preselectedIds: preselectedIds,
        // In "Full Outfit" mode the user has no wardrobe items to select.
        requireWardrobeSelection: _selectedOption != 1,
        onSave: (selectedIds) async {
          if (mounted) Navigator.of(context).pop();
          await _openSaveOutfitPage(items: items, clothingItemIds: selectedIds);
        },
      ),
    );
  }

  /// Pushes the [_SaveOutfitPage] where the user can name and schedule
  /// the outfit before it is persisted to Supabase.
  Future<void> _openSaveOutfitPage({
    required List<_OutfitPiece> items,
    required List<String> clothingItemIds,
  }) async {
    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _SaveOutfitPage(
          modeName: _options[_selectedOption].title,
          occasion: _occasions[_selectedOccasion],
          audienceLabel: _audiences[_selectedAudience].label,
          items: items,
          currentTemperatureC: _temperatureC,
          initialWeatherBand: _weatherBandFor(_temperatureC),
          onSave: (draft) async {
            await _saveOutfit(
              items,
              clothingItemIds: clothingItemIds,
              customName: draft.name,
              plannedDate: draft.plannedDate,
              suitableWeatherBand: draft.weatherBand,
              suitableMinTempC: draft.minTempC,
              suitableMaxTempC: draft.maxTempC,
            );
          },
        ),
      ),
    );
  }

  // ── Save outfit ───────────────────────────────────────────────

  String _weatherBandText(_WeatherBand band) {
    switch (band) {
      case _WeatherBand.cold:
        return 'Cold';
      case _WeatherBand.mild:
        return 'Mild';
      case _WeatherBand.hot:
        return 'Hot';
    }
  }

  /// Returns the full English weekday name for [date].
  String _weekdayName(DateTime date) {
    const names = <String>[
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return names[(date.weekday - 1).clamp(0, 6)];
  }

  /// Persists the outfit to Supabase via [OutfitProvider].
  ///
  /// Serialises all generation context (mode, occasion, audience, temperature,
  /// planned date, weather band, and individual items) into the `notes` JSON
  /// field so the home screen can display a rich preview without re-fetching.
  Future<void> _saveOutfit(
    List<_OutfitPiece> items, {
    required List<String> clothingItemIds,
    String? customName,
    DateTime? plannedDate,
    _WeatherBand? suitableWeatherBand,
    double? suitableMinTempC,
    double? suitableMaxTempC,
  }) async {
    try {
      final supabase = SupabaseService();
      final userId = supabase.currentUserId;

      if (userId == null) {
        _showError('User not authenticated');
        return;
      }

      final outfitProvider = context.read<OutfitProvider>();
      // Normalise to midnight so the date is date-only (no time component).
      final normalizedPlannedDate = DateTime(
        (plannedDate ?? DateTime.now()).year,
        (plannedDate ?? DateTime.now()).month,
        (plannedDate ?? DateTime.now()).day,
      );
      final selectedBand =
          suitableWeatherBand ?? _weatherBandFor(_temperatureC);
      final minTemp = suitableMinTempC ?? (_temperatureC - 3);
      final maxTemp = suitableMaxTempC ?? (_temperatureC + 3);

      final noteItems = <Map<String, dynamic>>[];

      String? normalizedImagePath(String? value) {
        if (value == null) return null;
        final trimmed = value.trim();
        return trimmed.isEmpty ? null : trimmed;
      }

      for (final piece in items) {
        final wardrobeId = piece.wardrobeId?.trim();
        final isWardrobePiece = wardrobeId != null && wardrobeId.isNotEmpty;
        final primaryImagePath = normalizedImagePath(piece.imagePath);
        final sourceImagePath = normalizedImagePath(piece.apiSourceImageUrl);
        noteItems.add({
          'name': piece.name,
          'category': piece.category,
          'emoji': piece.emoji,
          // Keep the exact rendered image URL first (image service endpoint).
          'image_path': primaryImagePath ?? sourceImagePath,
          // Keep source URL only as fallback metadata.
          'fallback_image_path': sourceImagePath,
          'source': isWardrobePiece ? 'wardrobe' : 'ai',
          'wardrobe_id': isWardrobePiece ? wardrobeId : null,
          'api_image_name': piece.apiImageName,
          'api_image_type': piece.apiImageType,
          'api_image_index': piece.apiImageIndex,
        });
      }

      final notesJson = jsonEncode({
        'generated_at': DateTime.now().toIso8601String(),
        'mode': _options[_selectedOption].title,
        'occasion': _occasions[_selectedOccasion],
        'audience': _audienceSearchValue,
        'governorate': _selectedGovernorate,
        'temperature_c': _temperatureC,
        'planned_for_date': normalizedPlannedDate.toIso8601String(),
        'planned_day_name': _weekdayName(normalizedPlannedDate),
        'suitable_weather': _weatherBandText(selectedBand),
        'suitable_temp_min_c': minTemp,
        'suitable_temp_max_c': maxTemp,
        'items': noteItems,
      });

      await outfitProvider.createOutfit(
        userId: userId,
        name: (customName != null && customName.trim().isNotEmpty)
            ? customName.trim()
            : '${_options[_selectedOption].title} - ${_occasions[_selectedOccasion]}',
        occasion: _occasions[_selectedOccasion],
        styleType: _options[_selectedOption].title,
        clothingItemIds: clothingItemIds,
        notes: notesJson,
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              Icon(Icons.check_circle, color: Colors.white),
              SizedBox(width: 8),
              Text('Outfit saved successfully!'),
            ],
          ),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );

      Navigator.of(context).maybePop();
    } catch (e) {
      _showError('Failed to save outfit: ${e.toString()}');
    }
  }

  /// Displays [message] both as an inline banner and a floating snackbar.
  void _showError(String message) {
    setState(() => _errorMessage = message);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(Icons.error_outline, color: Colors.white),
            SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
      ),
    );
  }

  // ── Fallback item builders ────────────────────────────────────
  // These thin wrappers exist so the three generation modes have distinct
  // call sites even though their local fallbacks currently share the same logic.

  List<_OutfitPiece> _wardrobeBasedItems(_WeatherBand band, String occasion) {
    return _aiFullOutfitItems(band, occasion);
  }

  List<_OutfitPiece> _mixAndMatchItems(_WeatherBand band, String occasion) {
    return _aiFullOutfitItems(band, occasion);
  }

  /// Converts the weather/occasion seed list into imageless [_OutfitPiece]s
  /// ready for image enrichment.
  List<_OutfitPiece> _aiFullOutfitItems(_WeatherBand band, String occasion) {
    final seeds = _fullSuggestionSeedsForContext(
      band: band,
      occasion: occasion,
    );
    return seeds
        .map(
          (seed) => _OutfitPiece(
            emoji: seed.emoji,
            name: seed.name,
            category: seed.category,
            apiImageName: seed.searchName,
            apiImageType: seed.type,
            apiImageIndex: 0,
          ),
        )
        .toList();
  }

  // ── Build ─────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _handleBackNavigation();
      },
      child: Scaffold(
        backgroundColor: AppColors.background,

        // ── AppBar ──────────────────────────────────────────────
        appBar: AppBar(
          backgroundColor: AppColors.background,
          elevation: 0,
          leading: GestureDetector(
            onTap: _handleBackNavigation,
            child: Container(
              margin: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadius.sm),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: const Icon(
                Icons.arrow_back_ios_new_rounded,
                size: 18,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          title: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Get Outfit',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              Text(
                'Choose recommendation type',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w400,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),

        // ── Body ────────────────────────────────────────────────
        body: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                AppColors.primarySoft.withValues(alpha: 0.35),
                AppColors.background,
              ],
              stops: const [0.0, 0.42],
            ),
          ),
          child: SlideTransition(
            position: _slideAnim,
            child: FadeTransition(
              opacity: _fadeAnim,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: Column(
                    children: [
                      const SizedBox(height: AppSpacing.md),

                      // Summary card showing current mode, occasion, and weather.
                      _OutfitHeroCard(
                        modeTitle: _options[_selectedOption].title,
                        occasion: _occasions[_selectedOccasion],
                        audienceLabel: _audiences[_selectedAudience].label,
                        temperatureC: _temperatureC,
                        weatherSummary:
                            _weatherSummary ?? _weatherBandLabel(_temperatureC),
                      ),
                      const SizedBox(height: AppSpacing.md),

                      // Inline error banner (also shown as a snackbar).
                      if (_errorMessage != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: AppSpacing.md),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(AppSpacing.md),
                            decoration: BoxDecoration(
                              color: AppColors.error.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(AppRadius.md),
                              border: Border.all(
                                color: AppColors.error.withValues(alpha: 0.4),
                              ),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(AppSpacing.xs),
                                  decoration: BoxDecoration(
                                    color: AppColors.error.withValues(
                                      alpha: 0.15,
                                    ),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.error_outline_rounded,
                                    color: AppColors.error,
                                  ),
                                ),
                                const SizedBox(width: AppSpacing.sm),
                                Expanded(
                                  child: Text(
                                    _errorMessage!,
                                    style: const TextStyle(
                                      color: AppColors.error,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                      // ── Recommendation mode selector ─────────
                      _SectionCard(
                        title: 'Recommendation Mode',
                        subtitle: 'Choose how your outfit should be generated.',
                        icon: Icons.tune_rounded,
                        child: ListView.separated(
                          physics: const NeverScrollableScrollPhysics(),
                          shrinkWrap: true,
                          itemCount: _options.length,
                          separatorBuilder: (context, index) =>
                              const SizedBox(height: AppSpacing.sm + 2),
                          itemBuilder: (context, i) => OutfitOptionCard(
                            icon: _options[i].icon,
                            title: _options[i].title,
                            description: _options[i].description,
                            isSelected: i == _selectedOption,
                            onTap: () => _onOptionSelected(i),
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),

                      // ── Audience selector ────────────────────
                      _SectionCard(
                        title: 'Audience',
                        subtitle: 'Tailor suggestions to men or women style.',
                        icon: Icons.people_alt_outlined,
                        child: _AudienceRow(
                          selectedIndex: _selectedAudience,
                          audiences: _audiences,
                          onSelect: _onAudienceSelected,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),

                      // ── Occasion selector ────────────────────
                      _SectionCard(
                        title: 'Occasion',
                        subtitle: 'Pick where you will wear this outfit.',
                        icon: Icons.event_available_outlined,
                        child: _OccasionRow(
                          selectedIndex: _selectedOccasion,
                          occasions: _occasions,
                          onSelect: _onOccasionSelected,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),

                      // ── Weather context card ─────────────────
                      _WeatherContextCard(
                        governorates: _governorates,
                        selectedGovernorate: _selectedGovernorate,
                        temperatureC: _temperatureC,
                        isLoading: _isWeatherLoading,
                        errorMessage: _weatherError,
                        weatherSummary:
                            _weatherSummary ?? _weatherBandLabel(_temperatureC),
                        recommendation: _weatherRecommendation(_temperatureC),
                        updatedAt: _weatherUpdatedAt,
                        usingDeviceLocation: _usingDeviceLocation,
                        locationLabel: _weatherLocationLabel,
                        onUseMyLocation: () => _loadWeather(preferDevice: true),
                        onRefresh: () =>
                            _loadWeather(preferDevice: _usingDeviceLocation),
                        onGovernorateChanged: (v) {
                          setState(() {
                            _selectedGovernorate = v;
                            _usingDeviceLocation = false;
                          });
                          _loadWeather(preferDevice: false);
                        },
                      ),
                      const SizedBox(height: AppSpacing.md),

                      // ── Generate button + status label ────────
                      _GenerateButton(
                        isGenerating: _isGenerating,
                        statusText: _generationStatus,
                        onPressed: _isGenerating ? null : _onGenerateOutfit,
                      ),
                      if (_isGenerating &&
                          _generationStatus?.trim().isNotEmpty == true) ...[
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          _generationStatus!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                      const SizedBox(height: AppSpacing.lg),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),

        // ── Bottom navigation bar ────────────────────────────────
        bottomNavigationBar: const AppBottomNavBar(currentIndex: 3),
      ),
    );
  }
}
