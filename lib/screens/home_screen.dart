import 'dart:async';
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

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeAnim;
  late final Animation<Offset> _slideAnim;
  Timer? _greetingTimer;
  final WeatherService _weatherService = WeatherService();
  final ClothingImageService _clothingImageService = ClothingImageService();
  bool _isWeatherLoading = true;
  String _temperatureText = '--';
  String _conditionText = 'Loading weather...';
  String _tipText = 'Fetching local temperature';
  IconData _weatherIcon = Icons.cloud_outlined;
  String _locationLabel = 'Cairo';
  bool _isSuggestionsLoading = true;
  String? _suggestionsError;
  String _suggestionsTip = 'Matching your weather right now';
  List<_SuggestionItem> _liveSuggestions = [];
  List<_SuggestionItem> _savedSuggestions = [];
  String _savedOutfitTitle = 'Saved Outfit';

  @override
  void initState() {
    super.initState();
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
    _startGreetingTicker();

    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _greetingTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _startGreetingTicker() {
    _greetingTimer?.cancel();
    _greetingTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted) return;
      setState(() {});
    });
  }

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
        _suggestionsError = mapped.every((item) => item.imageBytes == null)
            ? (firstApiError != null
                  ? 'Image API unavailable: $firstApiError'
                  : 'Image API unavailable. Showing fallback icons.')
            : null;
        _liveSuggestions = mapped;
      });
    } catch (e) {
      if (!mounted) return;
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

  _SuggestionPlan _suggestionPlanForTemperature(double temperatureC) {
    if (temperatureC >= 28) {
      return _SuggestionPlan(
        tip: 'Hot weather - Light clothes',
        items: const [
          _SuggestionSeed(
            searchName: 'cotton t-shirt',
            type: 'tshirt',
            label: 'T-shirt',
            category: 'Top',
            emoji: '\u{1F455}',
          ),
          _SuggestionSeed(
            searchName: 'summer shorts',
            type: 'shorts',
            label: 'Shorts',
            category: 'Bottom',
            emoji: '\u{1FA73}',
          ),
          _SuggestionSeed(
            searchName: 'summer dress',
            type: 'dress',
            label: 'Dress',
            category: 'One-piece',
            emoji: '\u{1F457}',
          ),
          _SuggestionSeed(
            searchName: 'light top',
            type: 'top',
            label: 'Top',
            category: 'Top',
            emoji: '\u{1F45A}',
          ),
        ],
      );
    }

    if (temperatureC <= 18) {
      return _SuggestionPlan(
        tip: 'Cool weather - Add warm layers',
        items: const [
          _SuggestionSeed(
            searchName: 'fleece hoodie',
            type: 'hoodie',
            label: 'Hoodie',
            category: 'Outerwear',
            emoji: '\u{1F9E5}',
          ),
          _SuggestionSeed(
            searchName: 'denim jeans',
            type: 'jeans',
            label: 'Jeans',
            category: 'Bottom',
            emoji: '\u{1F456}',
          ),
          _SuggestionSeed(
            searchName: 'light jacket',
            type: 'jacket',
            label: 'Jacket',
            category: 'Outerwear',
            emoji: '\u{1F9E5}',
          ),
          _SuggestionSeed(
            searchName: 'ankle boots',
            type: 'boots',
            label: 'Boots',
            category: 'Shoes',
            emoji: '\u{1F97E}',
          ),
        ],
      );
    }

    return _SuggestionPlan(
      tip: 'Mild weather - light layers work best',
      items: const [
        _SuggestionSeed(
          searchName: 'casual shirt',
          type: 'shirt',
          label: 'Shirt',
          category: 'Top',
          emoji: '\u{1F454}',
        ),
        _SuggestionSeed(
          searchName: 'chino pants',
          type: 'pants',
          label: 'Pants',
          category: 'Bottom',
          emoji: '\u{1F456}',
        ),
        _SuggestionSeed(
          searchName: 'cardigan sweater',
          type: 'cardigan',
          label: 'Cardigan',
          category: 'Layer',
          emoji: '\u{1F9E5}',
        ),
        _SuggestionSeed(
          searchName: 'white sneakers',
          type: 'shoes',
          label: 'Sneakers',
          category: 'Shoes',
          emoji: '\u{1F45F}',
        ),
      ],
    );
  }

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
        _temperatureText = '${temp.toStringAsFixed(0)}\u00B0C';
        _conditionText = _weatherSummaryFromCode(weather.weatherCode);
        _tipText = _weatherTip(temp);
        _weatherIcon = _weatherIconFromCode(weather.weatherCode);
        _locationLabel = locationLabel ?? 'Cairo';
        _isWeatherLoading = false;
      });
      await _loadSuggestionsForTemperature(temp);
    } catch (e) {
      if (!mounted) return;
      setState(() {
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

      final enriched = await Future.wait(
        collected.map((item) async {
          final result = await _clothingImageService.fetchClothingImage(
            name: item.name,
            type: _inferImageType(name: item.name, category: item.category),
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

  Future<void> _openFullOutfitSuggestion() async {
    await Navigator.pushNamed(
      context,
      AppRoutes.outfit,
      arguments: const {'select_full_outfit': true},
    );
    if (!mounted) return;
    await _loadSavedOutfitSuggestions();
  }

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

  String _weatherTip(double tempC) {
    if (tempC >= 28) return 'Hot day - choose light, breathable clothes';
    if (tempC <= 18) return 'Cool weather - add a layer or jacket';
    return 'Mild weather - light layers work best';
  }

  // ── Greeting helper ─────────────────────────────────────────
  String get _greeting {
    final hour = DateTime.now().toLocal().hour;
    if (hour < 5) return 'Good Night';
    if (hour < 12) return 'Good Morning';
    if (hour < 17) return 'Good Afternoon';
    if (hour < 21) return 'Good Evening';
    return 'Good Night';
  }

  // ── Responsive utilities ────────────────────────────────────
  bool get _isMobile => MediaQuery.of(context).size.width < 600;
  bool get _isTablet =>
      MediaQuery.of(context).size.width >= 600 &&
      MediaQuery.of(context).size.width < 1024;
  bool get _isDesktop => MediaQuery.of(context).size.width >= 1024;

  double get _horizontalPadding {
    if (_isDesktop) return 40;
    if (_isTablet) return 28;
    return 20;
  }

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

  double get _suggestionCardHeight {
    if (_isDesktop) return 200;
    if (_isTablet) return 190;
    return 175;
  }

  // ── Quick Action data ────────────────────────────────────────
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

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    final profile = context.watch<ProfileProvider>().profile;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SlideTransition(
        position: _slideAnim,
        child: FadeTransition(
          opacity: _fadeAnim,
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              // ── Top safe-area ──────────────────────────────────
              SliverToBoxAdapter(child: SizedBox(height: topPadding + 20)),

              // ── Header: Greeting + Avatar ─────────────────────
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: _horizontalPadding),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Left: greeting
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '$_greeting,',
                              style: TextStyle(
                                fontSize: _isMobile ? 15 : 17,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary,
                                height: 1.2,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${profile?.name}!',
                              style: TextStyle(
                                fontSize: _isMobile ? 24 : 28,
                                fontWeight: FontWeight.w800,
                                color: AppColors.textPrimary,
                                height: 1.2,
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Right: profile avatar
                      GestureDetector(
                        onTap: () =>
                            Navigator.pushNamed(context, AppRoutes.profile),
                        child: Container(
                          width: _isMobile ? 48 : 52,
                          height: _isMobile ? 48 : 52,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.primarySoft,
                            border: Border.all(
                              color: AppColors.primary.withValues(alpha: 0.20),
                              width: 2.5,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.06),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: ClipOval(
                            child: profile?.imagePath != null
                                ? Image.network(
                                    profile!.imagePath!,
                                    fit: BoxFit.cover,
                                    errorBuilder:
                                        (context, error, stackTrace) => Icon(
                                          Icons.person_rounded,
                                          color: AppColors.primary,
                                          size: _isMobile ? 24 : 28,
                                        ),
                                    loadingBuilder:
                                        (context, child, loadingProgress) {
                                          if (loadingProgress == null) {
                                            return child;
                                          }
                                          return Icon(
                                            Icons.person_rounded,
                                            color: AppColors.primary,
                                            size: _isMobile ? 24 : 28,
                                          );
                                        },
                                  )
                                : Icon(
                                    Icons.person_rounded,
                                    color: AppColors.primary,
                                    size: _isMobile ? 24 : 28,
                                  ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(child: SizedBox(height: _isMobile ? 16 : 20)),

              // ── Weather Card ───────────────────────────────────
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: _horizontalPadding),
                  child: GestureDetector(
                    onTap: _isWeatherLoading ? null : _loadWeather,
                    child: WeatherCard(
                      temperature: _temperatureText,
                      location: _locationLabel,
                      condition: _conditionText,
                      tip: _tipText,
                      weatherIcon: _weatherIcon,
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(child: SizedBox(height: _isMobile ? 20 : 28)),

              // ── Quick Actions title ────────────────────────────
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: _horizontalPadding),
                  child: Text(
                    'Quick Actions',
                    style: TextStyle(
                      fontSize: _isMobile ? 16 : 18,
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFF1C1C1C),
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(child: SizedBox(height: _isMobile ? 12 : 14)),

              // ── Responsive Quick Actions grid ──────────────────
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: _horizontalPadding),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: _gridCrossAxisCount.toInt(),
                    mainAxisSpacing: _gridSpacing,
                    crossAxisSpacing: _gridSpacing,
                    childAspectRatio: _gridChildAspectRatio,
                  ),
                  delegate: SliverChildBuilderDelegate((context, i) {
                    final action = _actions[i];
                    return QuickActionCard(
                      icon: action.icon,
                      title: action.title,
                      subtitle: action.subtitle,
                      onTap: () async {
                        await Navigator.pushNamed(context, action.route);
                        if (!mounted) return;
                        await _loadSavedOutfitSuggestions();
                      },
                    );
                  }, childCount: _actions.length),
                ),
              ),
              SliverToBoxAdapter(child: SizedBox(height: _isMobile ? 20 : 28)),

              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: _horizontalPadding),
                  child: Row(
                    children: [
                      Text(
                        'AI Suggestion',
                        style: TextStyle(
                          fontSize: _isMobile ? 16 : 18,
                          fontWeight: FontWeight.w700,
                          color: const Color(0xFF1C1C1C),
                        ),
                      ),
                      const Spacer(),
                      TextButton.icon(
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
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: _horizontalPadding),
                  child: Text(
                    _suggestionsTip,
                    style: TextStyle(
                      fontSize: _isMobile ? 12 : 13,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF8C5A2B),
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: _horizontalPadding),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _openFullOutfitSuggestion,
                      icon: const Icon(Icons.auto_awesome_rounded, size: 16),
                      label: const Text('Open Full Outfit Suggestion'),
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(child: SizedBox(height: _isMobile ? 10 : 12)),
              SliverToBoxAdapter(
                child: SizedBox(
                  height: _suggestionCardHeight,
                  child: (_isSuggestionsLoading && _liveSuggestions.isEmpty)
                      ? const Center(
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : _liveSuggestions.isEmpty
                      ? Center(
                          child: Text(
                            _suggestionsError ??
                                'No suggestions available right now.',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        )
                      : ListView.builder(
                          scrollDirection: Axis.horizontal,
                          physics: const BouncingScrollPhysics(),
                          padding: EdgeInsets.symmetric(
                            horizontal: _horizontalPadding,
                          ),
                          itemCount: _liveSuggestions.length,
                          itemBuilder: (context, i) {
                            final s = _liveSuggestions[i];
                            return SuggestionCard(
                              name: s.name,
                              category: s.category,
                              imagePath: s.imagePath,
                              imageBytes: s.imageBytes,
                              emoji: s.emoji,
                            );
                          },
                        ),
                ),
              ),
              SliverToBoxAdapter(child: SizedBox(height: _isMobile ? 14 : 16)),
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: _horizontalPadding),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _savedOutfitTitle,
                          style: TextStyle(
                            fontSize: _isMobile ? 16 : 18,
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFF1C1C1C),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton.icon(
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
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(child: SizedBox(height: _isMobile ? 10 : 12)),
              SliverToBoxAdapter(
                child: SizedBox(
                  height: _suggestionCardHeight,
                  child: _savedSuggestions.isEmpty
                      ? Center(
                          child: Text(
                            'No saved outfit items yet.',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        )
                      : ListView.builder(
                          scrollDirection: Axis.horizontal,
                          physics: const BouncingScrollPhysics(),
                          padding: EdgeInsets.symmetric(
                            horizontal: _horizontalPadding,
                          ),
                          itemCount: _savedSuggestions.length,
                          itemBuilder: (context, i) {
                            final s = _savedSuggestions[i];
                            return SuggestionCard(
                              name: s.name,
                              category: s.category,
                              imagePath: s.imagePath,
                              imageBytes: s.imageBytes,
                              emoji: s.emoji,
                            );
                          },
                        ),
                ),
              ),

              // ── Bottom padding ─────────────────────────────────
              const SliverToBoxAdapter(child: SizedBox(height: 48)),
            ],
          ),
        ),
      ),

      // ── Bottom Navigation Bar ──────────────────────────────────
      bottomNavigationBar: const AppBottomNavBar(currentIndex: 0),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// Data models
// ─────────────────────────────────────────────────────────────────

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

class _SuggestionSeed {
  final String searchName;
  final String type;
  final String label;
  final String category;
  final String emoji;
  const _SuggestionSeed({
    required this.searchName,
    required this.type,
    required this.label,
    required this.category,
    required this.emoji,
  });
}

class _SuggestionPlan {
  final String tip;
  final List<_SuggestionSeed> items;
  const _SuggestionPlan({required this.tip, required this.items});
}
