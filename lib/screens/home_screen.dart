import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:mano/providers/supabase_provider.dart';
import 'package:provider/provider.dart';
import 'package:geolocator/geolocator.dart';
import '../theme/app_theme.dart';
import '../main.dart' show AppRoutes;
import '../widgets/bottom_nav_bar.dart';
import '../widgets/weather_card.dart';
import '../widgets/quick_action_card.dart';
import '../widgets/suggestion_card.dart';
import '../services/weather_service.dart';
import '../services/clothing_image_service.dart';
import '../services/supabase_service.dart';

/// The main home screen of the app, showing a greeting, weather, quick actions,
/// AI outfit suggestions, and the user's latest saved outfit.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  // ── Animation ────────────────────────────────────────────────
  late final AnimationController _controller;
  late final Animation<double> _fadeAnim;
  late final Animation<Offset> _slideAnim;

  // ── Services ─────────────────────────────────────────────────
  final WeatherService _weatherService = WeatherService();
  final ClothingImageService _clothingImageService = ClothingImageService();

  // ── Weather state ─────────────────────────────────────────────
  bool _isWeatherLoading = true;
  String _temperatureText = '--';
  String _conditionText = 'Loading weather...';
  String _tipText = 'Fetching local temperature';
  IconData _weatherIcon = Icons.cloud_outlined;
  String _locationLabel = 'Cairo';

  // ── Suggestions state ─────────────────────────────────────────
  bool _isSuggestionsLoading = true;
  String? _suggestionsError;
  String _suggestionsTip = 'Matching your weather right now';
  List<_SuggestionItem> _liveSuggestions = [];   // weather-based suggestions
  List<_SuggestionItem> _savedSuggestions = [];  // latest saved outfit items
  String _savedOutfitTitle = 'Saved Outfit';

  // ── Audience filter (0 = Men, 1 = Women) ─────────────────────
  int _selectedAudience = 0;
  double _lastTemperatureC = 24.0;

  /// Returns the search keyword for the currently selected audience.
  String get _audienceSearchValue => _selectedAudience == 0 ? 'men' : 'women';

  // ── Lifecycle ─────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();

    // Set up a short fade + slide-up entrance animation.
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnim = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.05),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    _loadWeather();
    _loadSavedOutfitSuggestions();

    // Slight delay so the first frame renders before the animation starts.
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // ── Suggestion loading ────────────────────────────────────────

  /// Fetches clothing images for each item in the temperature-based plan
  /// and updates [_liveSuggestions].
  Future<void> _loadSuggestionsForTemperature(double temperatureC) async {
    final plan = _suggestionPlanForTemperature(temperatureC);

    setState(() {
      _isSuggestionsLoading = true;
      _suggestionsError = null;
      _suggestionsTip = plan.tip;
    });

    try {
      String? firstApiError;
      final mapped = await Future.wait(
        plan.items.map((seed) async {
          final imageResult = await _clothingImageService.fetchClothingImage(
            name: seed.searchName,
            type: seed.type,
            audience: _audienceSearchValue,
            allowGenericFallback: false,
            minConfidenceScore: 8,
          );
          firstApiError ??= imageResult.error;
          return _SuggestionItem(
            name: seed.label,
            category: seed.category,
            imagePath: imageResult.isSuccess
                ? imageResult.requestUri?.toString()
                : null,
            imageBytes: imageResult.bytes,
            emoji: seed.emoji,
          );
        }),
      );

      if (!mounted) return;
      setState(() {
        _isSuggestionsLoading = false;
        // Show an error banner only when every item lacks an image.
        _suggestionsError = mapped.every((item) => item.imageBytes == null)
            ? (firstApiError != null
                  ? 'Image API unavailable: $firstApiError'
                  : 'Image API unavailable. Showing fallback icons.')
            : null;
        _liveSuggestions = mapped;
      });
    } catch (e) {
      if (!mounted) return;
      // On failure, show emoji-only cards instead of a blank screen.
      setState(() {
        _isSuggestionsLoading = false;
        _suggestionsError = 'Unable to load suggestions';
        _liveSuggestions = plan.items
            .map(
              (seed) => _SuggestionItem(
                name: seed.label,
                category: seed.category,
                emoji: seed.emoji,
              ),
            )
            .toList();
      });
    }
  }

  /// Called when the user switches between the Men / Women filter.
  void _onAudienceSelected(int index) {
    if (_selectedAudience == index) return;
    setState(() => _selectedAudience = index);
    _loadSuggestionsForTemperature(_lastTemperatureC);
  }

  // ── Suggestion plan selection ─────────────────────────────────

  /// Returns the appropriate outfit plan (tip + item seeds) based on
  /// [temperatureC] and the selected audience.
  ///
  /// Thresholds: ≥ 28 °C → hot, ≤ 18 °C → cool, otherwise mild.
  _SuggestionPlan _suggestionPlanForTemperature(double temperatureC) {
    final isWomen = _selectedAudience == 1;
    if (temperatureC >= 28) {
      if (isWomen) {
        return _SuggestionPlan(
          tip: 'Hot weather - Light women outfits',
          items: const [
            _SuggestionSeed(
              searchName: 'ivory linen sleeveless blouse',
              type: 'blouse',
              label: 'Linen Blouse',
              category: 'Top',
              emoji: '\u{1F45A}',
            ),
            _SuggestionSeed(
              searchName: 'beige high waisted summer shorts',
              type: 'shorts',
              label: 'Summer Shorts',
              category: 'Bottom',
              emoji: '\u{1FA73}',
            ),
            _SuggestionSeed(
              searchName: 'tan flat summer sandals',
              type: 'sandals',
              label: 'Sandals',
              category: 'Shoes',
              emoji: '\u{1F461}',
            ),
            _SuggestionSeed(
              searchName: 'straw tote bag',
              type: 'bag',
              label: 'Straw Tote',
              category: 'Accessory',
              emoji: '\u{1F45C}',
            ),
          ],
        );
      }
      return _SuggestionPlan(
        tip: 'Hot weather - Light men outfits',
        items: const [
          _SuggestionSeed(
            searchName: 'white cotton t-shirt',
            type: 'tshirt',
            label: 'T-shirt',
            category: 'Top',
            emoji: '\u{1F455}',
          ),
          _SuggestionSeed(
            searchName: 'beige chino shorts',
            type: 'shorts',
            label: 'Shorts',
            category: 'Bottom',
            emoji: '\u{1FA73}',
          ),
          _SuggestionSeed(
            searchName: 'white low top sneakers',
            type: 'sneakers',
            label: 'Sneakers',
            category: 'Shoes',
            emoji: '\u{1F45F}',
          ),
          _SuggestionSeed(
            searchName: 'tortoise sunglasses',
            type: 'sunglasses',
            label: 'Sunglasses',
            category: 'Accessory',
            emoji: '\u{1F576}',
          ),
        ],
      );
    }

    if (temperatureC <= 18) {
      if (isWomen) {
        return _SuggestionPlan(
          tip: 'Cool weather - Warm women layers',
          items: const [
            _SuggestionSeed(
              searchName: 'cream knit turtleneck sweater',
              type: 'sweater',
              label: 'Knit Sweater',
              category: 'Top',
              emoji: '\u{1F9E5}',
            ),
            _SuggestionSeed(
              searchName: 'dark straight leg jeans',
              type: 'jeans',
              label: 'Jeans',
              category: 'Bottom',
              emoji: '\u{1F456}',
            ),
            _SuggestionSeed(
              searchName: 'camel wool wrap coat',
              type: 'coat',
              label: 'Coat',
              category: 'Outerwear',
              emoji: '\u{1F9E5}',
            ),
            _SuggestionSeed(
              searchName: 'black leather ankle boots',
              type: 'boots',
              label: 'Ankle Boots',
              category: 'Shoes',
              emoji: '\u{1F97E}',
            ),
          ],
        );
      }
      return _SuggestionPlan(
        tip: 'Cool weather - Warm men layers',
        items: const [
          _SuggestionSeed(
            searchName: 'charcoal fleece hoodie',
            type: 'hoodie',
            label: 'Hoodie',
            category: 'Outerwear',
            emoji: '\u{1F9E5}',
          ),
          _SuggestionSeed(
            searchName: 'dark denim jeans',
            type: 'jeans',
            label: 'Jeans',
            category: 'Bottom',
            emoji: '\u{1F456}',
          ),
          _SuggestionSeed(
            searchName: 'black light jacket',
            type: 'jacket',
            label: 'Jacket',
            category: 'Outerwear',
            emoji: '\u{1F9E5}',
          ),
          _SuggestionSeed(
            searchName: 'brown leather ankle boots',
            type: 'boots',
            label: 'Boots',
            category: 'Shoes',
            emoji: '\u{1F97E}',
          ),
        ],
      );
    }

    // Mild temperature plan
    if (_selectedAudience == 1) {
      return _SuggestionPlan(
        tip: 'Mild weather - relaxed women layers',
        items: const [
          _SuggestionSeed(
            searchName: 'white cotton button blouse',
            type: 'blouse',
            label: 'Blouse',
            category: 'Top',
            emoji: '\u{1F45A}',
          ),
          _SuggestionSeed(
            searchName: 'sand wide leg trousers',
            type: 'pants',
            label: 'Trousers',
            category: 'Bottom',
            emoji: '\u{1F456}',
          ),
          _SuggestionSeed(
            searchName: 'oatmeal cardigan sweater',
            type: 'cardigan',
            label: 'Cardigan',
            category: 'Layer',
            emoji: '\u{1F9E5}',
          ),
          _SuggestionSeed(
            searchName: 'white fashion sneakers',
            type: 'sneakers',
            label: 'Sneakers',
            category: 'Shoes',
            emoji: '\u{1F45F}',
          ),
        ],
      );
    }

    return _SuggestionPlan(
      tip: 'Mild weather - relaxed men layers',
      items: const [
        _SuggestionSeed(
          searchName: 'light blue casual shirt',
          type: 'shirt',
          label: 'Shirt',
          category: 'Top',
          emoji: '\u{1F454}',
        ),
        _SuggestionSeed(
          searchName: 'navy chino pants',
          type: 'pants',
          label: 'Pants',
          category: 'Bottom',
          emoji: '\u{1F456}',
        ),
        _SuggestionSeed(
          searchName: 'gray cardigan sweater',
          type: 'cardigan',
          label: 'Cardigan',
          category: 'Layer',
          emoji: '\u{1F9E5}',
        ),
        _SuggestionSeed(
          searchName: 'white sneakers',
          type: 'sneakers',
          label: 'Sneakers',
          category: 'Shoes',
          emoji: '\u{1F45F}',
        ),
      ],
    );
  }

  // ── Weather loading ───────────────────────────────────────────

  /// Requests the device location, reverse-geocodes it for a city name,
  /// fetches current weather, and then triggers suggestion loading.
  /// Falls back to a neutral 24 °C plan when location is unavailable.
  Future<void> _loadWeather() async {
    setState(() {
      _isWeatherLoading = true;
      _conditionText = 'Loading weather...';
      _tipText = 'Fetching local temperature';
    });

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw Exception('Location services are disabled.');
      }

      // Check and, if necessary, request location permission.
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

      final locationLabel = await _weatherService.reverseGeocode(
        latitude: position.latitude,
        longitude: position.longitude,
      );

      final weather = await _weatherService.fetchCurrentWeather(
        latitude: position.latitude,
        longitude: position.longitude,
      );

      if (!mounted) return;
      final temp = weather.temperatureC;
      setState(() {
        _lastTemperatureC = temp;
        _temperatureText = '${temp.toStringAsFixed(0)}\u00B0C';
        _conditionText = _weatherSummaryFromCode(weather.weatherCode);
        _tipText = _weatherTip(temp);
        _weatherIcon = _weatherIconFromCode(weather.weatherCode);
        _locationLabel = locationLabel ?? 'Cairo';
        _isWeatherLoading = false;
      });
      await _loadSuggestionsForTemperature(temp);
    } catch (e) {
      // Location unavailable — show a placeholder and use a mild-weather plan.
      if (!mounted) return;
      setState(() {
        _lastTemperatureC = 24;
        _isWeatherLoading = false;
        _temperatureText = '--';
        _conditionText = 'Location needed';
        _tipText = 'Enable location to show real weather';
        _weatherIcon = Icons.location_off_rounded;
        _locationLabel = 'Unknown governorate';
      });
      await _loadSuggestionsForTemperature(24);
    }
  }

  // ── Saved outfit loading ──────────────────────────────────────

  /// Loads the user's most recently saved outfit from Supabase and
  /// fetches images for each item to populate [_savedSuggestions].
  Future<void> _loadSavedOutfitSuggestions() async {
    try {
      final supabase = SupabaseService();
      final userId = supabase.currentUserId;
      if (userId == null) return;

      final outfits = await supabase.getUserOutfits(userId);
      if (outfits.isEmpty) {
        if (!mounted) return;
        setState(() {
          _savedSuggestions = [];
          _savedOutfitTitle = 'Saved Outfit';
        });
        return;
      }

      final latestOutfit = outfits.first;
      final collected = _extractSavedItemsFromOutfit(latestOutfit);
      final title = latestOutfit['name']?.toString().trim();

      // Enrich each item with a clothing image from the API.
      final enriched = await Future.wait(
        collected.map((item) async {
          final result = await _clothingImageService.fetchClothingImage(
            name: item.name,
            type: _inferImageType(name: item.name, category: item.category),
            audience: _audienceSearchValue,
            allowGenericFallback: false,
            minConfidenceScore: 8,
          );
          return _SuggestionItem(
            name: item.name,
            category: item.category,
            imagePath: result.isSuccess ? result.requestUri?.toString() : null,
            imageBytes: result.bytes,
            emoji: _sanitizeEmoji(item.emoji, item.category),
          );
        }),
      );

      if (!mounted) return;
      setState(() {
        _savedSuggestions = enriched;
        _savedOutfitTitle = (title != null && title.isNotEmpty)
            ? title
            : 'Saved Outfit';
      });
    } catch (_) {
      // Keep weather suggestions if saved outfits fail to load.
    }
  }

  // ── Navigation helpers ────────────────────────────────────────

  /// Navigates to the try-on screen with the given [items] pre-loaded.
  /// Requires at least two pieces to make a sensible outfit.
  Future<void> _openTryOnWithOutfit({
    required String title,
    required List<_SuggestionItem> items,
  }) async {
    if (items.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Outfit needs at least 2 pieces to try on.'),
        ),
      );
      return;
    }

    await Navigator.pushNamed(
      context,
      AppRoutes.tryOn,
      arguments: {
        'outfit_title': title,
        'outfit_items': items
            .map(
              (e) => {
                'name': e.name,
                'category': e.category,
                'emoji': e.emoji,
                'image_path': e.imagePath,
                'image_bytes': e.imageBytes,
              },
            )
            .toList(),
      },
    );
  }

  /// Opens the full outfit suggestion screen and refreshes saved outfits on return.
  Future<void> _openFullOutfitSuggestion() async {
    await Navigator.pushNamed(
      context,
      AppRoutes.outfit,
      arguments: const {'select_full_outfit': true},
    );
    if (!mounted) return;
    await _loadSavedOutfitSuggestions();
  }

  // ── Data helpers ──────────────────────────────────────────────

  /// Parses the JSON stored in the outfit's `notes` field and returns
  /// a list of [_SuggestionItem]s. Returns an empty list on any error.
  List<_SuggestionItem> _extractSavedItemsFromOutfit(
    Map<String, dynamic> outfit,
  ) {
    final notesRaw = outfit['notes'];
    if (notesRaw is! String || notesRaw.trim().isEmpty) return const [];

    try {
      final decoded = jsonDecode(notesRaw);
      if (decoded is! Map<String, dynamic>) return const [];
      final itemsRaw = decoded['items'];
      if (itemsRaw is! List) return const [];

      final out = <_SuggestionItem>[];
      for (final item in itemsRaw) {
        if (item is! Map) continue;
        final name = item['name']?.toString().trim() ?? '';
        final category = item['category']?.toString().trim() ?? '';
        final emoji = item['emoji']?.toString().trim();
        if (name.isEmpty || category.isEmpty) continue;
        out.add(
          _SuggestionItem(
            name: name,
            category: category,
            emoji: _sanitizeEmoji(emoji, category),
          ),
        );
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Infers a clothing image search type from the item's [name] and [category].
  /// Falls back to `'clothes'` when no keyword matches.
  String _inferImageType({required String name, required String category}) {
    final text = '${name.toLowerCase()} ${category.toLowerCase()}';
    if (text.contains('watch')) return 'watch';
    if (text.contains('sunglass')) return 'sunglasses';
    if (text.contains('cap') || text.contains('hat')) return 'cap';
    if (text.contains('bag') || text.contains('tote') || text.contains('clutch')) {
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
        text.contains('chino') ||
        text.contains('bottom')) {
      return 'pants';
    }
    if (text.contains('jacket') ||
        text.contains('coat') ||
        text.contains('hoodie') ||
        text.contains('blazer') ||
        text.contains('outer')) {
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

  /// Returns a valid emoji for the item, falling back to a category-based
  /// default when [emoji] is null, empty, or a placeholder `'?'`.
  String _sanitizeEmoji(String? emoji, String category) {
    final v = emoji?.trim() ?? '';
    if (v.isNotEmpty && v != '?' && v != '??') {
      return v;
    }
    final c = category.toLowerCase();
    if (c.contains('top') || c.contains('shirt') || c.contains('tee')) {
      return '\u{1F455}';
    }
    if (c.contains('bottom') || c.contains('pant') || c.contains('jean')) {
      return '\u{1F456}';
    }
    if (c.contains('shoe') || c.contains('sneaker') || c.contains('boot')) {
      return '\u{1F45F}';
    }
    if (c.contains('jacket') || c.contains('coat') || c.contains('hoodie')) {
      return '\u{1F9E5}';
    }
    if (c.contains('dress')) {
      return '\u{1F457}';
    }
    if (c.contains('acc') || c.contains('watch') || c.contains('cap')) {
      return '\u{1F9E2}';
    }
    return '\u{2728}';
  }

  // ── Weather helpers ───────────────────────────────────────────

  /// Maps an Open-Meteo WMO weather code to a human-readable label.
  String _weatherSummaryFromCode(int? code) {
    if (code == null) return 'Weather';
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

  /// Maps a WMO weather code to a matching Material icon.
  IconData _weatherIconFromCode(int? code) {
    if (code == null) return Icons.cloud_outlined;
    if (code == 0) return Icons.wb_sunny_rounded;
    if (code >= 1 && code <= 3) return Icons.wb_cloudy_rounded;
    if (code == 45 || code == 48) return Icons.cloud;
    if (code >= 51 && code <= 67) return Icons.grain;
    if (code >= 71 && code <= 77) return Icons.ac_unit;
    if (code >= 80 && code <= 82) return Icons.beach_access;
    if (code >= 95) return Icons.flash_on;
    return Icons.cloud_outlined;
  }

  /// Returns a dressing tip based on the current temperature.
  String _weatherTip(double tempC) {
    if (tempC >= 28) return 'Hot day - choose light, breathable clothes';
    if (tempC <= 18) return 'Cool weather - add a layer or jacket';
    return 'Mild weather - light layers work best';
  }

  // ── Responsive utilities ──────────────────────────────────────
  bool get _isMobile => MediaQuery.of(context).size.width < 600;
  bool get _isTablet =>
      MediaQuery.of(context).size.width >= 600 &&
      MediaQuery.of(context).size.width < 1024;
  bool get _isDesktop => MediaQuery.of(context).size.width >= 1024;

  /// Horizontal page padding adapts to screen size.
  double get _horizontalPadding {
    if (_isDesktop) return 40;
    if (_isTablet) return 28;
    return 20;
  }

  /// Number of columns in the quick-action grid.
  double get _gridCrossAxisCount {
    if (_isDesktop) return 4;
    if (_isTablet) return 3;
    return 2;
  }

  double get _gridChildAspectRatio {
    if (_isDesktop) return 1.4;
    if (_isTablet) return 1.35;
    return 1.3;
  }

  double get _gridSpacing {
    if (_isDesktop) return 20;
    if (_isTablet) return 16;
    return 14;
  }

  /// Fixed height for each horizontal suggestion strip.
  double get _suggestionCardHeight {
    if (_isDesktop) return 208;
    if (_isTablet) return 196;
    return 182;
  }

  /// Maximum content width keeps the layout readable on large screens.
  double get _contentMaxWidth {
    if (_isDesktop) return 1080;
    if (_isTablet) return 860;
    return 560;
  }

  // ── Quick Action data ─────────────────────────────────────────

  static const List<_QuickAction> _actions = [
    _QuickAction(
      icon: Icons.add_rounded,
      title: 'Upload Clothes',
      subtitle: 'New items',
      route: AppRoutes.upload,
    ),
    _QuickAction(
      icon: Icons.face_retouching_natural_rounded,
      title: 'Try On',
      subtitle: 'Avatar fit',
      route: AppRoutes.tryOn,
    ),
    _QuickAction(
      icon: Icons.checkroom_rounded,
      title: 'My Wardrobe',
      subtitle: 'Browse collection',
      route: AppRoutes.wardrobe,
    ),
    _QuickAction(
      icon: Icons.auto_awesome_rounded,
      title: 'Get Outfit',
      subtitle: 'AI suggestions',
      route: AppRoutes.outfit,
    ),
  ];

  /// Navigates to [route] and refreshes saved outfit data on return.
  Future<void> _openActionRoute(String route) async {
    await Navigator.pushNamed(context, route);
    if (!mounted) return;
    await _loadSavedOutfitSuggestions();
  }

  /// Pulls fresh weather and saved outfit data (used by pull-to-refresh).
  Future<void> _refreshHomeData() async {
    await _loadWeather();
    if (!mounted) return;
    await _loadSavedOutfitSuggestions();
  }

  // ── UI builders ───────────────────────────────────────────────

  /// Builds a horizontal scrolling strip of [SuggestionCard]s.
  /// Shows a spinner while loading, or [emptyMessage] when [items] is empty.
  Widget _buildSuggestionStrip({
    required List<_SuggestionItem> items,
    required String emptyMessage,
    bool isLoading = false,
  }) {
    if (isLoading && items.isEmpty) {
      return SizedBox(
        height: _suggestionCardHeight,
        child: const Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (items.isEmpty) {
      return SizedBox(
        height: _suggestionCardHeight,
        child: Center(
          child: Text(
            emptyMessage,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: _suggestionCardHeight,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.only(left: 2, right: 2),
        itemCount: items.length,
        itemBuilder: (context, i) {
          final s = items[i];
          return SuggestionCard(
            // Key includes image dimensions so Flutter replaces the widget
            // when the image source changes after an audience switch.
            key: ValueKey(
              '${s.name}-${s.category}-${s.imagePath}-${s.imageBytes?.length ?? 0}-$i',
            ),
            name: s.name,
            category: s.category,
            imagePath: s.imagePath,
            imageBytes: s.imageBytes,
            emoji: s.emoji,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    final profile = context.watch<ProfileProvider>().profile;
    // Fall back to 'there' when the user hasn't set a display name yet.
    final userName = profile?.name.trim().isNotEmpty == true
        ? profile!.name.trim()
        : 'there';

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          // Decorative background blobs (non-interactive)
          const _HomeBackgroundDecor(),
          // Main scrollable content with fade + slide-up entrance animation
          SlideTransition(
            position: _slideAnim,
            child: FadeTransition(
              opacity: _fadeAnim,
              child: RefreshIndicator(
                color: AppColors.primary,
                backgroundColor: AppColors.surface,
                onRefresh: _refreshHomeData,
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          _horizontalPadding,
                          topPadding + 12,
                          _horizontalPadding,
                          48,
                        ),
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(maxWidth: _contentMaxWidth),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // ── Hero greeting card ───────────────────────
                                _HomeHeroCard(
                                  userName: userName,
                                  profileImagePath: profile?.imagePath,
                                  isMobile: _isMobile,
                                  onProfileTap: () =>
                                      Navigator.pushNamed(context, AppRoutes.profile),
                                ),
                                const SizedBox(height: AppSpacing.md),

                                // ── Weather card ─────────────────────────────
                                _HomeGlassPanel(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      if (_isWeatherLoading)
                                        const Align(
                                          alignment: Alignment.centerRight,
                                          child: Padding(
                                            padding: EdgeInsets.only(bottom: 8),
                                            child: SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            ),
                                          ),
                                        ),
                                      // Tap the card to manually refresh weather.
                                      GestureDetector(
                                        onTap: _isWeatherLoading ? null : _loadWeather,
                                        child: WeatherCard(
                                          temperature: _temperatureText,
                                          location: _locationLabel,
                                          condition: _conditionText,
                                          tip: _tipText,
                                          weatherIcon: _weatherIcon,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: AppSpacing.lg),

                                // ── Quick actions grid ───────────────────────
                                const _HomeSectionHeader(
                                  title: 'Quick Actions',
                                  subtitle: 'Everything you need for today in one place',
                                ),
                                const SizedBox(height: AppSpacing.sm),
                                _HomeGlassPanel(
                                  padding: const EdgeInsets.all(AppSpacing.sm + 4),
                                  child: GridView.builder(
                                    shrinkWrap: true,
                                    physics: const NeverScrollableScrollPhysics(),
                                    itemCount: _actions.length,
                                    gridDelegate:
                                        SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: _gridCrossAxisCount.toInt(),
                                      mainAxisSpacing: _gridSpacing,
                                      crossAxisSpacing: _gridSpacing,
                                      childAspectRatio: _gridChildAspectRatio,
                                    ),
                                    itemBuilder: (context, i) {
                                      final action = _actions[i];
                                      return QuickActionCard(
                                        icon: action.icon,
                                        title: action.title,
                                        subtitle: action.subtitle,
                                        onTap: () => _openActionRoute(action.route),
                                      );
                                    },
                                  ),
                                ),
                                const SizedBox(height: AppSpacing.lg),

                                // ── AI outfit suggestions ────────────────────
                                _HomeSectionHeader(
                                  title: 'AI Suggestion',
                                  subtitle: _suggestionsTip,
                                  trailing: TextButton.icon(
                                    onPressed: _liveSuggestions.length < 2
                                        ? null
                                        : () => _openTryOnWithOutfit(
                                            title: 'AI Suggestion',
                                            items: _liveSuggestions,
                                          ),
                                    icon: const Icon(
                                      Icons.face_retouching_natural_rounded,
                                      size: 16,
                                    ),
                                    label: const Text('Try Full Outfit'),
                                  ),
                                ),
                                const SizedBox(height: AppSpacing.sm),
                                _HomeGlassPanel(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      _AudienceSelector(
                                        selectedIndex: _selectedAudience,
                                        onSelect: _onAudienceSelected,
                                      ),
                                      const SizedBox(height: AppSpacing.xs),
                                      TextButton.icon(
                                        onPressed: _openFullOutfitSuggestion,
                                        icon: const Icon(
                                          Icons.auto_awesome_rounded,
                                          size: 16,
                                        ),
                                        label: const Text(
                                          'Open Full Outfit Suggestion',
                                        ),
                                      ),
                                      const SizedBox(height: AppSpacing.sm),
                                      _buildSuggestionStrip(
                                        items: _liveSuggestions,
                                        emptyMessage:
                                            _suggestionsError ??
                                            'No suggestions available right now.',
                                        isLoading: _isSuggestionsLoading,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: AppSpacing.lg - 2),

                                // ── Saved outfit preview ─────────────────────
                                _HomeSectionHeader(
                                  title: _savedOutfitTitle,
                                  subtitle: 'Latest saved look from your wardrobe',
                                  trailing: TextButton.icon(
                                    onPressed: _savedSuggestions.length < 2
                                        ? null
                                        : () => _openTryOnWithOutfit(
                                            title: _savedOutfitTitle,
                                            items: _savedSuggestions,
                                          ),
                                    icon: const Icon(
                                      Icons.face_retouching_natural_rounded,
                                      size: 16,
                                    ),
                                    label: const Text('Try Full Outfit'),
                                  ),
                                ),
                                const SizedBox(height: AppSpacing.sm),
                                _HomeGlassPanel(
                                  child: _buildSuggestionStrip(
                                    items: _savedSuggestions,
                                    emptyMessage: 'No saved outfit items yet.',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // ── Floating action button (fashion chatbot) ───────────
          Positioned(
            right: AppSpacing.md,
            bottom: AppSpacing.md,
            child: SafeArea(
              top: false,
              child: FloatingActionButton(
                heroTag: 'home_chat_fab',
                onPressed: () =>
                    Navigator.pushNamed(context, AppRoutes.fashionChatbot),
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                child: const Icon(Icons.chat_bubble_rounded),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: const AppBottomNavBar(currentIndex: 0),
    );
  }
}

// ── Background decoration ─────────────────────────────────────────────────────

/// Renders non-interactive decorative blobs and a gradient behind the main content.
class _HomeBackgroundDecor extends StatelessWidget {
  const _HomeBackgroundDecor();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        children: [
          // Full-screen gradient from background to a soft primary tint.
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    AppColors.background,
                    AppColors.primarySoft.withValues(alpha: 0.35),
                  ],
                ),
              ),
            ),
          ),
          // Top-left accent blob
          Positioned(
            top: -140,
            left: -95,
            child: Container(
              width: 280,
              height: 280,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primary.withValues(alpha: 0.1),
              ),
            ),
          ),
          // Top-right accent blob
          Positioned(
            top: 170,
            right: -110,
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primarySoft.withValues(alpha: 0.7),
              ),
            ),
          ),
          // Bottom-left accent blob
          Positioned(
            bottom: -90,
            left: -50,
            child: Container(
              width: 190,
              height: 190,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primaryLight.withValues(alpha: 0.13),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Glass panel ───────────────────────────────────────────────────────────────

/// A frosted-glass-style container used to group content sections.
class _HomeGlassPanel extends StatelessWidget {
  const _HomeGlassPanel({
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.md),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.93),
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(
          color: AppColors.border.withValues(alpha: 0.9),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: child,
    );
  }
}

// ── Hero greeting card ────────────────────────────────────────────────────────

/// Gradient card shown at the top of the screen that greets the user by name
/// and displays their profile avatar. Tapping navigates to the profile screen.
class _HomeHeroCard extends StatelessWidget {
  const _HomeHeroCard({
    required this.userName,
    required this.profileImagePath,
    required this.isMobile,
    required this.onProfileTap,
  });

  final String userName;
  final String? profileImagePath;
  final bool isMobile;
  final VoidCallback onProfileTap;

  @override
  Widget build(BuildContext context) {
    final avatarSize = isMobile ? 68.0 : 76.0;
    final greeting = _greetingForHour(DateTime.now().toLocal().hour);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onProfileTap,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        child: Ink(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md + 2,
          ),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFFB57A67),
                Color(0xFF8A5646),
                Color(0xFF643B31),
              ],
            ),
            borderRadius: BorderRadius.circular(AppRadius.xl),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.24),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.16),
                blurRadius: 24,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Stack(
            children: [
              // Decorative circles inside the card for depth
              Positioned(
                top: -60,
                right: -45,
                child: Container(
                  width: 145,
                  height: 145,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              Positioned(
                bottom: -55,
                left: -30,
                child: Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '$greeting,',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: isMobile ? 13 : 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.white.withValues(alpha: 0.9),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          userName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                            height: 1.08,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  // Circular avatar with a white border ring
                  Container(
                    width: avatarSize,
                    height: avatarSize,
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.2),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.65),
                        width: 2,
                      ),
                    ),
                    child: ClipOval(
                      child: (profileImagePath != null &&
                              profileImagePath!.isNotEmpty)
                          ? Image.network(
                              profileImagePath!,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => _fallbackAvatar(),
                            )
                          : _fallbackAvatar(),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Placeholder shown when the profile image is missing or fails to load.
  Widget _fallbackAvatar() {
    return Container(
      color: Colors.white.withValues(alpha: 0.18),
      alignment: Alignment.center,
      child: const Icon(Icons.person_rounded, color: Colors.white, size: 28),
    );
  }

  /// Returns a time-of-day greeting for the given [hour] (0–23).
  String _greetingForHour(int hour) {
    if (hour < 5) return 'Good Night';
    if (hour < 12) return 'Good Morning';
    if (hour < 17) return 'Good Afternoon';
    if (hour < 21) return 'Good Evening';
    return 'Good Night';
  }
}

// ── Section header ────────────────────────────────────────────────────────────

/// A labelled section divider with an accent bar, a title, a subtitle,
/// and an optional trailing widget (e.g. a "See all" button).
class _HomeSectionHeader extends StatelessWidget {
  const _HomeSectionHeader({
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Vertical accent bar
        Container(
          width: 4,
          height: 34,
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(AppRadius.full),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: AppSpacing.sm),
          trailing!,
        ],
      ],
    );
  }
}

// ── Data models ───────────────────────────────────────────────────────────────

/// Represents a tappable quick-action tile (icon, label, route).
class _QuickAction {
  final IconData icon;
  final String title;
  final String subtitle;
  final String route;
  const _QuickAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.route,
  });
}

/// A resolved clothing item ready to display in a suggestion strip.
/// [imageBytes] takes priority over [imagePath]; [emoji] is the fallback.
class _SuggestionItem {
  final String name;
  final String category;
  final String? imagePath;
  final Uint8List? imageBytes;
  final String? emoji;
  const _SuggestionItem({
    required this.name,
    required this.category,
    this.imagePath,
    this.imageBytes,
    this.emoji,
  });
}

/// A template used to drive clothing image searches before images are fetched.
class _SuggestionSeed {
  final String searchName; // query passed to the image API
  final String type;       // clothing type hint for the API
  final String label;      // display name shown to the user
  final String category;   // e.g. 'Top', 'Bottom', 'Shoes'
  final String emoji;      // fallback icon
  const _SuggestionSeed({
    required this.searchName,
    required this.type,
    required this.label,
    required this.category,
    required this.emoji,
  });
}

/// Groups a contextual tip with the list of seeds for one temperature range.
class _SuggestionPlan {
  final String tip;
  final List<_SuggestionSeed> items;
  const _SuggestionPlan({required this.tip, required this.items});
}

// ── Audience selector ─────────────────────────────────────────────────────────

/// A pill-shaped toggle between "Men" and "Women" outfit filters.
class _AudienceSelector extends StatelessWidget {
  const _AudienceSelector({
    required this.selectedIndex,
    required this.onSelect,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    Widget option({
      required int index,
      required String label,
      required IconData icon,
    }) {
      final isSelected = selectedIndex == index;
      return Expanded(
        child: GestureDetector(
          onTap: () => onSelect(index),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.sm + 1,
            ),
            decoration: BoxDecoration(
              color: isSelected ? AppColors.primary : AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadius.full),
              border: Border.all(
                color: isSelected ? AppColors.primary : AppColors.border,
              ),
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: AppColors.primary.withValues(alpha: 0.25),
                        blurRadius: 12,
                        offset: const Offset(0, 6),
                      ),
                    ]
                  : const [],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 16,
                  color: isSelected ? Colors.white : AppColors.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: isSelected ? Colors.white : AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(AppRadius.full),
        border: Border.all(color: AppColors.border.withValues(alpha: 0.85)),
      ),
      child: Row(
        children: [
          option(index: 0, label: 'Men', icon: Icons.male_rounded),
          const SizedBox(width: AppSpacing.xs),
          option(index: 1, label: 'Women', icon: Icons.female_rounded),
        ],
      ),
    );
  }
}
