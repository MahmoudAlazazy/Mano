import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';
import 'package:mano/providers/supabase_provider.dart';
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

class OutfitScreen extends StatefulWidget {
  const OutfitScreen({super.key});

  @override
  State<OutfitScreen> createState() => _OutfitScreenState();
}

class _OutfitScreenState extends State<OutfitScreen>
    with SingleTickerProviderStateMixin {
  // ── State ────────────────────────────────────────────────────
  int _selectedOption = 0;
  int _selectedOccasion = 0;
  bool _isGenerating = false;
  String? _generationStatus;
  String? _errorMessage;
  String _selectedGovernorate = 'Cairo';
  double _temperatureC = 24.0;
  bool _isWeatherLoading = false;
  String? _weatherError;
  DateTime? _weatherUpdatedAt;
  String? _weatherSummary;
  String _weatherLocationLabel = 'Detecting location...';
  bool _usingDeviceLocation = true;
  bool _didReadRouteArgs = false;
  final WeatherService _weatherService = WeatherService();
  final ClothingImageService _clothingImageService = ClothingImageService();
  final Map<String, WeatherCoordinates> _coordinatesCache = {};

  // ── Animation ────────────────────────────────────────────────
  late final AnimationController _controller;
  late final Animation<double> _fadeAnim;
  late final Animation<Offset> _slideAnim;

  // ── Option definitions ───────────────────────────────────────
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

  @override
  void initState() {
    super.initState();
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
    if (_didReadRouteArgs) return;
    _didReadRouteArgs = true;
    _hydrateSelectionFromRouteArgs();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<bool> _handleBackNavigation() async {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
      return false;
    }
    navigator.pushReplacementNamed(AppRoutes.home);
    return false;
  }

  void _setGenerationStatus(String? status) {
    if (!mounted) return;
    setState(() => _generationStatus = status);
    if (status != null && status.trim().isNotEmpty) {
      _terminalDebug(status, tag: 'OutfitScreen');
    }
  }

  void _terminalDebug(String message, {String tag = 'OutfitDebug'}) {
    developer.log(message, name: tag);
    // ignore: avoid_print
    print('[$tag] $message');
  }

  String _normalizeDebugValue(String? value) {
    if (value == null) return '';
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _shortDebug(String? value, {int max = 180}) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty) return '-';
    if (raw.length <= max) return raw;
    return '${raw.substring(0, max)}...';
  }

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

  void _hydrateSelectionFromRouteArgs() {
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is! Map) return;

    final selectedOption = args['selected_option'];
    final selectFullOutfit = args['select_full_outfit'] == true;
    final selectedOccasion = args['selected_occasion'];

    var nextOption = _selectedOption;
    var nextOccasion = _selectedOccasion;

    if (selectFullOutfit) {
      nextOption = 1;
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

  String _normalizeGovernorateKey(String raw) {
    return raw
        .toLowerCase()
        .replaceAll(RegExp(r'governorate', caseSensitive: false), '')
        .replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  String? _matchGovernorate(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final key = _normalizeGovernorateKey(raw);
    if (key.isEmpty) return null;

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
      if (cityKey != governorateKey) {
        return '$city, $governorate';
      }
      return governorate;
    }
    if (governorate != null && governorate.isNotEmpty) {
      return governorate;
    }
    if (city != null && city.isNotEmpty) {
      return city;
    }
    if (fallbackLabel != null && fallbackLabel.trim().isNotEmpty) {
      return fallbackLabel.trim();
    }
    return 'Location unavailable';
  }

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
          locationError = e.toString().replaceFirst('Exception: ', '').trim();
        }
      }

      if (coords == null) {
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

  _WeatherBand _weatherBandFor(double tempC) {
    if (tempC <= 18) return _WeatherBand.cold;
    if (tempC >= 28) return _WeatherBand.hot;
    return _WeatherBand.mild;
  }

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

  String _inferImageType({required String name, required String category}) {
    final text = '${name.toLowerCase()} ${category.toLowerCase()}';

    if (text.contains('watch')) return 'watch';
    if (text.contains('sunglass')) return 'sunglasses';
    if (text.contains('cap') || text.contains('hat')) return 'cap';
    if (text.contains('boot')) return 'boots';
    if (text.contains('loafer')) return 'loafers';
    if (text.contains('sneaker') || text.contains('shoe')) return 'shoes';
    if (text.contains('short')) return 'shorts';
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

  String _occasionKey(String occasion) {
    final v = occasion.toLowerCase().trim();
    if (v.contains('business')) return 'business';
    if (v.contains('formal')) return 'formal';
    if (v.contains('sport')) return 'sport';
    return 'casual';
  }

  List<_ApiSuggestionSeed> _fullSuggestionSeedsForContext({
    required _WeatherBand band,
    required String occasion,
  }) {
    final occ = _occasionKey(occasion);

    if (occ == 'formal') {
      switch (band) {
        case _WeatherBand.hot:
          return const [
            _ApiSuggestionSeed(
              searchName: 'formal linen shirt',
              type: 'shirt',
              name: 'Formal Shirt',
              category: 'Top',
              emoji: '\u{1F454}',
            ),
            _ApiSuggestionSeed(
              searchName: 'formal slim trousers',
              type: 'pants',
              name: 'Formal Trousers',
              category: 'Bottom',
              emoji: '\u{1F456}',
            ),
            _ApiSuggestionSeed(
              searchName: 'oxford leather shoes',
              type: 'shoes',
              name: 'Oxford Shoes',
              category: 'Shoes',
              emoji: '\u{1F45E}',
            ),
            _ApiSuggestionSeed(
              searchName: 'formal blazer',
              type: 'blazer',
              name: 'Blazer',
              category: 'Jacket',
              emoji: '\u{1F9E5}',
            ),
          ];
        case _WeatherBand.cold:
          return const [
            _ApiSuggestionSeed(
              searchName: 'formal turtleneck',
              type: 'top',
              name: 'Turtleneck',
              category: 'Top',
              emoji: '\u{1F9E5}',
            ),
            _ApiSuggestionSeed(
              searchName: 'formal wool trousers',
              type: 'pants',
              name: 'Wool Trousers',
              category: 'Bottom',
              emoji: '\u{1F456}',
            ),
            _ApiSuggestionSeed(
              searchName: 'formal leather boots',
              type: 'boots',
              name: 'Formal Boots',
              category: 'Shoes',
              emoji: '\u{1F97E}',
            ),
            _ApiSuggestionSeed(
              searchName: 'formal long coat',
              type: 'coat',
              name: 'Long Coat',
              category: 'Jacket',
              emoji: '\u{1F9E5}',
            ),
          ];
        case _WeatherBand.mild:
          return const [
            _ApiSuggestionSeed(
              searchName: 'formal white shirt',
              type: 'shirt',
              name: 'White Shirt',
              category: 'Top',
              emoji: '\u{1F454}',
            ),
            _ApiSuggestionSeed(
              searchName: 'formal tailored pants',
              type: 'pants',
              name: 'Tailored Pants',
              category: 'Bottom',
              emoji: '\u{1F456}',
            ),
            _ApiSuggestionSeed(
              searchName: 'formal derby shoes',
              type: 'shoes',
              name: 'Derby Shoes',
              category: 'Shoes',
              emoji: '\u{1F45E}',
            ),
            _ApiSuggestionSeed(
              searchName: 'classic formal watch',
              type: 'watch',
              name: 'Classic Watch',
              category: 'Accessory',
              emoji: '\u{231A}',
            ),
          ];
      }
    }

    if (occ == 'business') {
      switch (band) {
        case _WeatherBand.hot:
          return const [
            _ApiSuggestionSeed(
              searchName: 'linen shirt men',
              type: 'shirt',
              name: 'Linen Shirt',
              category: 'Top',
              emoji: '\u{1F454}',
            ),
            _ApiSuggestionSeed(
              searchName: 'tailored trousers',
              type: 'pants',
              name: 'Tailored Trousers',
              category: 'Bottom',
              emoji: '\u{1F456}',
            ),
            _ApiSuggestionSeed(
              searchName: 'brown loafers',
              type: 'loafers',
              name: 'Loafers',
              category: 'Shoes',
              emoji: '\u{1F45E}',
            ),
            _ApiSuggestionSeed(
              searchName: 'minimalist watch',
              type: 'watch',
              name: 'Watch',
              category: 'Accessory',
              emoji: '\u{231A}',
            ),
          ];
        case _WeatherBand.cold:
          return const [
            _ApiSuggestionSeed(
              searchName: 'turtleneck sweater',
              type: 'sweater',
              name: 'Turtleneck',
              category: 'Top',
              emoji: '\u{1F9E5}',
            ),
            _ApiSuggestionSeed(
              searchName: 'wool trousers formal',
              type: 'pants',
              name: 'Wool Trousers',
              category: 'Bottom',
              emoji: '\u{1F456}',
            ),
            _ApiSuggestionSeed(
              searchName: 'leather chelsea boots',
              type: 'boots',
              name: 'Leather Boots',
              category: 'Shoes',
              emoji: '\u{1F97E}',
            ),
            _ApiSuggestionSeed(
              searchName: 'long wool coat',
              type: 'coat',
              name: 'Wool Coat',
              category: 'Jacket',
              emoji: '\u{1F9E5}',
            ),
          ];
        case _WeatherBand.mild:
          return const [
            _ApiSuggestionSeed(
              searchName: 'oxford shirt',
              type: 'shirt',
              name: 'Oxford Shirt',
              category: 'Top',
              emoji: '\u{1F454}',
            ),
            _ApiSuggestionSeed(
              searchName: 'slim fit chinos',
              type: 'pants',
              name: 'Chinos',
              category: 'Bottom',
              emoji: '\u{1F456}',
            ),
            _ApiSuggestionSeed(
              searchName: 'derby shoes',
              type: 'shoes',
              name: 'Derby Shoes',
              category: 'Shoes',
              emoji: '\u{1F45E}',
            ),
            _ApiSuggestionSeed(
              searchName: 'classic watch',
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
              searchName: 'dry fit t shirt',
              type: 'tshirt',
              name: 'Dry-Fit Tee',
              category: 'Top',
              emoji: '\u{1F455}',
            ),
            _ApiSuggestionSeed(
              searchName: 'running shorts',
              type: 'shorts',
              name: 'Running Shorts',
              category: 'Bottom',
              emoji: '\u{1FA73}',
            ),
            _ApiSuggestionSeed(
              searchName: 'training sneakers',
              type: 'sneakers',
              name: 'Training Sneakers',
              category: 'Shoes',
              emoji: '\u{1F45F}',
            ),
            _ApiSuggestionSeed(
              searchName: 'sports cap',
              type: 'cap',
              name: 'Sports Cap',
              category: 'Accessory',
              emoji: '\u{1F9E2}',
            ),
          ];
        case _WeatherBand.cold:
          return const [
            _ApiSuggestionSeed(
              searchName: 'thermal training top',
              type: 'top',
              name: 'Thermal Top',
              category: 'Top',
              emoji: '\u{1F9E5}',
            ),
            _ApiSuggestionSeed(
              searchName: 'running joggers',
              type: 'pants',
              name: 'Joggers',
              category: 'Bottom',
              emoji: '\u{1F456}',
            ),
            _ApiSuggestionSeed(
              searchName: 'running shoes',
              type: 'shoes',
              name: 'Running Shoes',
              category: 'Shoes',
              emoji: '\u{1F45F}',
            ),
            _ApiSuggestionSeed(
              searchName: 'training jacket',
              type: 'jacket',
              name: 'Training Jacket',
              category: 'Jacket',
              emoji: '\u{1F9E5}',
            ),
          ];
        case _WeatherBand.mild:
          return const [
            _ApiSuggestionSeed(
              searchName: 'athletic t shirt',
              type: 'tshirt',
              name: 'Athletic Tee',
              category: 'Top',
              emoji: '\u{1F455}',
            ),
            _ApiSuggestionSeed(
              searchName: 'track joggers',
              type: 'pants',
              name: 'Track Joggers',
              category: 'Bottom',
              emoji: '\u{1F456}',
            ),
            _ApiSuggestionSeed(
              searchName: 'gym sneakers',
              type: 'sneakers',
              name: 'Gym Sneakers',
              category: 'Shoes',
              emoji: '\u{1F45F}',
            ),
            _ApiSuggestionSeed(
              searchName: 'sports cap',
              type: 'cap',
              name: 'Sports Cap',
              category: 'Accessory',
              emoji: '\u{1F9E2}',
            ),
          ];
      }
    }

    switch (band) {
      case _WeatherBand.hot:
        return const [
          _ApiSuggestionSeed(
            searchName: 'cotton t-shirt',
            type: 'tshirt',
            name: 'T-shirt',
            category: 'Top',
            emoji: '\u{1F455}',
          ),
          _ApiSuggestionSeed(
            searchName: 'tailored shorts',
            type: 'shorts',
            name: 'Shorts',
            category: 'Bottom',
            emoji: '\u{1FA73}',
          ),
          _ApiSuggestionSeed(
            searchName: 'white sneakers',
            type: 'sneakers',
            name: 'Sneakers',
            category: 'Shoes',
            emoji: '\u{1F45F}',
          ),
          _ApiSuggestionSeed(
            searchName: 'sunglasses fashion',
            type: 'sunglasses',
            name: 'Sunglasses',
            category: 'Accessory',
            emoji: '\u{1F576}',
          ),
        ];
      case _WeatherBand.cold:
        return const [
          _ApiSuggestionSeed(
            searchName: 'warm hoodie',
            type: 'hoodie',
            name: 'Warm Hoodie',
            category: 'Top',
            emoji: '\u{1F9E5}',
          ),
          _ApiSuggestionSeed(
            searchName: 'dark jeans',
            type: 'jeans',
            name: 'Dark Jeans',
            category: 'Bottom',
            emoji: '\u{1F456}',
          ),
          _ApiSuggestionSeed(
            searchName: 'leather boots',
            type: 'boots',
            name: 'Leather Boots',
            category: 'Shoes',
            emoji: '\u{1F97E}',
          ),
          _ApiSuggestionSeed(
            searchName: 'puffer jacket',
            type: 'jacket',
            name: 'Puffer Jacket',
            category: 'Jacket',
            emoji: '\u{1F9E5}',
          ),
        ];
      case _WeatherBand.mild:
        return const [
          _ApiSuggestionSeed(
            searchName: 'cotton tee',
            type: 'tshirt',
            name: 'Cotton Tee',
            category: 'Top',
            emoji: '\u{1F455}',
          ),
          _ApiSuggestionSeed(
            searchName: 'slim jeans',
            type: 'jeans',
            name: 'Slim Jeans',
            category: 'Bottom',
            emoji: '\u{1F456}',
          ),
          _ApiSuggestionSeed(
            searchName: 'clean sneakers',
            type: 'sneakers',
            name: 'Clean Sneakers',
            category: 'Shoes',
            emoji: '\u{1F45F}',
          ),
          _ApiSuggestionSeed(
            searchName: 'baseball cap',
            type: 'cap',
            name: 'Cap',
            category: 'Accessory',
            emoji: '\u{1F9E2}',
          ),
        ];
    }
  }

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
          index: 0,
          allowGenericFallback: preferFastFallback,
          skipMetadataSearch: preferFastFallback,
          minConfidenceScore: 2,
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

  bool _hasVisualImage(_OutfitPiece piece) {
    final hasBytes = piece.imageBytes != null && piece.imageBytes!.isNotEmpty;
    final hasPath =
        piece.imagePath != null && piece.imagePath!.trim().isNotEmpty;
    return hasBytes || hasPath;
  }

  List<String> _imageTypeCandidates({
    required String baseType,
    required String category,
  }) {
    final out = <String>[baseType];
    final c = category.toLowerCase();
    if (c.contains('shoe') || c.contains('sneaker') || c.contains('boot')) {
      out.addAll(['shoes', 'sneakers']);
    } else if (c.contains('pant') ||
        c.contains('bottom') ||
        c.contains('jean') ||
        c.contains('short')) {
      out.addAll(['pants', 'jeans', 'shorts', 'bottom']);
    } else if (c.contains('top') ||
        c.contains('shirt') ||
        c.contains('tee') ||
        c.contains('blouse')) {
      out.addAll(['top', 'shirt', 'tshirt']);
    } else if (c.contains('jacket') ||
        c.contains('coat') ||
        c.contains('outer')) {
      out.addAll(['jacket', 'coat']);
    } else if (c.contains('access')) {
      out.addAll(['accessory', 'watch']);
    }
    out.add('clothes');
    return out.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet().toList();
  }

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
        final directResult = await _clothingImageService.fetchClothingImage(
          name: apiName,
          type: apiType,
          index: piece.apiImageIndex,
          allowGenericFallback: preferFastFallback,
          skipMetadataSearch: preferFastFallback,
          minConfidenceScore: 2,
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
        if (preferFastFallback) {
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
        for (final minScore in const [4, 2]) {
          for (final query in queryCandidates) {
            for (final t in typeCandidates) {
              final candidate = await _clothingImageService.fetchClothingImage(
                name: query,
                type: t,
                index: piece.apiImageIndex,
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

  void _onOptionSelected(int index) {
    if (_selectedOption == index) return;
    setState(() => _selectedOption = index);
  }

  void _onOccasionSelected(int index) {
    if (_selectedOccasion == index) return;
    setState(() => _selectedOccasion = index);
  }

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
        c.contains('heel')) {
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

    // casual
    return text.contains('tuxedo') ||
        text.contains('gown') ||
        text.contains('oxford') ||
        text.contains('derby') ||
        text.contains('formal suit') ||
        text.contains('wedding');
  }

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

  List<_OutfitPiece> _buildOutfitFromWardrobe(
    List<Map<String, dynamic>> items,
    _WeatherBand band,
    String occasion,
  ) {
    if (items.isEmpty) return [];

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

    for (final bucket in _desiredBucketsForOccasion(
      band: band,
      occasion: occasion,
    )) {
      final item = takeFrom(bucket);
      if (item != null) selected.add(item);
    }

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
        imagePath: imageUrl?.isNotEmpty == true
            ? imageUrl
            : (imagePath?.isNotEmpty == true ? imagePath : null),
        wardrobeId: item['id']?.toString(),
      );
    }).toList();
  }

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

  // ── Generate outfit ──────────────────────────────────────────
  Future<void> _onGenerateOutfit() async {
    final totalStopwatch = Stopwatch()..start();
    setState(() {
      _isGenerating = true;
      _generationStatus = 'Preparing outfit generation...';
      _errorMessage = null;
    });
    developer.log(
      'Generate outfit started: mode=${_options[_selectedOption].title}, '
      'occasion=${_occasions[_selectedOccasion]}, temp=$_temperatureC',
      name: 'OutfitScreen',
    );

    try {
      final supabase = SupabaseService();
      final userId = supabase.currentUserId;

      if (userId == null) {
        _showError('User not authenticated');
        return;
      }

      // Get user's clothing items (used for wardrobe + mix)
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
        );
        _logGeminiSuggestedItems(suggestion);
        developer.log(
          'Gemini suggestion resolved in ${geminiStopwatch.elapsedMilliseconds}ms '
          '(items=${suggestion.items.length})',
          name: 'OutfitScreen',
        );
      } catch (e) {
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
        _showGeneratedOutfitSheet(fallbackItems, wardrobeItems, const []);
        return;
      }

      var outfitItems = _mapSuggestionItems(
        suggestion,
        wardrobeItems,
        _selectedOption,
      );
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

      final preselectedIds = _selectedOption != 1
          ? _filterWardrobeIds(suggestion.suggestedWardrobeIds, wardrobeItems)
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

  /// Generate outfit items based on mode
  List<_OutfitPiece> _generateOutfitItems({
    required int mode,
    required String occasion,
    required List<Map<String, dynamic>> wardrobeItems,
    required double temperatureC,
  }) {
    final band = _weatherBandFor(temperatureC);
    if (mode == 0) {
      // Use My Wardrobe - pick from existing items
      final realItems = _buildOutfitFromWardrobe(wardrobeItems, band, occasion);
      if (realItems.length >= 4) return realItems.take(4).toList();
      return _wardrobeBasedItems(band, occasion);
    } else if (mode == 1) {
      // Full Outfit Suggestion
      return _aiFullOutfitItems(band, occasion);
    } else {
      // Mix & Match
      final realItems = _buildOutfitFromWardrobe(wardrobeItems, band, occasion);
      if (realItems.length >= 2) {
        final aiItems = _mixAndMatchItems(band, occasion);
        final combined = <_OutfitPiece>[...realItems.take(2), ...aiItems];
        return combined.take(4).toList();
      }
      return _mixAndMatchItems(band, occasion);
    }
  }

  // ── Generated outfit result bottom sheet ─────────────────────
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
        requireWardrobeSelection: _selectedOption != 1,
        onSave: (selectedIds) =>
            _saveOutfit(items, clothingItemIds: selectedIds),
      ),
    );
  }

  /// Save outfit to Supabase
  Future<void> _saveOutfit(
    List<_OutfitPiece> items, {
    required List<String> clothingItemIds,
  }) async {
    try {
      final supabase = SupabaseService();
      final userId = supabase.currentUserId;

      if (userId == null) {
        _showError('User not authenticated');
        return;
      }

      final outfitProvider = context.read<OutfitProvider>();

      final notesJson = jsonEncode({
        'generated_at': DateTime.now().toIso8601String(),
        'mode': _options[_selectedOption].title,
        'occasion': _occasions[_selectedOccasion],
        'governorate': _selectedGovernorate,
        'temperature_c': _temperatureC,
        'items': items
            .map(
              (e) => {'name': e.name, 'category': e.category, 'emoji': e.emoji},
            )
            .toList(),
      });

      // Create outfit
      await outfitProvider.createOutfit(
        userId: userId,
        name:
            '${_options[_selectedOption].title} - ${_occasions[_selectedOccasion]}',
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

      Navigator.pop(context); // Close bottom sheet
    } catch (e) {
      _showError('Failed to save outfit: ${e.toString()}');
    }
  }

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

  List<_OutfitPiece> _wardrobeBasedItems(_WeatherBand band, String occasion) {
    return _aiFullOutfitItems(band, occasion);
  }

  List<_OutfitPiece> _mixAndMatchItems(_WeatherBand band, String occasion) {
    return _aiFullOutfitItems(band, occasion);
  }

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
          ),
        )
        .toList();
  }

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

        // ── AppBar ───────────────────────────────────────────────
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

        // ── Body ─────────────────────────────────────────────────
        body: SlideTransition(
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

                    // ── Error message display ─────────────────────
                    if (_errorMessage != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.md),
                        child: Container(
                          padding: const EdgeInsets.all(AppSpacing.md),
                          decoration: BoxDecoration(
                            color: AppColors.error.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(AppRadius.md),
                            border: Border.all(color: AppColors.error),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.error_outline, color: AppColors.error),
                              SizedBox(width: AppSpacing.sm),
                              Expanded(
                                child: Text(
                                  _errorMessage!,
                                  style: TextStyle(
                                    color: AppColors.error,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                    // ── Option cards ──────────────────────────────
                    ListView.separated(
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

                    // ── Occasion quick-filter row ─────────────────
                    _OccasionRow(
                      selectedIndex: _selectedOccasion,
                      occasions: _occasions,
                      onSelect: _onOccasionSelected,
                    ),
                    const SizedBox(height: AppSpacing.md),

                    // Weather context
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

                    // ── Generate button ───────────────────────────
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

        // ── Bottom Navigation Bar ─────────────────────────────────
        bottomNavigationBar: const AppBottomNavBar(currentIndex: 3),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// Occasion quick-filter row
// ─────────────────────────────────────────────────────────────────
class _OccasionRow extends StatelessWidget {
  final int selectedIndex;
  final List<String> occasions;
  final Function(int) onSelect;

  const _OccasionRow({
    required this.selectedIndex,
    required this.occasions,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: AppSpacing.sm),
          child: Text(
            'Occasion',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: List.generate(occasions.length, (i) {
              final isSelected = i == selectedIndex;
              return GestureDetector(
                onTap: () => onSelect(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.only(right: AppSpacing.sm),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.sm,
                  ),
                  decoration: BoxDecoration(
                    color: isSelected ? AppColors.primary : AppColors.surface,
                    borderRadius: BorderRadius.circular(AppRadius.full),
                    border: Border.all(
                      color: isSelected ? AppColors.primary : AppColors.border,
                      width: 1.5,
                    ),
                  ),
                  child: Text(
                    occasions[i],
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isSelected ? Colors.white : AppColors.textPrimary,
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────

class _WeatherContextCard extends StatelessWidget {
  final List<String> governorates;
  final String selectedGovernorate;
  final double temperatureC;
  final bool isLoading;
  final String? errorMessage;
  final String weatherSummary;
  final String recommendation;
  final DateTime? updatedAt;
  final bool usingDeviceLocation;
  final String locationLabel;
  final VoidCallback onUseMyLocation;
  final VoidCallback onRefresh;
  final ValueChanged<String> onGovernorateChanged;

  const _WeatherContextCard({
    required this.governorates,
    required this.selectedGovernorate,
    required this.temperatureC,
    required this.isLoading,
    required this.errorMessage,
    required this.weatherSummary,
    required this.recommendation,
    required this.updatedAt,
    required this.usingDeviceLocation,
    required this.locationLabel,
    required this.onUseMyLocation,
    required this.onRefresh,
    required this.onGovernorateChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Weather Context',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Use today\'s weather to guide your outfit generation.',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: onRefresh,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: const Icon(
                    Icons.refresh_rounded,
                    size: 18,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              const Icon(Icons.location_on_outlined, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  locationLabel,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              TextButton(
                onPressed: isLoading ? null : onUseMyLocation,
                child: const Text('Use My Location'),
              ),
            ],
          ),
          if (!usingDeviceLocation) ...[
            const SizedBox(height: AppSpacing.sm),
            DropdownButtonFormField<String>(
              initialValue: selectedGovernorate,
              items: governorates
                  .map((g) => DropdownMenuItem(value: g, child: Text(g)))
                  .toList(),
              onChanged: (v) {
                if (v != null) onGovernorateChanged(v);
              },
              decoration: InputDecoration(
                labelText: 'Governorate',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm,
                ),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.sm + 2),
          if (isLoading)
            Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                const Text('Loading current weather...'),
              ],
            )
          else ...[
            Row(
              children: [
                const Icon(Icons.thermostat_rounded, size: 18),
                const SizedBox(width: 6),
                Text(
                  '${temperatureC.toStringAsFixed(1)} C',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 8),
                Text(
                  weatherSummary,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
            if (updatedAt != null) ...[
              const SizedBox(height: 4),
              Text(
                'Updated at ${_formatTime(updatedAt!)}',
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ],
          if (errorMessage != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              errorMessage!,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.error,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          Text(
            recommendation,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    final local = time.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
}

// Generate Outfit Button
// ─────────────────────────────────────────────────────────────────
class _GenerateButton extends StatelessWidget {
  final bool isGenerating;
  final String? statusText;
  final VoidCallback? onPressed;

  const _GenerateButton({
    required this.isGenerating,
    required this.statusText,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          disabledBackgroundColor: AppColors.primary.withValues(alpha: 0.6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          elevation: 0,
        ),
        child: isGenerating
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    'Generating outfit…',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ],
              )
            : const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.auto_awesome_rounded,
                    size: 20,
                    color: Colors.white,
                  ),
                  SizedBox(width: AppSpacing.sm),
                  Text(
                    'Generate Outfit',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// Generated Outfit Result Bottom Sheet
// ─────────────────────────────────────────────────────────────────
class _GeneratedOutfitSheet extends StatefulWidget {
  final String modeName;
  final String occasion;
  final List<_OutfitPiece> items;
  final List<Map<String, dynamic>> wardrobeItems;
  final List<String> preselectedIds;
  final bool requireWardrobeSelection;
  final Future<void> Function(List<String>) onSave;

  const _GeneratedOutfitSheet({
    required this.modeName,
    required this.occasion,
    required this.items,
    required this.wardrobeItems,
    required this.preselectedIds,
    required this.requireWardrobeSelection,
    required this.onSave,
  });

  @override
  State<_GeneratedOutfitSheet> createState() => _GeneratedOutfitSheetState();
}

class _GeneratedOutfitSheetState extends State<_GeneratedOutfitSheet> {
  final Set<String> _selectedIds = {};
  String? _errorText;

  Widget _pieceVisual(_OutfitPiece piece) {
    if (piece.imageBytes != null && piece.imageBytes!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(
          piece.imageBytes!,
          width: 32,
          height: 32,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) =>
              Text(piece.emoji, style: const TextStyle(fontSize: 26)),
        ),
      );
    }

    final path = piece.imagePath?.trim();
    if (path != null && path.isNotEmpty) {
      final isNetwork =
          path.startsWith('http://') || path.startsWith('https://');
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: isNetwork
            ? Image.network(
                path,
                width: 32,
                height: 32,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    Text(piece.emoji, style: const TextStyle(fontSize: 26)),
              )
            : Image.asset(
                path,
                width: 32,
                height: 32,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    Text(piece.emoji, style: const TextStyle(fontSize: 26)),
              ),
      );
    }
    return Text(piece.emoji, style: const TextStyle(fontSize: 26));
  }

  @override
  void initState() {
    super.initState();
    if (widget.preselectedIds.isNotEmpty) {
      final validIds = widget.wardrobeItems
          .map((e) => e['id'])
          .whereType<String>()
          .toSet();
      _selectedIds.addAll(
        widget.preselectedIds.where((id) => validIds.contains(id)),
      );
    }
    if (widget.requireWardrobeSelection && widget.wardrobeItems.length == 1) {
      final id = widget.wardrobeItems.first['id'];
      if (id is String) _selectedIds.add(id);
    }
  }

  bool get _needsSelection =>
      widget.requireWardrobeSelection && widget.wardrobeItems.isNotEmpty;

  void _toggleSelect(String id) {
    setState(() {
      _selectedIds.contains(id)
          ? _selectedIds.remove(id)
          : _selectedIds.add(id);
      _errorText = null;
    });
  }

  Future<void> _handleSave() async {
    if (_needsSelection && _selectedIds.isEmpty) {
      setState(() => _errorText = 'Select at least one wardrobe item to link.');
      return;
    }
    await widget.onSave(_selectedIds.toList());
  }

  @override
  Widget build(BuildContext context) {
    final wardrobeItems = widget.wardrobeItems;

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: AppSpacing.md,
      ),
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Drag handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(AppRadius.full),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),

            // Header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: AppColors.primarySoft,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: const Icon(
                    Icons.auto_awesome_rounded,
                    color: AppColors.primary,
                    size: 20,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "Today's Outfit",
                        style: AppTextStyles.headlineSmall,
                      ),
                      Text(
                        '${widget.modeName} • ${widget.occasion}',
                        style: AppTextStyles.bodySmall,
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: const Icon(
                      Icons.refresh_rounded,
                      size: 20,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),

            // Outfit pieces grid
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: AppSpacing.sm,
                crossAxisSpacing: AppSpacing.sm,
                childAspectRatio: 2.4,
              ),
              itemCount: widget.items.length,
              itemBuilder: (context, i) {
                final piece = widget.items[i];
                return Container(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Row(
                    children: [
                      _pieceVisual(piece),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              piece.name,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              piece.category,
                              style: AppTextStyles.labelSmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: AppSpacing.md),

            if (widget.requireWardrobeSelection) ...[
              const Text(
                'Link Items From Your Wardrobe',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),

              if (wardrobeItems.isEmpty)
                Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: const Text(
                    'No wardrobe items yet. You can still save the suggestion.',
                    style: AppTextStyles.bodySmall,
                  ),
                )
              else
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: wardrobeItems.map((item) {
                    final id = item['id'] as String?;
                    final name = item['name'] as String? ?? 'Item';
                    final emoji = item['emoji'] as String? ?? '\u{1F455}';
                    final selected = id != null && _selectedIds.contains(id);
                    return FilterChip(
                      label: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 160),
                        child: Text(
                          '$emoji $name',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      selected: selected,
                      onSelected: id == null ? null : (_) => _toggleSelect(id),
                      selectedColor: AppColors.primary.withValues(alpha: 0.15),
                      checkmarkColor: AppColors.primary,
                      side: BorderSide(
                        color: selected ? AppColors.primary : AppColors.border,
                      ),
                    );
                  }).toList(),
                ),

              if (_errorText != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  _errorText!,
                  style: const TextStyle(
                    color: AppColors.error,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],

              const SizedBox(height: AppSpacing.md),
            ],

            // Save button
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _handleSave,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                ),
                child: const Text(
                  'Save Outfit',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Local data models
// ─────────────────────────────────────────────────────────────────
enum _WardrobeBucket { top, bottom, shoes, jacket, accessory, other }

enum _WeatherBand { cold, mild, hot }

class _OutfitOption {
  final IconData icon;
  final String title;
  final String description;
  const _OutfitOption({
    required this.icon,
    required this.title,
    required this.description,
  });
}

class _ApiSuggestionSeed {
  final String searchName;
  final String type;
  final String name;
  final String category;
  final String emoji;

  const _ApiSuggestionSeed({
    required this.searchName,
    required this.type,
    required this.name,
    required this.category,
    required this.emoji,
  });
}

class _PreviewLoadResult {
  final List<_OutfitPiece> items;
  final String? firstApiError;

  const _PreviewLoadResult({required this.items, required this.firstApiError});
}

class _OutfitPiece {
  final String emoji;
  final String name;
  final String category;
  final String? imagePath;
  final Uint8List? imageBytes;
  final String? wardrobeId;
  final String? apiImageName;
  final String? apiImageType;
  final int? apiImageIndex;
  final String? apiSourceImageUrl;
  final String? apiSearchQuery;
  final String? apiSearchEngine;
  final int? apiResultIndex;
  final bool usedGenericFallback;
  const _OutfitPiece({
    required this.emoji,
    required this.name,
    required this.category,
    this.imagePath,
    this.imageBytes,
    this.wardrobeId,
    this.apiImageName,
    this.apiImageType,
    this.apiImageIndex,
    this.apiSourceImageUrl,
    this.apiSearchQuery,
    this.apiSearchEngine,
    this.apiResultIndex,
    this.usedGenericFallback = false,
  });

  _OutfitPiece copyWith({
    String? emoji,
    String? name,
    String? category,
    String? imagePath,
    Uint8List? imageBytes,
    String? wardrobeId,
    String? apiImageName,
    String? apiImageType,
    int? apiImageIndex,
    String? apiSourceImageUrl,
    String? apiSearchQuery,
    String? apiSearchEngine,
    int? apiResultIndex,
    bool? usedGenericFallback,
  }) {
    return _OutfitPiece(
      emoji: emoji ?? this.emoji,
      name: name ?? this.name,
      category: category ?? this.category,
      imagePath: imagePath ?? this.imagePath,
      imageBytes: imageBytes ?? this.imageBytes,
      wardrobeId: wardrobeId ?? this.wardrobeId,
      apiImageName: apiImageName ?? this.apiImageName,
      apiImageType: apiImageType ?? this.apiImageType,
      apiImageIndex: apiImageIndex ?? this.apiImageIndex,
      apiSourceImageUrl: apiSourceImageUrl ?? this.apiSourceImageUrl,
      apiSearchQuery: apiSearchQuery ?? this.apiSearchQuery,
      apiSearchEngine: apiSearchEngine ?? this.apiSearchEngine,
      apiResultIndex: apiResultIndex ?? this.apiResultIndex,
      usedGenericFallback: usedGenericFallback ?? this.usedGenericFallback,
    );
  }
}
