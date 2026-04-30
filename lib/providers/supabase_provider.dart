// ═════════════════════════════════════════════════════════════════════════════
// OUTFIT ADVISOR - SUPABASE PROVIDERS
// ═════════════════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import 'dart:async';
import '../services/supabase_service.dart';
import '../models/user_profile.dart';

// ═════════════════════════════════════════════════════════════════════════════
// AUTH PROVIDER
// ═════════════════════════════════════════════════════════════════════════════

class AuthProvider extends ChangeNotifier {
  final _supabase = SupabaseService();

  User? _user;
  bool _isLoading = false;
  String? _error;
  DateTime? _lastAuthAttempt;
  int? _remainingWaitSeconds;
  Timer? _waitTimer;
  bool _isInitialized = false;

  User? get user => _user;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isAuthenticated => _user != null;
  bool get isInitialized => _isInitialized;

  void initializeAuthState() {
    _user = _supabase.currentUser;
    _isInitialized = true;
    notifyListeners();

    _supabase.onAuthStateChanged().listen((data) {
      _user = data.session?.user;
      _error = null;
      _isInitialized = true;
      notifyListeners();
    });
  }

  bool _canAttempt() {
    if (_remainingWaitSeconds != null && _remainingWaitSeconds! > 0) return false;
    if (_lastAuthAttempt == null) return true;
    return DateTime.now().difference(_lastAuthAttempt!).inSeconds > 45;
  }

  int get remainingWaitSeconds => _remainingWaitSeconds ?? 0;

  void clearError() {
    _error = null;
    _remainingWaitSeconds = null;
    _waitTimer?.cancel();
    notifyListeners();
  }

  void _startWaitTimer(int seconds) {
    _remainingWaitSeconds = seconds;
    notifyListeners();
    _waitTimer?.cancel();
    _waitTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_remainingWaitSeconds! <= 0) {
        _remainingWaitSeconds = null;
        timer.cancel();
        notifyListeners();
      } else {
        _remainingWaitSeconds = _remainingWaitSeconds! - 1;
        notifyListeners();
      }
    });
  }

  Future<bool> signUp({
    required String email,
    required String password,
    Map<String, dynamic>? metadata,
  }) async {
    if (_isLoading) return false;
    if (!_canAttempt()) {
      _error = _remainingWaitSeconds != null
          ? 'Wait ${_remainingWaitSeconds!}s (rate limited)'
          : 'Please wait before retrying';
      notifyListeners();
      return false;
    }
    _lastAuthAttempt = DateTime.now();
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final response = await _supabase.signUp(
        email:    email,
        password: password,
        data:     metadata,
      );
      if (response.user == null) {
        _error = "Check your email to confirm account";
        _isLoading = false;
        notifyListeners();
        return false;
      }
      _user = response.user;
      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      final msg = e.toString();
      final lowerMsg = msg.toLowerCase();
      if (lowerMsg.contains('over_email_send_rate_limit') || lowerMsg.contains('429')) {
        final secondsMatch = RegExp(r'(\d+)\s*seconds?').firstMatch(msg);
        final seconds = secondsMatch?.group(1) != null ? int.parse(secondsMatch!.group(1)!) : 45;
        _startWaitTimer(seconds);
        _error = 'Email rate limited. Wait ${seconds}s';
      } else if (lowerMsg.contains('rate') || lowerMsg.contains('too many')) {
        _startWaitTimer(45);
        _error = 'Too many attempts. Wait 45s';
      } else {
        _error = msg.replaceAll('AuthException(', '').replaceAll(')', '').trim();
      }
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> signIn({required String email, required String password}) async {
    if (_isLoading) return false;
    if (!_canAttempt()) {
      _error = _remainingWaitSeconds != null
          ? 'Wait ${_remainingWaitSeconds!}s'
          : 'Please wait before retrying';
      notifyListeners();
      return false;
    }
    _lastAuthAttempt = DateTime.now();
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final response = await _supabase.signIn(email: email, password: password);
      _user = response.user;
      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      final msg = e.toString();
      final lowerMsg = msg.toLowerCase();
      if (lowerMsg.contains('email not confirmed') ||
          lowerMsg.contains('confirm your email')) {
        _error = "Email not confirmed yet. Check inbox then login again";
      } else if (lowerMsg.contains('invalid login') ||
          lowerMsg.contains('bad requests') ||
          lowerMsg.contains('invalid')) {
        _error = "Invalid email or password";
      } else if (lowerMsg.contains('over_email_send_rate_limit') || lowerMsg.contains('429')) {
        final secondsMatch = RegExp(r'(\d+)\s*seconds?').firstMatch(msg);
        final seconds = secondsMatch?.group(1) != null ? int.parse(secondsMatch!.group(1)!) : 45;
        _startWaitTimer(seconds);
        _error = 'Rate limited. Wait ${seconds}s';
      } else if (lowerMsg.contains('rate') || lowerMsg.contains('too many')) {
        _startWaitTimer(30);
        _error = 'Too many attempts. Wait 30s';
      } else {
        _error = msg.replaceAll('AuthException(', '').replaceAll(')', '').trim();
      }
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> signOut() async {
    try {
      await _supabase.signOut();
      _user = null;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// PROFILE PROVIDER
// ═════════════════════════════════════════════════════════════════════════════

class ProfileProvider extends ChangeNotifier {
  final _supabase = SupabaseService();

  UserProfile? _profile;
  String? _profileUserId;
  bool _isLoading = false;
  String? _error;

  UserProfile? get profile => _profile;
  bool get isLoading => _isLoading;
  String? get error => _error;

  Future<void> loadProfile(String userId) async {
    _isLoading = true;
    _error = null;
    if (_profileUserId != userId) {
      // Clear stale profile when switching users
      _profile = null;
      _profileUserId = userId;
    }
    notifyListeners();
    try {
      final userData = await _supabase.getUserProfile(userId);
      if (userData != null) {
        final colors    = await _supabase.getFavoriteColors(userId);
        final occasions = await _supabase.getOccasions(userId);
        _profile = UserProfile.fromMap(userData).copyWith(
          favoriteColors: colors,
          occasions:      occasions,
        );
        _error = null;
        _profileUserId = userId;
      } else {
        _profile = null;
      }
      _isLoading = false;
      notifyListeners();
    } catch (e) {
      _error     = e.toString();
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> createProfile(String userId, UserProfile profile, String email) async {
    _isLoading = true;
    notifyListeners();
    try {
      await _supabase.createUserProfile(
        userId:           userId,
        name:             profile.name,
        email:            email,
        height:           profile.height,
        weight:           profile.weight,
        skinTone:         profile.skinTone,
        bodyType:         profile.bodyType,
        stylePersonality: profile.stylePersonality,
        favoriteColors:   profile.favoriteColors,
        occasions:        profile.occasions,
      );
      _profile = profile;
      _profileUserId = userId;
      _error   = null;
    } catch (e) {
      _error = e.toString();
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> updateProfile(String userId, UserProfile profile) async {
    _isLoading = true;
    notifyListeners();
    try {
      await _supabase.updateUserProfile(
        userId:           userId,
        name:             profile.name,
        height:           profile.height,
        weight:           profile.weight,
        skinTone:         profile.skinTone,
        bodyType:         profile.bodyType,
        stylePersonality: profile.stylePersonality,
        imagePath:        profile.imagePath,
      );
      await _supabase.setFavoriteColors(userId, profile.favoriteColors);
      await _supabase.setOccasions(userId, profile.occasions);
      _profile   = profile;
      _profileUserId = userId;
      _error     = null;
      _isLoading = false;
      notifyListeners();
    } catch (e) {
      _error     = e.toString();
      _isLoading = false;
      notifyListeners();
    }
  }

  void clear() {
    _profile = null;
    _profileUserId = null;
    _isLoading = false;
    _error = null;
    notifyListeners();
  }

  void updateName(String name) {
    if (_profile != null) {
      _profile = _profile!.copyWith(name: name);
      notifyListeners();
    }
  }

  void updateHeight(double height) {
    if (_profile != null) {
      _profile = _profile!.copyWith(height: height);
      notifyListeners();
    }
  }

  void addFavoriteColor(String color) {
    if (_profile != null) {
      final colors = List<String>.from(_profile!.favoriteColors);
      if (!colors.contains(color)) {
        colors.add(color);
        _profile = _profile!.copyWith(favoriteColors: colors);
        notifyListeners();
      }
    }
  }

  void removeFavoriteColor(String color) {
    if (_profile != null) {
      final colors = List<String>.from(_profile!.favoriteColors);
      colors.remove(color);
      _profile = _profile!.copyWith(favoriteColors: colors);
      notifyListeners();
    }
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// WARDROBE PROVIDER
// ═════════════════════════════════════════════════════════════════════════════

class WardrobeProvider extends ChangeNotifier {
  final _supabase = SupabaseService();

  List<Map<String, dynamic>> _items          = [];
  Map<String, int>           _categoryCounts = {};
  bool                       _isLoading      = false;
  String?                    _error;

  List<Map<String, dynamic>> get items          => _items;
  Map<String, int>           get categoryCounts => _categoryCounts;
  bool                       get isLoading      => _isLoading;
  String?                    get error          => _error;

  // ── Load wardrobe ─────────────────────────────────────────────
  Future<void> loadWardrobe(String userId) async {
    _isLoading = true;
    notifyListeners();

    try {
      _items = await _supabase.getUserClothingItems(userId);

      _categoryCounts = {};
      for (final item in _items) {
        final category = item['category'] as String;
        _categoryCounts[category] = (_categoryCounts[category] ?? 0) + 1;
      }

      _error     = null;
      _isLoading = false;
      notifyListeners();
    } catch (e) {
      _error     = e.toString();
      _isLoading = false;
      notifyListeners();
    }
  }

  // ── Add item ──────────────────────────────────────────────────
  // FIX: rethrow the error so the UI can catch it and show the real message
  Future<void> addItem({
    required String  userId,
    required String  name,
    required String  category,
    String?          emoji,
    String?          color,
    String?          imageUrl,
    String?          imagePath,
  }) async {
    _isLoading = true;
    _error     = null;
    notifyListeners();

    try {
      await _supabase.addClothingItem(
        userId:   userId,
        name:     name,
        category: category,
        emoji:    emoji,
        color:    color,
        imageUrl:  imageUrl,
        imagePath: imagePath,
      );

      // Reload so the new item appears immediately
      await loadWardrobe(userId);

    } catch (e) {
      _error     = e.toString();
      _isLoading = false;
      notifyListeners();
      rethrow; // ← FIX: بيوصّل الـ error للـ UI عشان يعرضه
    }
  }

  // ── Delete item ───────────────────────────────────────────────
  Future<void> deleteItem(String userId, String itemId) async {
    _isLoading = true;
    notifyListeners();

    try {
      await _supabase.deleteClothingItem(itemId);
      await loadWardrobe(userId);
    } catch (e) {
      _error     = e.toString();
      _isLoading = false;
      notifyListeners();
      rethrow;
    }
  }

  // ── Toggle favorite ───────────────────────────────────────────
  Future<void> toggleFavorite(String itemId, bool currentState) async {
    try {
      await _supabase.toggleFavorite(itemId, currentState);
      final idx = _items.indexWhere((item) => item['id'] == itemId);
      if (idx != -1) {
        _items[idx]['is_favorite'] = !currentState;
        notifyListeners();
      }
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  // ── Get items by category ─────────────────────────────────────
  Future<List<Map<String, dynamic>>> getItemsByCategory(
    String userId,
    String category,
  ) async {
    try {
      return await _supabase.getUserClothingItems(
        userId,
        categoryFilter: category,
      );
    } catch (e) {
      _error = e.toString();
      return [];
    }
  }

  // ── Load recent items ─────────────────────────────────────────
  Future<void> loadRecentItems(String userId) async {
    try {
      _items = await _supabase.getRecentClothingItems(userId, limit: 10);
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// OUTFIT PROVIDER
// ═════════════════════════════════════════════════════════════════════════════

class OutfitProvider extends ChangeNotifier {
  final _supabase = SupabaseService();

  List<Map<String, dynamic>> _outfits   = [];
  bool                       _isLoading = false;
  String?                    _error;

  List<Map<String, dynamic>> get outfits   => _outfits;
  bool                       get isLoading => _isLoading;
  String?                    get error     => _error;

  Future<void> loadOutfits(String userId) async {
    _isLoading = true;
    notifyListeners();
    try {
      _outfits   = await _supabase.getUserOutfits(userId);
      _error     = null;
      _isLoading = false;
      notifyListeners();
    } catch (e) {
      _error     = e.toString();
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<String?> createOutfit({
    required String       userId,
    String?               name,
    String?               occasion,
    required List<String> clothingItemIds,
    String?               styleType,
    String?               notes,
  }) async {
    _isLoading = true;
    notifyListeners();
    try {
      final outfitId = await _supabase.createOutfit(
        userId:          userId,
        name:            name ?? 'Outfit ${DateTime.now().day}',
        occasion:        occasion,
        clothingItemIds: clothingItemIds,
        styleType:       styleType,
        notes:           notes,
      );
      await loadOutfits(userId);
      return outfitId;
    } catch (e) {
      _error     = e.toString();
      _isLoading = false;
      notifyListeners();
      return null;
    }
  }

  Future<void> deleteOutfit(String userId, String outfitId) async {
    _isLoading = true;
    notifyListeners();
    try {
      await _supabase.deleteOutfit(outfitId);
      await loadOutfits(userId);
    } catch (e) {
      _error     = e.toString();
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>?> getOutfitWithItems(String outfitId) async {
    try {
      return await _supabase.getOutfitWithItems(outfitId);
    } catch (e) {
      _error = e.toString();
      return null;
    }
  }

  Future<void> recordOutfitWear(
    String       userId,
    String       outfitId,
    List<String> clothingItemIds,
  ) async {
    try {
      for (final itemId in clothingItemIds) {
        await _supabase.recordItemWear(
          userId:         userId,
          clothingItemId: itemId,
          outfitId:       outfitId,
        );
      }
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// STATISTICS PROVIDER
// ═════════════════════════════════════════════════════════════════════════════

class StatsProvider extends ChangeNotifier {
  final _supabase = SupabaseService();

  Map<String, dynamic>?      _stats          = {};
  List<Map<String, dynamic>> _leastWornItems = [];
  bool                       _isLoading      = false;
  String?                    _error;

  Map<String, dynamic>?      get stats          => _stats;
  List<Map<String, dynamic>> get leastWornItems => _leastWornItems;
  bool                       get isLoading      => _isLoading;
  String?                    get error          => _error;

  Future<void> loadStats(String userId) async {
    _isLoading = true;
    notifyListeners();
    try {
      _stats          = await _supabase.getWardrobeStats(userId);
      _leastWornItems = await _supabase.getLeastWornItems(userId, limit: 5);
      _error          = null;
      _isLoading      = false;
      notifyListeners();
    } catch (e) {
      _error     = e.toString();
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> recordItemWear({
    required String userId,
    required String clothingItemId,
    String?         outfitId,
  }) async {
    try {
      await _supabase.recordItemWear(
        userId:         userId,
        clothingItemId: clothingItemId,
        outfitId:       outfitId,
      );
      await loadStats(userId);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }
}
