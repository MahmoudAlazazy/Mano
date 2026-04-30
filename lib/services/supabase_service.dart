// ═════════════════════════════════════════════════════════════════════════════
// OUTFIT ADVISOR - SUPABASE SERVICE FOR FLUTTER
// ═════════════════════════════════════════════════════════════════════════════

import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:io';
import 'dart:convert';

export 'package:supabase_flutter/supabase_flutter.dart'
    show
        Supabase,
        SupabaseClient,
        AuthResponse,
        User,
        Session,
        AuthState,
        PostgresChangeEvent,
        PostgresChangeFilter,
        PostgresChangeFilterType,
        RealtimeChannel,
        FileOptions;

// ═════════════════════════════════════════════════════════════════════════════
// SUPABASE SERVICE
// ═════════════════════════════════════════════════════════════════════════════

class SupabaseService {
  static final SupabaseService _instance = SupabaseService._internal();
  factory SupabaseService() => _instance;
  SupabaseService._internal();

  SupabaseClient get client => Supabase.instance.client;
  User?   get currentUser   => client.auth.currentUser;
  String? get currentUserId => client.auth.currentUser?.id;

  static Future<void> initialize({
    required String supabaseUrl,
    required String supabaseKey,
  }) async {
    await Supabase.initialize(url: supabaseUrl, anonKey: supabaseKey);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // AUTHENTICATION
  // ─────────────────────────────────────────────────────────────────────────

  Future<AuthResponse> signUp({
    required String email,
    required String password,
    Map<String, dynamic>? data,
  }) async {
    try {
      return await client.auth.signUp(
        email:    email,
        password: password,
        data:     data,
      );
    } catch (e) { rethrow; }
  }

  Future<AuthResponse> signIn({required String email, required String password}) async {
    try {
      return await client.auth.signInWithPassword(email: email, password: password);
    } catch (e) { rethrow; }
  }

  Future<void> signOut() async {
    try { await client.auth.signOut(); } catch (e) { rethrow; }
  }

  Session? getSession() => client.auth.currentSession;
  Stream<AuthState> onAuthStateChanged() => client.auth.onAuthStateChange;

  // â”€â”€ Helpers (metadata parsing) â”€â”€â”€â”€â”€â”€â”€
  double _metaDouble(dynamic value, double fallback) {
    if (value is num) return value.toDouble();
    if (value is String) {
      final parsed = double.tryParse(value);
      if (parsed != null) return parsed;
    }
    return fallback;
  }

  String _metaString(dynamic value, String fallback) {
    if (value is String && value.trim().isNotEmpty) return value.trim();
    return fallback;
  }

  List<String> _metaStringList(dynamic value, List<String> fallback) {
    if (value is List) {
      return value.map((e) => e.toString()).where((s) => s.trim().isNotEmpty).toList();
    }
    if (value is String && value.trim().isNotEmpty) {
      final trimmed = value.trim();
      if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is List) {
            return decoded.map((e) => e.toString()).where((s) => s.trim().isNotEmpty).toList();
          }
        } catch (_) {}
      }
      return trimmed
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    }
    return fallback;
  }

  /// Ensure the current user's profile exists in public.users
  Future<void> ensureUserProfileExists(String userId) async {
    final existing = await getUserProfile(userId);
    if (existing != null) return;

    final user = currentUser;
    if (user == null) return;

    final meta = user.userMetadata ?? {};
    final name = _metaString(meta['name'], user.email?.split('@').first ?? 'User');
    final height = _metaDouble(meta['height'], 170);
    final weight = _metaDouble(meta['weight'], 65);
    final skinTone = _metaString(meta['skin_tone'], 'Medium');
    final bodyType = _metaString(meta['body_type'], 'Regular');
    final stylePersonality = _metaString(meta['style_personality'], 'Classic');
    final favoriteColors = _metaStringList(meta['favorite_colors'], const []);
    final occasions = _metaStringList(meta['occasions'], const ['Casual']);

    await createUserProfile(
      userId:           userId,
      name:             name,
      email:            user.email ?? '',
      height:           height,
      weight:           weight,
      skinTone:         skinTone,
      bodyType:         bodyType,
      stylePersonality: stylePersonality,
      favoriteColors:   favoriteColors,
      occasions:        occasions,
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ─────────────────────────────────────────────────────────────────────────

  // ─────────────────────────────────────────────────────────────────────────
  // USER PROFILE OPERATIONS
  // ─────────────────────────────────────────────────────────────────────────

  /// Create user profile
  /// FIX: لا نبعت favorite_colors أو occasions في users table
  ///      هما بيتحفظوا في جداول منفصلة user_favorite_colors و user_occasions
  Future<void> createUserProfile({
    required String       userId,
    required String       name,
    required String       email,
    double                height           = 170,
    double                weight           = 65,
    String                skinTone         = 'Medium',
    String                bodyType         = 'Regular',
    String                stylePersonality = 'Classic',
    List<String>          favoriteColors   = const [],
    List<String>          occasions        = const [],
  }) async {
    try {
      // 1. Upsert user profile (بدون favorite_colors أو occasions)
      await client.from('users').upsert({
        'id':                userId,
        'name':              name,
        'email':             email,
        'height':            height,
        'weight':            weight,
        'skin_tone':         skinTone,
        'body_type':         bodyType,
        'style_personality': stylePersonality,
      }, onConflict: 'id');

      // 2. Sync favorite colors + occasions (replace all)
      await setFavoriteColors(userId, favoriteColors);
      await setOccasions(userId, occasions);
    } catch (e) {
      rethrow;
    }
  }

  /// Get user profile
  Future<Map<String, dynamic>?> getUserProfile(String userId) async {
    try {
      return await client
          .from('users')
          .select()
          .eq('id', userId)
          .single();
    } catch (e) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> getCurrentUserProfile() async {
    final userId = currentUserId;
    if (userId == null) return null;
    return getUserProfile(userId);
  }

  /// Update user profile
  Future<void> updateUserProfile({
    required String userId,
    String?         name,
    String?         imagePath,
    double?         height,
    double?         weight,
    String?         skinTone,
    String?         bodyType,
    String?         stylePersonality,
  }) async {
    try {
      final updates = <String, dynamic>{};
      if (name             != null) updates['name']              = name;
      if (imagePath        != null) updates['image_path']        = imagePath;
      if (height           != null) updates['height']            = height;
      if (weight           != null) updates['weight']            = weight;
      if (skinTone         != null) updates['skin_tone']         = skinTone;
      if (bodyType         != null) updates['body_type']         = bodyType;
      if (stylePersonality != null) updates['style_personality'] = stylePersonality;

      if (updates.isNotEmpty) {
        await client.from('users').update(updates).eq('id', userId);
      }
    } catch (e) {
      rethrow;
    }
  }

  /// Get favorite colors
  Future<List<String>> getFavoriteColors(String userId) async {
    try {

      final response = await client
          .from('user_favorite_colors')
          .select('color_name')
          .eq('user_id', userId);

      return List<String>.from(
        response.map((item) => item['color_name'] as String),
      );
    } catch (e) {
      return [];
    }
  }

  /// Set favorite colors (replace all)
  Future<void> setFavoriteColors(String userId, List<String> colors) async {
    try {
      await ensureUserProfileExists(userId);

      await client.from('user_favorite_colors').delete().eq('user_id', userId);

      if (colors.isNotEmpty) {
        await client.from('user_favorite_colors').insert(
          colors.map((color) => {
            'user_id':    userId,
            'color_name': color,
          }).toList(),
        );
      }
    } catch (e) {
      rethrow;
    }
  }

  /// Get occasions
  Future<List<String>> getOccasions(String userId) async {
    try {

      final response = await client
          .from('user_occasions')
          .select('occasion')
          .eq('user_id', userId);

      return List<String>.from(
        response.map((item) => item['occasion'] as String),
      );
    } catch (e) {
      return [];
    }
  }

  /// Set occasions (replace all)
  Future<void> setOccasions(String userId, List<String> occasions) async {
    try {
      await ensureUserProfileExists(userId);

      await client.from('user_occasions').delete().eq('user_id', userId);

      if (occasions.isNotEmpty) {
        await client.from('user_occasions').insert(
          occasions.map((occasion) => {
            'user_id':  userId,
            'occasion': occasion,
          }).toList(),
        );
      }
    } catch (e) {
      rethrow;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CLOTHING ITEMS OPERATIONS
  // ─────────────────────────────────────────────────────────────────────────

  /// Add clothing item
  Future<String> addClothingItem({
    required String userId,   // ← auth.uid()
    required String name,
    required String category,
    String?         emoji,
    String?         color,
    String?         imageUrl,
    String?         imagePath,
    String?         brand,
    String?         size,
  }) async {
    try {
      // Ensure profile exists to satisfy FK constraint
      await ensureUserProfileExists(userId);

      final response = await client.from('clothing_items').insert({
        'user_id':  userId,   // auth uid
        'name':     name,
        'category': category,
        'emoji':    emoji,
        'image_url':  imageUrl,
        'image_path': imagePath,
        'color':    color,
        'brand':    brand,
        'size':     size,
      }).select();

      return response[0]['id'] as String;
    } catch (e) {
      rethrow;
    }
  }

  /// Get all clothing items for user
  Future<List<Map<String, dynamic>>> getUserClothingItems(
    String userId, {
    String? categoryFilter,
  }) async {
    try {

      var query = client
          .from('clothing_items')
          .select()
          .eq('user_id', userId);

      if (categoryFilter != null) {
        query = query.eq('category', categoryFilter);
      }

      return await query.order('added_at', ascending: false);
    } catch (e) {
      return [];
    }
  }

  /// Get recently added items
  Future<List<Map<String, dynamic>>> getRecentClothingItems(
    String userId, {
    int limit = 5,
  }) async {
    try {

      return await client
          .from('clothing_items')
          .select()
          .eq('user_id', userId)
          .order('added_at', ascending: false)
          .limit(limit);
    } catch (e) {
      return [];
    }
  }

  /// Get favorite items
  Future<List<Map<String, dynamic>>> getFavoriteItems(String userId) async {
    try {

      return await client
          .from('clothing_items')
          .select()
          .eq('user_id', userId)
          .eq('is_favorite', true)
          .order('added_at', ascending: false);
    } catch (e) {
      return [];
    }
  }

  /// Update clothing item
  Future<void> updateClothingItem(
    String itemId, {
    String? name,
    String? category,
    String? color,
    bool?   isFavorite,
  }) async {
    try {
      final updates = <String, dynamic>{};
      if (name       != null) updates['name']        = name;
      if (category   != null) updates['category']    = category;
      if (color      != null) updates['color']       = color;
      if (isFavorite != null) updates['is_favorite'] = isFavorite;

      await client.from('clothing_items').update(updates).eq('id', itemId);
    } catch (e) {
      rethrow;
    }
  }

  Future<void> toggleFavorite(String itemId, bool currentState) async {
    try {
      await updateClothingItem(itemId, isFavorite: !currentState);
    } catch (e) {
      rethrow;
    }
  }

  Future<void> deleteClothingItem(String itemId) async {
    try {
      await client.from('clothing_items').delete().eq('id', itemId);
    } catch (e) {
      rethrow;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // OUTFITS OPERATIONS
  // ─────────────────────────────────────────────────────────────────────────

  Future<String> createOutfit({
    required String       userId,
    String?               name,
    String?               occasion,
    String?               styleType,
    String?               notes,
    required List<String> clothingItemIds,
  }) async {
    try {
      // Ensure profile exists to satisfy FK constraint
      await ensureUserProfileExists(userId);

      final outfitResponse = await client.from('saved_outfits').insert({
        'user_id':    userId,
        'name':       name,
        'occasion':   occasion,
        'style_type': styleType,
        'notes':      notes,
      }).select();

      final outfitId = outfitResponse[0]['id'] as String;

      for (int i = 0; i < clothingItemIds.length; i++) {
        await client.from('outfit_items').insert({
          'outfit_id':        outfitId,
          'clothing_item_id': clothingItemIds[i],
          'position':         i,
        });
      }

      return outfitId;
    } catch (e) {
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> getUserOutfits(String userId) async {
    try {

      return await client
          .from('saved_outfits')
          .select()
          .eq('user_id', userId)
          .order('created_at', ascending: false);
    } catch (e) {
      return [];
    }
  }

  Future<Map<String, dynamic>?> getOutfitWithItems(String outfitId) async {
    try {
      final outfit = await client
          .from('saved_outfits')
          .select()
          .eq('id', outfitId)
          .single();

      final items = await client
          .from('outfit_items')
          .select('clothing_item_id, position')
          .eq('outfit_id', outfitId)
          .order('position');

      return {...outfit, 'items': items};
    } catch (e) {
      return null;
    }
  }

  Future<void> deleteOutfit(String outfitId) async {
    try {
      await client.from('saved_outfits').delete().eq('id', outfitId);
    } catch (e) {
      rethrow;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // WEAR HISTORY OPERATIONS
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> recordItemWear({
    required String userId,
    required String clothingItemId,
    String?         outfitId,
  }) async {
    try {
      await ensureUserProfileExists(userId);

      await client.from('wear_history').insert({
        'user_id':         userId,
        'clothing_item_id': clothingItemId,
        'outfit_id':        outfitId,
        'wore_date':        DateTime.now().toIso8601String(),
      });
    } catch (e) {
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> getItemWearHistory(
    String clothingItemId, {
    int limit = 10,
  }) async {
    try {
      return await client
          .from('wear_history')
          .select()
          .eq('clothing_item_id', clothingItemId)
          .order('wore_date', ascending: false)
          .limit(limit);
    } catch (e) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> getRecentlyWornItems(
    String userId, {
    int days = 7,
  }) async {
    try {

      final sinceDate =
          DateTime.now().subtract(Duration(days: days)).toIso8601String();

      return await client
          .from('wear_history')
          .select('clothing_item_id, wore_date')
          .eq('user_id', userId)
          .gte('wore_date', sinceDate)
          .order('wore_date', ascending: false);
    } catch (e) {
      return [];
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // STATISTICS OPERATIONS
  // ─────────────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>?> getWardrobeStats(String userId) async {
    try {

      final response = await client
          .from('wardrobe_stats')
          .select()
          .eq('user_id', userId)
          .single();

      return response;
    } catch (e) {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> getLeastWornItems(
    String userId, {
    int limit = 5,
  }) async {
    try {

      return await client
          .from('clothing_items')
          .select()
          .eq('user_id', userId)
          .order('wear_count', ascending: true)
          .order('added_at',   ascending: true)
          .limit(limit);
    } catch (e) {
      return [];
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // REAL-TIME SUBSCRIPTIONS
  // ─────────────────────────────────────────────────────────────────────────

  RealtimeChannel subscribeToClothingItems(
    String userId,
    Function(List<Map<String, dynamic>>) onData,
  ) {
    return client
        .channel('clothing_items:$userId')
        .onPostgresChanges(
          event:    PostgresChangeEvent.all,
          schema:   'public',
          table:    'clothing_items',
          filter:   PostgresChangeFilter(
            type:   PostgresChangeFilterType.eq,
            column: 'user_id',
            value:  userId,
          ),
          callback: (payload) {},
        )
        .subscribe();
  }

  RealtimeChannel subscribeToOutfits(
    String userId,
    Function(List<Map<String, dynamic>>) onData,
  ) {
    return client
        .channel('saved_outfits:$userId')
        .onPostgresChanges(
          event:    PostgresChangeEvent.all,
          schema:   'public',
          table:    'saved_outfits',
          filter:   PostgresChangeFilter(
            type:   PostgresChangeFilterType.eq,
            column: 'user_id',
            value:  userId,
          ),
          callback: (payload) {},
        )
        .subscribe();
  }

  Future<void> unsubscribe(RealtimeChannel channel) async {
    await client.removeChannel(channel);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // STORAGE OPERATIONS
  // ─────────────────────────────────────────────────────────────────────────

  Future<String> uploadImage({
    required String userId,
    required String imagePath,
    required String bucket,
  }) async {
    try {
      final file     = File(imagePath);
      final fileName =
          'outfit_advisor/$userId/${DateTime.now().millisecondsSinceEpoch}.jpg';

      await client.storage.from(bucket).upload(
        fileName,
        file,
        fileOptions: const FileOptions(cacheControl: '3600', upsert: false),
      );

      return client.storage.from(bucket).getPublicUrl(fileName);
    } catch (e) {
      rethrow;
    }
  }

  Future<void> deleteImage({
    required String imagePath,
    required String bucket,
  }) async {
    try {
      await client.storage.from(bucket).remove([imagePath]);
    } catch (e) {
      rethrow;
    }
  }

  /// Upload user avatar
  Future<String?> uploadAvatar(String userId, String filePath) async {
    try {
      final file    = File(filePath);
      final fileExt = filePath.split('.').last;
      final fileName = '$userId/avatar.$fileExt';

      // امسح القديمة
      try {
        await client.storage.from('avatars')
            .remove(['$userId/avatar.jpg', '$userId/avatar.png', '$userId/avatar.jpeg']);
      } catch (_) {}

      // ارفع الجديدة
      await client.storage.from('avatars').upload(
        fileName,
        file,
        fileOptions: const FileOptions(upsert: true),
      );

      return client.storage.from('avatars').getPublicUrl(fileName);
    } catch (e) {
      rethrow;
    }
  }
}
