import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;

import '../theme/app_theme.dart';
import '../providers/supabase_provider.dart';
import '../services/supabase_service.dart';
import '../services/admin_api_service.dart';

/// Whether the avatar used for try-on is the built-in male or female preset.
enum _AvatarChoice { male, female }

/// Whether the avatar comes from a built-in preset or a user-uploaded photo.
enum _AvatarSource { preset, upload }

/// Holds the raw bytes and MIME type of an image ready to be sent to the API.
class _ImagePayload {
  final Uint8List bytes;
  final String mimeType;
  const _ImagePayload({required this.bytes, required this.mimeType});
}

/// The virtual try-on screen.
///
/// Users pick an avatar (preset or custom photo), select garments from their
/// wardrobe or by uploading images, then tap Generate to see the outfit
/// composited onto the avatar via the [AdminApiService].
class TryOnScreen extends StatefulWidget {
  const TryOnScreen({super.key});

  @override
  State<TryOnScreen> createState() => _TryOnScreenState();
}

class _TryOnScreenState extends State<TryOnScreen> {
  // ── Avatar state ──────────────────────────────────────────────
  _AvatarChoice _selectedAvatar = _AvatarChoice.male;
  _AvatarSource _selectedAvatarSource = _AvatarSource.preset;
  XFile? _customAvatarImage;
  // When true, the avatar selection card is collapsed to save screen space.
  bool _hideAvatarSelectionCard = false;

  // ── Garment / outfit state ────────────────────────────────────
  List<Map<String, dynamic>> _selectedWardrobeItems = [];
  List<Map<String, dynamic>> _uploadedGarmentItems = [];
  // Items injected via route arguments when navigating from an outfit suggestion.
  List<Map<String, dynamic>> _presetOutfitItems = [];
  String? _presetOutfitTitle;

  // ── Generation state ──────────────────────────────────────────
  bool _isGenerating = false;
  bool _isSavingResult = false;
  bool _hasResult = false;
  Uint8List? _resultBytes;
  String? _errorMessage;
  String? _generationStatus;

  // ── Wardrobe filter ───────────────────────────────────────────
  String _selectedFilter = 'All';

  // Guards against reading route arguments more than once across rebuilds.
  bool _didReadRouteArgs = false;

  final AdminApiService _adminApi = AdminApiService();
  final ImagePicker _imagePicker = ImagePicker();

  static const List<String> _categories = [
    'All', 'Tops', 'Bottoms', 'Shoes', 'Jackets', 'Dresses', 'Accessories',
  ];

  // ── Convenience getters ───────────────────────────────────────
  bool get _isPresetOutfitMode => _presetOutfitItems.isNotEmpty;
  bool get _hasUploadedLook => _uploadedGarmentItems.isNotEmpty;
  bool get _hasCustomAvatar => _customAvatarImage != null;

  @override
  void initState() {
    super.initState();
    // Load the user's wardrobe after the first frame so the widget is mounted.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final userId = SupabaseService().currentUserId;
      if (userId != null) {
        context.read<WardrobeProvider>().loadWardrobe(userId);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Route arguments are only read once; subsequent calls are no-ops.
    if (_didReadRouteArgs) return;
    _didReadRouteArgs = true;
    _hydratePresetOutfitFromRouteArgs();
  }

  /// Reads outfit items passed via [ModalRoute] arguments (e.g. from the outfit
  /// suggestion screen) and pre-populates [_presetOutfitItems].
  /// Silently ignores malformed or incomplete payloads (fewer than 2 items).
  void _hydratePresetOutfitFromRouteArgs() {
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is! Map) return;
    final rawItems = args['outfit_items'];
    if (rawItems is! List) return;

    final parsed = <Map<String, dynamic>>[];
    for (final raw in rawItems) {
      if (raw is! Map) continue;
      final name = raw['name']?.toString().trim() ?? '';
      if (name.isEmpty) continue;
      final category = raw['category']?.toString().trim() ?? 'Clothing';
      final emoji = raw['emoji']?.toString().trim();
      final imagePath = raw['image_path']?.toString().trim();

      // Accept image bytes as either Uint8List or List<int> for flexibility.
      Uint8List? imageBytes;
      final rawBytes = raw['image_bytes'];
      if (rawBytes is Uint8List && rawBytes.isNotEmpty) {
        imageBytes = rawBytes;
      } else if (rawBytes is List<int> && rawBytes.isNotEmpty) {
        imageBytes = Uint8List.fromList(rawBytes);
      }

      parsed.add({
        'name': name,
        'category': category,
        'emoji': (emoji != null && emoji.isNotEmpty) ? emoji : '✨',
        'image_path': imagePath,
        'image_bytes': imageBytes,
      });
    }

    // A valid preset outfit needs at least two pieces.
    if (parsed.length < 2) return;

    setState(() {
      _presetOutfitItems = parsed;
      _presetOutfitTitle = args['outfit_title']?.toString();
      _selectedWardrobeItems = [];
      _resetGeneratedPreview();
    });
  }

  /// Clears the last generated result and any associated error/save state.
  void _resetGeneratedPreview() {
    _hasResult = false;
    _resultBytes = null;
    _isSavingResult = false;
    _errorMessage = null;
  }

  /// Opens the image picker to select one or more garment photos from the gallery.
  /// Infers category and emoji from the file name and replaces any existing
  /// uploaded look.
  Future<void> _pickGarmentImages() async {
    final files = await _imagePicker.pickMultiImage(imageQuality: 90);
    if (!mounted || files.isEmpty) return;

    final picked = files.map((file) {
      final label = _displayNameFromPath(file.path);
      final type = _inferImageTypeForTryOn(name: label, category: '');
      final category = _categoryLabelForType(type);
      return <String, dynamic>{
        'name': label,
        'category': category,
        'emoji': _emojiForCategory(category),
        'image_path': file.path,
      };
    }).toList();

    setState(() {
      _uploadedGarmentItems = picked;
      _selectedWardrobeItems = []; // uploaded look takes priority
      _resetGeneratedPreview();
    });
  }

  /// Opens the gallery picker for the user to choose their own full-body photo
  /// as a custom avatar. Switches [_selectedAvatarSource] to [_AvatarSource.upload]
  /// and collapses the avatar card.
  Future<void> _pickCustomAvatarImage() async {
    try {
      final image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 95,
      );
      if (!mounted || image == null) return;

      setState(() {
        _selectedAvatarSource = _AvatarSource.upload;
        _customAvatarImage = image;
        _hideAvatarSelectionCard = true;
        _resetGeneratedPreview();
      });
    } catch (e) {
      _showError('Failed to upload avatar image: $e');
    }
  }

  /// Removes the custom avatar photo and reverts to the preset avatar mode.
  void _clearCustomAvatarImage() {
    setState(() {
      _customAvatarImage = null;
      _hideAvatarSelectionCard = false;
      _selectedAvatarSource = _AvatarSource.preset;
      _resetGeneratedPreview();
    });
  }

  /// Switches between preset and upload avatar sources, showing the card again
  /// when reverting to preset.
  void _selectAvatarSource(_AvatarSource source) {
    setState(() {
      _selectedAvatarSource = source;
      if (source == _AvatarSource.preset) {
        _hideAvatarSelectionCard = false;
      }
      _resetGeneratedPreview();
    });
  }

  /// Removes the uploaded garment at [index] from the picked-clothes list.
  void _removeUploadedGarmentAt(int index) {
    if (index < 0 || index >= _uploadedGarmentItems.length) return;
    setState(() {
      _uploadedGarmentItems.removeAt(index);
      _resetGeneratedPreview();
    });
  }

  /// Returns true if [item] (identified by its `id` field) is in the current
  /// wardrobe selection.
  bool _isWardrobeItemSelected(Map<String, dynamic> item) {
    final id = item['id']?.toString();
    if (id == null || id.isEmpty) return false;
    return _selectedWardrobeItems.any((e) => e['id']?.toString() == id);
  }

  /// Adds or removes [item] from [_selectedWardrobeItems].
  /// Selecting a wardrobe item also clears any currently uploaded garments,
  /// since the two modes are mutually exclusive.
  void _toggleWardrobeItem(Map<String, dynamic> item) {
    final id = item['id']?.toString();
    if (id == null || id.isEmpty) return;
    setState(() {
      if (_uploadedGarmentItems.isNotEmpty) {
        _uploadedGarmentItems = [];
      }
      final idx = _selectedWardrobeItems.indexWhere(
        (e) => e['id']?.toString() == id,
      );
      if (idx >= 0) {
        _selectedWardrobeItems.removeAt(idx);
      } else {
        _selectedWardrobeItems.add(item);
      }
      _resetGeneratedPreview();
    });
  }

  // ── Image loading helpers ─────────────────────────────────────

  /// Loads a bundled preset avatar asset and returns it as an [_ImagePayload].
  Future<_ImagePayload?> _loadPresetAvatarPayload(_AvatarChoice avatar) async {
    final asset = _avatarAssetPathForChoice(avatar);
    final data = await rootBundle.load(asset);
    final bytes = data.buffer.asUint8List();
    final mime = asset.endsWith('.png') ? 'image/png' : 'image/jpeg';
    return _ImagePayload(bytes: bytes, mimeType: mime);
  }

  /// Returns the avatar payload for whichever source is currently active
  /// (custom upload or preset asset).
  Future<_ImagePayload?> _loadSelectedAvatarPayload() async {
    if (_selectedAvatarSource == _AvatarSource.upload) {
      final path = _customAvatarImage?.path;
      if (path == null || path.isEmpty) return null;

      final file = File(path);
      if (!await file.exists()) return null;

      return _ImagePayload(
        bytes: await file.readAsBytes(),
        mimeType: _inferMime(path),
      );
    }

    return _loadPresetAvatarPayload(_selectedAvatar);
  }

  /// Loads a garment image from in-memory bytes, a remote URL, or a local file
  /// path — whichever is available on [item]. Returns null if no image can be
  /// resolved.
  Future<_ImagePayload?> _loadGarmentPayload(Map<String, dynamic> item) async {
    // Prefer in-memory bytes (fastest, no network required).
    final bytes = item['image_bytes'];
    if (bytes is Uint8List && bytes.isNotEmpty) {
      return _ImagePayload(bytes: bytes, mimeType: 'image/jpeg');
    }
    if (bytes is List<int> && bytes.isNotEmpty) {
      return _ImagePayload(
        bytes: Uint8List.fromList(bytes),
        mimeType: 'image/jpeg',
      );
    }

    final imageUrl = item['image_url'] as String?;
    final imagePath = item['image_path'] as String?;
    // Custom header required to bypass ngrok browser-warning redirects.
    const remoteHeaders = <String, String>{
      'Accept': '*/*',
      'ngrok-skip-browser-warning': 'true',
    };

    if (imageUrl != null && imageUrl.isNotEmpty) {
      final res = await http.get(Uri.parse(imageUrl), headers: remoteHeaders);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final mime = res.headers['content-type'] ?? _inferMime(imageUrl);
        return _ImagePayload(bytes: res.bodyBytes, mimeType: mime);
      }
    }
    if (imagePath != null && imagePath.isNotEmpty) {
      if (imagePath.startsWith('http')) {
        final res = await http.get(Uri.parse(imagePath), headers: remoteHeaders);
        if (res.statusCode >= 200 && res.statusCode < 300) {
          final mime = res.headers['content-type'] ?? _inferMime(imagePath);
          return _ImagePayload(bytes: res.bodyBytes, mimeType: mime);
        }
      } else {
        final file = File(imagePath);
        if (await file.exists()) {
          return _ImagePayload(
              bytes: await file.readAsBytes(), mimeType: _inferMime(imagePath));
        }
      }
    }

    return null;
  }

  // ── Classification helpers ────────────────────────────────────

  /// Infers a garment type string (e.g. `'pants'`, `'top'`) from its name and
  /// category using keyword matching. Used to assign a category label and emoji
  /// when the user picks images from the gallery.
  String _inferImageTypeForTryOn({
    required String name,
    required String category,
  }) {
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
        text.contains('joggar') ||
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

  /// Returns the MIME type for a file path based on its extension.
  /// Defaults to `image/jpeg` for unknown extensions.
  String _inferMime(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  /// Converts a file path to a human-readable display name by stripping the
  /// extension and replacing underscores/hyphens with spaces.
  String _displayNameFromPath(String path) {
    final normalized = path.replaceAll('\\', '/');
    final fileName = normalized.split('/').last;
    final withoutExt = fileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
    return withoutExt.replaceAll(RegExp(r'[_-]+'), ' ').trim().isEmpty
        ? 'Garment'
        : withoutExt.replaceAll(RegExp(r'[_-]+'), ' ').trim();
  }

  /// Maps an inferred garment type to its UI category label.
  String _categoryLabelForType(String type) {
    switch (type) {
      case 'pants':
      case 'shorts':
        return 'Bottoms';
      case 'top':
      case 'tshirt':
      case 'shirt':
        return 'Tops';
      case 'shoes':
      case 'boots':
      case 'loafers':
        return 'Shoes';
      case 'jacket':
        return 'Jackets';
      case 'dress':
        return 'Dresses';
      case 'accessory':
      case 'watch':
      case 'sunglasses':
      case 'cap':
        return 'Accessories';
      default:
        return 'Clothing';
    }
  }

  /// Returns the representative emoji for a category label.
  String _emojiForCategory(String category) {
    switch (category) {
      case 'Tops':        return '\u{1F455}';
      case 'Bottoms':     return '\u{1F456}';
      case 'Shoes':       return '\u{1F45F}';
      case 'Jackets':     return '\u{1F9E5}';
      case 'Dresses':     return '\u{1F457}';
      case 'Accessories': return '\u{1F9E2}';
      default:            return '\u{2728}';
    }
  }

  /// Returns the asset path for a preset avatar image.
  String _avatarAssetPathForChoice(_AvatarChoice avatar) {
    return avatar == _AvatarChoice.male
        ? 'assets/images/avatar-male.png'
        : 'assets/images/avatar-female.jpeg';
  }

  // ── File / byte utilities ─────────────────────────────────────

  /// Lowercases and replaces any non-alphanumeric characters with underscores,
  /// producing a safe file name for temporary files.
  String _sanitizeFileName(String value) {
    final sanitized = value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return sanitized.isEmpty ? 'image' : sanitized;
  }

  /// Maps a MIME type string to a file extension. Defaults to `'jpg'`.
  String _extensionForMime(String mimeType) {
    final lower = mimeType.toLowerCase();
    if (lower.contains('png')) return 'png';
    if (lower.contains('webp')) return 'webp';
    if (lower.contains('gif')) return 'gif';
    if (lower.contains('bmp')) return 'bmp';
    return 'jpg';
  }

  /// Checks the leading magic bytes of [bytes] against known image format
  /// signatures (JPEG, PNG, GIF, WebP, BMP) to verify the data is a valid image.
  bool _looksLikeImageBytes(Uint8List bytes) {
    if (bytes.length < 8) return false;
    const signatures = <List<int>>[
      <int>[0xFF, 0xD8, 0xFF],             // JPEG
      <int>[0x89, 0x50, 0x4E, 0x47],       // PNG
      <int>[0x47, 0x49, 0x46, 0x38],       // GIF
      <int>[0x52, 0x49, 0x46, 0x46],       // WebP (RIFF)
      <int>[0x42, 0x4D],                   // BMP
    ];
    for (final signature in signatures) {
      if (bytes.length < signature.length) continue;
      var matches = true;
      for (var i = 0; i < signature.length; i++) {
        if (bytes[i] != signature[i]) {
          matches = false;
          break;
        }
      }
      if (matches) return true;
    }
    return false;
  }

  /// Reads the magic bytes of [bytes] to determine the image format and returns
  /// the corresponding file extension. Defaults to `'jpg'` for unrecognised data.
  String _extensionFromImageBytes(Uint8List bytes) {
    if (bytes.length >= 4 &&
        bytes[0] == 0x89 && bytes[1] == 0x50 &&
        bytes[2] == 0x4E && bytes[3] == 0x47) {
      return 'png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return 'jpg';
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0x47 && bytes[1] == 0x49 &&
        bytes[2] == 0x46 && bytes[3] == 0x38) {
      return 'gif';
    }
    // WebP: RIFF header (bytes 0-3) + "WEBP" marker (bytes 8-11).
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 && bytes[1] == 0x49 &&
        bytes[2] == 0x46 && bytes[3] == 0x46 &&
        bytes[8] == 0x57 && bytes[9] == 0x45 &&
        bytes[10] == 0x42 && bytes[11] == 0x50) {
      return 'webp';
    }
    if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
      return 'bmp';
    }
    return 'jpg';
  }

  // ── Save-result helpers ───────────────────────────────────────

  /// Interprets the heterogeneous return value of [ImageGallerySaverPlus.saveFile]
  /// as a boolean success flag, handling Map, bool, and String variants.
  bool _isSaveResultSuccessful(dynamic result) {
    if (result is Map) {
      final status = result['isSuccess'] ?? result['success'];
      if (status is bool) return status;
      if (status is num) return status != 0;
      if (status is String) {
        final normalized = status.trim().toLowerCase();
        if (normalized == 'true' || normalized == '1' || normalized == 'success') {
          return true;
        }
      }
      // A non-empty file path in the result also counts as success.
      final filePath = result['filePath'] ?? result['file_path'] ?? result['path'];
      if (filePath is String && filePath.trim().isNotEmpty) return true;
      return false;
    }

    if (result is bool) return result;
    if (result is String) return result.trim().isNotEmpty;
    return false;
  }

  /// Extracts a human-readable error message from a gallery-saver result map,
  /// or returns null if no error field is present.
  String? _extractSaveError(dynamic result) {
    if (result is! Map) return null;
    final error = result['errorMessage'] ?? result['error'] ?? result['message'];
    if (error == null) return null;
    final text = error.toString().trim();
    return text.isEmpty ? null : text;
  }

  void _showSuccess(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle_outline, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message, style: const TextStyle(fontSize: 13)),
            ),
          ],
        ),
        backgroundColor: Colors.green.shade700,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  /// Writes [_resultBytes] to a uniquely-named temp file, saves it to the
  /// device photo gallery via [ImageGallerySaverPlus], then deletes the temp file.
  Future<void> _saveGeneratedImageHighQuality() async {
    if (_isSavingResult) return;

    final bytes = _resultBytes;
    if (bytes == null || bytes.isEmpty) {
      _showError('Generate an image first.');
      return;
    }

    setState(() => _isSavingResult = true);
    File? tempFile;
    try {
      final ext = _extensionFromImageBytes(bytes);
      final ts = DateTime.now().millisecondsSinceEpoch;
      // Use a timestamped name to avoid collisions in the system temp directory.
      tempFile = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}mano_try_on_$ts.$ext',
      );
      await tempFile.writeAsBytes(bytes, flush: true);

      final saveResult = await ImageGallerySaverPlus.saveFile(
        tempFile.path,
        name: 'mano_try_on_$ts',
        isReturnPathOfIOS: true,
      );

      if (_isSaveResultSuccessful(saveResult)) {
        _showSuccess('Image downloaded in high quality to your gallery.');
      } else {
        final error = _extractSaveError(saveResult);
        _showError(error ?? 'Unable to download image to gallery.');
      }
    } catch (e) {
      _showError('Unable to download image: $e');
    } finally {
      // Always clean up the temporary file regardless of success or failure.
      if (tempFile != null) {
        try {
          if (await tempFile.exists()) {
            await tempFile.delete();
          }
        } catch (_) {}
      }
      if (mounted) {
        setState(() => _isSavingResult = false);
      }
    }
  }

  // ── API response parsing ──────────────────────────────────────

  /// Attempts to decode [value] as a base64 image string (with or without a
  /// `data:image/...;base64,` prefix). Returns null if decoding fails or the
  /// result is not a valid image.
  Uint8List? _tryDecodeBase64Image(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;

    var payload = trimmed;
    // Strip the data-URI prefix if present.
    if (payload.startsWith('data:image')) {
      final commaIndex = payload.indexOf(',');
      if (commaIndex < 0 || commaIndex == payload.length - 1) return null;
      payload = payload.substring(commaIndex + 1);
    }

    try {
      final decoded = Uint8List.fromList(
        base64Decode(base64.normalize(payload)),
      );
      return _looksLikeImageBytes(decoded) ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// Writes [bytes] to a sanitised, extension-appropriate file under [tempDir]
  /// and returns the resulting file path.
  Future<String> _writeTempImageFile({
    required Directory tempDir,
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  }) async {
    final safeName = _sanitizeFileName(fileName);
    final extension = _extensionForMime(mimeType);
    final file = File(
      '${tempDir.path}${Platform.pathSeparator}$safeName.$extension',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// Loads the selected avatar payload and writes it to [tempDir], returning
  /// the local file path for the API call. Throws [StateError] if no image
  /// can be resolved.
  Future<String> _materializeAvatarFilePath(Directory tempDir) async {
    final payload = await _loadSelectedAvatarPayload();
    if (payload == null) {
      throw StateError(
        _selectedAvatarSource == _AvatarSource.upload
            ? 'Custom avatar image not found.'
            : 'Avatar image not found.',
      );
    }

    return _writeTempImageFile(
      tempDir: tempDir,
      bytes: payload.bytes,
      fileName: _selectedAvatarSource == _AvatarSource.upload
          ? 'avatar_custom'
          : 'avatar_${_selectedAvatar.name}',
      mimeType: payload.mimeType,
    );
  }

  /// Loads the garment image for [item] and writes it to [tempDir].
  /// Returns null if the image cannot be resolved (and the caller should
  /// surface an appropriate error).
  Future<String?> _materializeGarmentFilePath(
    Map<String, dynamic> item,
    Directory tempDir,
    int index,
  ) async {
    final payload = await _loadGarmentPayload(item);
    if (payload == null || payload.bytes.isEmpty) {
      return null;
    }

    final name = item['name']?.toString().trim();
    return _writeTempImageFile(
      tempDir: tempDir,
      bytes: payload.bytes,
      fileName: 'garment_${index}_${name ?? 'item'}',
      mimeType: payload.mimeType,
    );
  }

  /// Recursively yields all [String] values from a potentially nested
  /// [Map] / [Iterable] / [String] structure. Used to scan the API response
  /// body for image URLs or base64 strings without knowing the exact schema.
  Iterable<String> _collectStringCandidates(dynamic value) sync* {
    if (value is String) {
      yield value;
      return;
    }
    if (value is Map) {
      for (final entry in value.values) {
        yield* _collectStringCandidates(entry);
      }
      return;
    }
    if (value is Iterable) {
      for (final entry in value) {
        yield* _collectStringCandidates(entry);
      }
    }
  }

  /// Extracts the generated image bytes from an [AdminApiResult] by trying
  /// three strategies in order:
  /// 1. Raw bytes in the response body (when the API returns image/\* directly).
  /// 2. Inline base64 strings found anywhere in the JSON body.
  /// 3. HTTP URLs found in the JSON body (fetched and validated).
  Future<Uint8List?> _extractGeneratedImageBytes(AdminApiResult result) async {
    // Strategy 1: raw image bytes in the response body.
    if (result.bodyBytes.isNotEmpty) {
      final contentType = result.contentType?.toLowerCase() ?? '';
      if (contentType.contains('image/') ||
          _looksLikeImageBytes(result.bodyBytes)) {
        return result.bodyBytes;
      }
    }

    // Strategy 2 & 3: scan the JSON / text body for base64 strings or URLs.
    final seen = <String>{};
    final sources = <dynamic>[
      if (result.jsonBody != null) result.jsonBody,
      if (result.body.trim().isNotEmpty) result.body,
    ];

    for (final source in sources) {
      for (final candidate in _collectStringCandidates(source)) {
        final trimmed = candidate.trim();
        if (trimmed.isEmpty || !seen.add(trimmed)) continue;

        // Try base64 first (cheaper than a network request).
        final inlineBytes = _tryDecodeBase64Image(trimmed);
        if (inlineBytes != null && inlineBytes.isNotEmpty) {
          return inlineBytes;
        }

        // Fall back to fetching the URL if it looks like one.
        if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
          try {
            final response = await http.get(
              Uri.parse(trimmed),
              headers: const <String, String>{
                'Accept': '*/*',
                'ngrok-skip-browser-warning': 'true',
              },
            );
            if (response.statusCode >= 200 &&
                response.statusCode < 300 &&
                _looksLikeImageBytes(response.bodyBytes)) {
              return response.bodyBytes;
            }
          } catch (_) {}
        }
      }
    }

    return null;
  }

  // ── Generation entry point ────────────────────────────────────

  /// Routes the generate request to [_runCombinedOutfitTryOn] based on which
  /// garment source is currently active (uploaded, wardrobe, or preset outfit).
  Future<void> _onGenerateTryOn() async {
    if (_selectedAvatarSource == _AvatarSource.upload && !_hasCustomAvatar) {
      _showError(
        'Upload your avatar image first or switch back to preset avatars.',
      );
      return;
    }

    if (_hasUploadedLook) {
      await _runCombinedOutfitTryOn(
        outfitItems: _uploadedGarmentItems,
        outfitTitle: 'Uploaded Look',
        minimumPieces: 1,
      );
      return;
    }

    if (_selectedWardrobeItems.isNotEmpty) {
      await _runCombinedOutfitTryOn(
        outfitItems: _selectedWardrobeItems,
        outfitTitle: 'My Wardrobe Selection',
        minimumPieces: 1,
      );
      return;
    }

    if (_isPresetOutfitMode) {
      await _runCombinedOutfitTryOn(
        outfitItems: _presetOutfitItems,
        outfitTitle: _presetOutfitTitle ?? 'Preset Outfit',
        minimumPieces: 1,
      );
      return;
    }

    _showError('Pick clothes from this page or choose items from your wardrobe first.');
  }

  /// Core try-on pipeline: materialises all images to temp files, calls the
  /// generate API (with one automatic retry using an alternative field name),
  /// extracts the result image, and updates state.
  ///
  /// The temp directory is always deleted in the `finally` block to avoid
  /// accumulating files in the system temp folder.
  Future<void> _runCombinedOutfitTryOn({
    required List<Map<String, dynamic>> outfitItems,
    required String outfitTitle,
    required int minimumPieces,
  }) async {
    if (outfitItems.length < minimumPieces) {
      _showError(
        minimumPieces == 1
            ? 'Pick at least 1 clothing image first.'
            : 'Outfit must include $minimumPieces pieces for avatar try-on.',
      );
      return;
    }

    setState(() {
      _isGenerating = true;
      _errorMessage = null;
      _generationStatus = 'Loading avatar...';
      _hasResult = false;
      _resultBytes = null;
      _isSavingResult = false;
    });

    Directory? tempDir;
    try {
      if (!mounted) return;
      setState(() => _generationStatus = 'Preparing avatar...');

      tempDir = await Directory.systemTemp.createTemp('mano_try_on_');
      final avatarPath = await _materializeAvatarFilePath(tempDir);

      if (!mounted) return;
      setState(() => _generationStatus = 'Preparing selected garments...');

      // Write every garment to a temp file; abort if any image fails to load.
      final garmentPaths = <String>[];
      for (var i = 0; i < outfitItems.length; i++) {
        final path = await _materializeGarmentFilePath(
          outfitItems[i],
          tempDir,
          i,
        );
        if (path == null) {
          final itemName = outfitItems[i]['name']?.toString() ?? 'a garment';
          _showError('Failed to load image for $itemName.');
          return;
        }
        garmentPaths.add(path);
      }

      if (garmentPaths.length < minimumPieces) {
        _showError('No valid garment images were available for generation.');
        return;
      }

      if (!mounted) return;
      setState(() => _generationStatus = '  Generate Image...');

      // First attempt with the default field layout.
      var result = await _adminApi.generate(
        avatarPath: avatarPath,
        garmentPaths: garmentPaths,
      );

      // Retry once with an alternative field name if the first attempt failed.
      if (!result.ok) {
        if (!mounted) return;
        setState(() => _generationStatus = 'Retrying Generate API...');
        result = await _adminApi.generate(
          avatarPath: avatarPath,
          garmentPaths: garmentPaths,
          useImagesField: true,
        );
      }

      if (!result.ok) {
        final message = result.error ??
            (result.body.trim().isNotEmpty
                ? result.body
                : 'Unknown Generate API failure.');
        _showError('Generate API failed: $message');
        return;
      }

      final imageBytes = await _extractGeneratedImageBytes(result);
      if (imageBytes == null || imageBytes.isEmpty) {
        _showError('Generate API succeeded but no image was returned.');
        return;
      }

      if (!mounted) return;
      setState(() {
        _resultBytes = imageBytes;
        _hasResult = true;
        _isSavingResult = false;
        _generationStatus = '$outfitTitle applied successfully!';
      });
    } catch (e) {
      _showError('Outfit try-on failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isGenerating = false;
          _generationStatus = null;
        });
      }
      // Clean up temp files even when an error is thrown.
      if (tempDir != null) {
        try {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        } catch (_) {}
      }
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() => _errorMessage = message);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(children: [
          const Icon(Icons.error_outline, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Expanded(
              child: Text(message, style: const TextStyle(fontSize: 13))),
        ]),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final wardrobe = context.watch<WardrobeProvider>();
    final items = wardrobe.items;
    // Apply the active category filter to the wardrobe item list.
    final filtered = _selectedFilter == 'All'
        ? items
        : items.where((e) => e['category'] == _selectedFilter).toList();

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          _buildHeader(context),
          // Show either the collapsed restore action or the full avatar card.
          if (_hideAvatarSelectionCard)
            _buildAvatarCardRestoreAction()
          else
            _buildAvatarSelection(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
              children: [
                _buildPreviewBox(),
                const SizedBox(height: 24),
                _buildUploadedGarmentsSection(),
                const SizedBox(height: 12),
                if (_isPresetOutfitMode) ...[
                  _buildPresetOutfitSection(),
                  const SizedBox(height: 12),
                ],
                _buildWardrobeSection(wardrobe, filtered, items),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: _buildGenerateButton(),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
          20, MediaQuery.of(context).padding.top + 12, 20, 18),
      decoration: const BoxDecoration(color: Colors.white),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(children: [
            GestureDetector(
              onTap: () => Navigator.pop(context),
              child: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
            ),
            const SizedBox(width: 10),
            const Text('Try On',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          ]),
          const Icon(Icons.checkroom_rounded, color: AppColors.primary),
        ],
      ),
    );
  }

  /// The avatar selection card with source toggle (preset / upload) and
  /// male / female preset chips. A "Hide Details" button collapses the card
  /// once a custom avatar has been uploaded.
  Widget _buildAvatarSelection() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.grey[200]!),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'Choose Avatar',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
                const Spacer(),
                // Show "Hide Details" only when a custom avatar is ready.
                if (_selectedAvatarSource == _AvatarSource.upload &&
                    _hasCustomAvatar)
                  TextButton.icon(
                    onPressed: () {
                      setState(() {
                        _hideAvatarSelectionCard = true;
                      });
                    },
                    style: TextButton.styleFrom(
                      visualDensity:
                          const VisualDensity(horizontal: -2, vertical: -2),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                    ),
                    icon: const Icon(Icons.visibility_off_rounded, size: 16),
                    label: const Text('Hide Details'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildAvatarSourceToggle(
                  source: _AvatarSource.preset,
                  label: 'Preset Avatars',
                  icon: Icons.auto_awesome_rounded,
                ),
                _buildAvatarSourceToggle(
                  source: _AvatarSource.upload,
                  label: 'Upload My Photo',
                  icon: Icons.file_upload_outlined,
                ),
              ],
            ),
            const SizedBox(height: 14),
            // Show gender chips for preset mode, or the custom photo picker.
            if (_selectedAvatarSource == _AvatarSource.preset)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildAvatarToggle(
                    choice: _AvatarChoice.male,
                    label: 'Male',
                    icon: Icons.male,
                  ),
                  _buildAvatarToggle(
                    choice: _AvatarChoice.female,
                    label: 'Female',
                    icon: Icons.female,
                  ),
                ],
              )
            else
              _buildCustomAvatarPicker(),
          ],
        ),
      ),
    );
  }

  /// A [ChoiceChip] that toggles between [_AvatarSource.preset] and
  /// [_AvatarSource.upload].
  Widget _buildAvatarSourceToggle({
    required _AvatarSource source,
    required String label,
    required IconData icon,
  }) {
    final isSelected = _selectedAvatarSource == source;
    return ChoiceChip(
      selected: isSelected,
      onSelected: (_) => _selectAvatarSource(source),
      avatar: Icon(
        icon,
        size: 16,
        color: isSelected ? Colors.white : AppColors.primary,
      ),
      label: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: isSelected ? Colors.white : AppColors.primary,
        ),
      ),
      backgroundColor: Colors.white,
      selectedColor: AppColors.primary,
      side: BorderSide(
        color: isSelected ? AppColors.primary : Colors.grey[300]!,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    );
  }

  /// A [ChoiceChip] for selecting between the male and female preset avatars.
  Widget _buildAvatarToggle({
    required _AvatarChoice choice,
    required String label,
    required IconData icon,
  }) {
    final isSelected = _selectedAvatar == choice;
    return ChoiceChip(
      selected: isSelected,
      onSelected: (_) => setState(() {
        _selectedAvatar = choice;
        _selectedAvatarSource = _AvatarSource.preset;
        _resetGeneratedPreview();
      }),
      avatar: Icon(
        icon,
        size: 16,
        color: isSelected ? Colors.white : AppColors.primary,
      ),
      label: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: isSelected ? Colors.white : AppColors.primary,
        ),
      ),
      backgroundColor: Colors.white,
      selectedColor: AppColors.primary,
      side: BorderSide(
        color: isSelected ? AppColors.primary : Colors.grey[300]!,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    );
  }

  /// The custom avatar picker UI: shows a thumbnail preview (or a placeholder),
  /// an upload/change button, and a "Use Presets" revert link.
  Widget _buildCustomAvatarPicker() {
    final customAvatarPath = _customAvatarImage?.path;
    final hasUploadedAvatar = _hasCustomAvatar && customAvatarPath != null;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.primarySoft,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Thumbnail: shows the uploaded photo or a person placeholder.
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: 54,
                  height: 54,
                  color: Colors.white,
                  child: hasUploadedAvatar
                      ? Image.file(
                          File(customAvatarPath!),
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) {
                            return const Icon(
                              Icons.person_outline_rounded,
                              color: AppColors.primary,
                              size: 26,
                            );
                          },
                        )
                      : const Icon(
                          Icons.person_outline_rounded,
                          color: AppColors.primary,
                          size: 26,
                        ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hasUploadedAvatar
                          ? _displayNameFromPath(customAvatarPath!)
                          : 'No custom avatar uploaded yet',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (!hasUploadedAvatar) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Use a clear full-body photo for better try-on results.',
                        style: TextStyle(fontSize: 11, color: Colors.grey[700]),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickCustomAvatarImage,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    visualDensity:
                        const VisualDensity(horizontal: -2, vertical: -2),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: Icon(
                    hasUploadedAvatar
                        ? Icons.autorenew_rounded
                        : Icons.file_upload_outlined,
                  ),
                  label: Text(
                    hasUploadedAvatar ? 'Change Photo' : 'Upload Photo',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              if (hasUploadedAvatar)
                TextButton(
                  onPressed: _clearCustomAvatarImage,
                  style: TextButton.styleFrom(
                    visualDensity:
                        const VisualDensity(horizontal: -2, vertical: -2),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Use Presets'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Minimal action bar shown instead of the full avatar card when it is
  /// collapsed. Tapping restores the card.
  Widget _buildAvatarCardRestoreAction() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
      child: Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: () {
            setState(() {
              _hideAvatarSelectionCard = false;
            });
          },
          style: TextButton.styleFrom(
            visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          ),
          icon: const Icon(Icons.visibility_rounded, size: 16),
          label: const Text('Show Details'),
        ),
      ),
    );
  }

  /// "Option 1" garment section: lets the user pick photos directly from the
  /// device gallery as an alternative to selecting from their wardrobe.
  Widget _buildUploadedGarmentsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.add_photo_alternate_outlined,
                size: 18, color: AppColors.primary),
            const SizedBox(width: 6),
            const Text(
              'Option 1: Pick Clothes',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
            const Spacer(),
            if (_hasUploadedLook)
              Text(
                '${_uploadedGarmentItems.length} selected',
                style: TextStyle(fontSize: 12, color: Colors.grey[500]),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _pickGarmentImages,
                icon: const Icon(Icons.checkroom_outlined),
                label: Text(
                  _hasUploadedLook ? 'Change Clothes' : 'Pick Clothes',
                ),
              ),
            ),
            const SizedBox(width: 10),
            if (_hasUploadedLook)
              OutlinedButton(
                onPressed: () {
                  setState(() {
                    _uploadedGarmentItems = [];
                    _resetGeneratedPreview();
                  });
                },
                child: const Text('Clear'),
              ),
          ],
        ),
        const SizedBox(height: 10),
        // Empty state prompt or a horizontal scroll of selected garment cards.
        if (!_hasUploadedLook)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey[300]!),
            ),
            child: Text(
              'Pick one or more garment images from your phone and generate directly from this page.',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          )
        else
          SizedBox(
            height: 125,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _uploadedGarmentItems.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final item = _uploadedGarmentItems[index];
                return _buildItemCard(
                  item,
                  isSelected: true,
                  onTap: () {},
                  onRemove: () => _removeUploadedGarmentAt(index),
                );
              },
            ),
          ),
      ],
    );
  }

  /// The large preview card (420 px tall) that shows the avatar, a generation
  /// spinner, the result image, or an error state depending on current status.
  Widget _buildPreviewBox() {
    return Container(
      height: 420,
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.07),
              blurRadius: 16,
              offset: const Offset(0, 4)),
        ],
      ),
      clipBehavior: Clip.hardEdge,
      child: _buildPreviewContent(),
    );
  }

  /// Shows the custom avatar file if one has been uploaded, or the selected
  /// preset asset otherwise.
  Widget _buildAvatarPreviewImage() {
    final customAvatarPath = _customAvatarImage?.path;
    if (_selectedAvatarSource == _AvatarSource.upload &&
        customAvatarPath != null &&
        customAvatarPath.isNotEmpty) {
      return Image.file(
        File(customAvatarPath),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _buildDefaultAvatarPreview(),
      );
    }

    return _buildDefaultAvatarPreview();
  }

  /// Renders the bundled preset avatar asset for the currently selected gender.
  Widget _buildDefaultAvatarPreview() {
    final avatarAsset = _selectedAvatar == _AvatarChoice.male
        ? 'assets/images/avatar-male.png'
        : 'assets/images/avatar-female.jpeg';
    return Image.asset(avatarAsset, fit: BoxFit.cover);
  }

  /// Decides which content to show inside [_buildPreviewBox]:
  /// - A spinner with status text while generating.
  /// - The result image with Download HD and Try Again overlays.
  /// - An error state with a retry button.
  /// - A summary overlay showing garment counts when items are ready but not yet generated.
  /// - An empty prompt when no garments are selected.
  Widget _buildPreviewContent() {
    // Generation in progress: spinner + live status message.
    if (_isGenerating) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: AppColors.primary),
            const SizedBox(height: 16),
            Text(_generationStatus ?? 'Generating try-on with AI...',
                style: TextStyle(color: Colors.grey[600], fontSize: 14)),
            const SizedBox(height: 6),
            Text('This may take up to 30 seconds',
                style: TextStyle(color: Colors.grey[400], fontSize: 12)),
          ],
        ),
      );
    }

    // Successful result: full-screen image with download and retry overlays.
    if (_hasResult && _resultBytes != null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.memory(_resultBytes!, fit: BoxFit.contain),
          // Download HD button (top-left).
          Positioned(
            top: 12,
            left: 12,
            child: GestureDetector(
              onTap: _isSavingResult ? null : _saveGeneratedImageHighQuality,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 180),
                opacity: _isSavingResult ? 0.8 : 1,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_isSavingResult)
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      else
                        const Icon(
                          Icons.download_rounded,
                          color: Colors.white,
                          size: 14,
                        ),
                      const SizedBox(width: 5),
                      Text(
                        _isSavingResult ? 'Saving...' : 'Download HD',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // "Try again" button (top-right) to clear the result and start over.
          Positioned(
            top: 12,
            right: 12,
            child: GestureDetector(
              onTap: () => setState(() {
                _hasResult = false;
                _resultBytes = null;
                _isSavingResult = false;
              }),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(Icons.refresh, color: Colors.white, size: 14),
                    SizedBox(width: 4),
                    Text('Try again',
                        style: TextStyle(color: Colors.white, fontSize: 12)),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    }

    // Error state with a retry button.
    if (_errorMessage != null) {
      return _buildErrorState(_errorMessage!);
    }

    // Pre-generation state when a preset outfit or uploaded look is ready:
    // show the avatar with a summary banner at the bottom.
    if ((_isPresetOutfitMode || _hasUploadedLook) &&
        _selectedWardrobeItems.isEmpty) {
      final summaryText = _hasUploadedLook
          ? '${_uploadedGarmentItems.length} picked from this page'
          : '${_presetOutfitItems.length} preset pieces ready';
      final overlayIcon =
          _hasUploadedLook ? Icons.add_photo_alternate_outlined : Icons.style_rounded;

      return Stack(
        fit: StackFit.expand,
        children: [
          _buildAvatarPreviewImage(),
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.6),
                    Colors.transparent,
                  ],
                ),
              ),
              child: Row(
                children: [
                  Icon(overlayIcon, color: Colors.white, size: 16),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '$summaryText - ready for 1 try-on call',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    // No garments selected: empty prompt.
    if (_selectedWardrobeItems.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.checkroom_outlined, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 8),
            Text(
              'Pick clothes from this page\nor choose from your wardrobe',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[500], fontSize: 14),
            ),
          ],
        ),
      );
    }

    // Wardrobe items selected: show avatar with a selection count banner.
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildAvatarPreviewImage(),
        Positioned(
          bottom: 0, left: 0, right: 0,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.6),
                  Colors.transparent,
                ],
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.auto_awesome_rounded,
                    color: Colors.white, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${_selectedWardrobeItems.length} selected from wardrobe - ready for try-on',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Centred error state shown inside the preview box with a retry button
  /// that clears [_errorMessage].
  Widget _buildErrorState(String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 40),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.red[300], fontSize: 13)),
          ),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: () => setState(() => _errorMessage = null),
            icon: const Icon(Icons.refresh),
            label: const Text('Try again'),
          ),
        ],
      ),
    );
  }

  /// Displays preset outfit items passed via route arguments as a read-only
  /// summary. The user can still override with wardrobe selections below.
  Widget _buildPresetOutfitSection() {
    final title = (_presetOutfitTitle != null && _presetOutfitTitle!.isNotEmpty)
        ? _presetOutfitTitle!
        : 'Preset Outfit';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.style_rounded,
                size: 18, color: AppColors.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(title,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            Text('${_presetOutfitItems.length} pieces',
                style: TextStyle(fontSize: 12, color: Colors.grey[500])),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _presetOutfitItems.map((item) {
            final name = item['name']?.toString() ?? 'Item';
            final emoji = item['emoji']?.toString() ?? '✨';
            return Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey[300]!),
              ),
              child: Text('$emoji $name',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600)),
            );
          }).toList(),
        ),
        const SizedBox(height: 8),
        Text(
          'You can still select your own pieces from Wardrobe below.',
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
      ],
    );
  }

  /// "Option 2" wardrobe section: shows the user's wardrobe items with a
  /// category filter row. Items can be tapped to toggle their selection.
  Widget _buildWardrobeSection(
      WardrobeProvider wardrobe, List filtered, List items) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              const Icon(Icons.checkroom_outlined,
                  size: 18, color: AppColors.primary),
              const SizedBox(width: 6),
              const Text('Option 2: My Wardrobe',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15)),
              if (items.isNotEmpty) ...[
                const Spacer(),
                Text(
                    '${_selectedWardrobeItems.length} selected - ${items.length} items',
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey[500])),
              ],
            ],
          ),
        ),
        if (wardrobe.isLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: CircularProgressIndicator(
                  color: AppColors.primary, strokeWidth: 2.5),
            ),
          )
        else if (items.isEmpty)
          Container(
            height: 80,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey[300]!),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text('No items added yet',
                style: TextStyle(color: Colors.grey[400], fontSize: 13)),
          )
        else
          Column(
            children: [
              _FilterChipRow(
                filters: _categories,
                selectedFilter: _selectedFilter,
                onSelect: (f) => setState(() => _selectedFilter = f),
              ),
              const SizedBox(height: 12),
              if (filtered.isEmpty)
                Container(
                  height: 80,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey[300]!),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text('No $_selectedFilter items yet',
                      style: TextStyle(
                          color: Colors.grey[400], fontSize: 13)),
                )
              else
                SizedBox(
                  height: 125,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: filtered.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 10),
                    itemBuilder: (context, index) {
                      final item = filtered[index];
                      final isSelected = _isWardrobeItemSelected(item);
                      return _buildItemCard(
                        item,
                        isSelected: isSelected,
                        onTap: () => _toggleWardrobeItem(item),
                        // The remove button deselects an already-selected item.
                        onRemove: () {
                          if (isSelected) _toggleWardrobeItem(item);
                        },
                      );
                    },
                  ),
                ),
            ],
          ),
      ],
    );
  }

  /// A fixed-width (100 px) garment card showing a thumbnail, name, a red
  /// remove badge (top-left), and a primary-coloured check badge (top-right)
  /// when [isSelected] is true.
  Widget _buildItemCard(
    Map<String, dynamic> item, {
    required bool isSelected,
    required VoidCallback onTap,
    required VoidCallback onRemove,
  }) {
    final imageUrl = item['image_url'] as String?;
    final imagePath = item['image_path'] as String?;
    final name = item['name'] as String? ?? 'Item';
    final emoji = item['emoji'] as String? ?? 'T';

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 100,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? AppColors.primary : Colors.grey[300]!,
            width: isSelected ? 2.5 : 1.5,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.2),
                      blurRadius: 8,
                      offset: const Offset(0, 2))
                ]
              : [],
        ),
        child: Stack(
          children: [
            Column(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(10)),
                    child: _Thumb(
                        imageUrl: imageUrl,
                        imagePath: imagePath,
                        emoji: emoji),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 4, vertical: 4),
                  child: Text(name,
                      style: const TextStyle(fontSize: 10),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center),
                ),
              ],
            ),
            // Red remove badge (top-left).
            Positioned(
              top: 4, left: 4,
              child: GestureDetector(
                onTap: onRemove,
                child: Container(
                  width: 20, height: 20,
                  decoration: const BoxDecoration(
                      color: Colors.red, shape: BoxShape.circle),
                  child: const Icon(Icons.close, size: 13, color: Colors.white),
                ),
              ),
            ),
            // Primary check badge (top-right), shown only when selected.
            if (isSelected)
              Positioned(
                top: 4, right: 4,
                child: Container(
                  width: 20, height: 20,
                  decoration: const BoxDecoration(
                      color: AppColors.primary, shape: BoxShape.circle),
                  child: const Icon(Icons.check, size: 13, color: Colors.white),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The sticky bottom button that triggers generation.
  /// Its label adapts to the active garment source for clarity.
  Widget _buildGenerateButton() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border(
            top: BorderSide(
                color: Colors.grey.withValues(alpha: 0.2), width: 1)),
      ),
      child: SizedBox(
        width: double.infinity,
        height: 54,
        child: ElevatedButton(
          onPressed: _isGenerating ? null : _onGenerateTryOn,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            disabledBackgroundColor:
                AppColors.primary.withValues(alpha: 0.5),
            elevation: 0,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(30)),
          ),
          // Spinner while generating; adaptive label otherwise.
          child: _isGenerating
              ? const SizedBox(
                  width: 22, height: 22,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2.5),
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.auto_awesome_rounded,
                        color: Colors.white, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      _hasUploadedLook
                          ? 'Generate Picked Clothes'
                          : _selectedWardrobeItems.isNotEmpty
                              ? 'Generate From Wardrobe'
                              : (_isPresetOutfitMode
                                  ? 'Generate Preset Outfit'
                                  : 'Generate Try-On'),
                      style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Colors.white),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ Thumb

/// A thumbnail widget that resolves an image from a remote URL, a local file
/// path (including http-prefixed strings), or falls back to an emoji placeholder.
class _Thumb extends StatelessWidget {
  final String? imageUrl;
  final String? imagePath;
  final String emoji;

  const _Thumb(
      {required this.imageUrl,
      required this.imagePath,
      required this.emoji});

  @override
  Widget build(BuildContext context) {
    if (imageUrl != null && imageUrl!.isNotEmpty) {
      return Image.network(imageUrl!,
          width: double.infinity,
          height: double.infinity,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _emojiFallback());
    }
    if (imagePath != null && imagePath!.isNotEmpty) {
      // imagePath may be a URL string even though the field is named "path".
      if (imagePath!.startsWith('http')) {
        return Image.network(imagePath!,
            width: double.infinity,
            height: double.infinity,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => _emojiFallback());
      }
      return Image.file(File(imagePath!),
          width: double.infinity,
          height: double.infinity,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _emojiFallback());
    }
    return _emojiFallback();
  }

  /// Renders a centred emoji on a soft primary background when no image is available.
  Widget _emojiFallback() {
    return Container(
      width: double.infinity,
      height: double.infinity,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.primarySoft,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(emoji, style: const TextStyle(fontSize: 24)),
    );
  }
}

// ------------------------------------------------------------ Filter Chip Row

/// A horizontally scrollable row of animated category filter chips.
/// Selecting a chip calls [onSelect] with the chip's label.
class _FilterChipRow extends StatelessWidget {
  final List<String> filters;
  final String selectedFilter;
  final ValueChanged<String> onSelect;

  const _FilterChipRow({
    required this.filters,
    required this.selectedFilter,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: filters.length,
        itemBuilder: (context, i) {
          final filter = filters[i];
          final isSelected = filter == selectedFilter;
          return GestureDetector(
            onTap: () => onSelect(filter),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: isSelected ? AppColors.primary : Colors.white,
                borderRadius: BorderRadius.circular(30),
                border: Border.all(
                  color:
                      isSelected ? AppColors.primary : Colors.grey[300]!,
                  width: 1.5,
                ),
              ),
              child: Center(
                child: Text(
                  filter,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isSelected ? Colors.white : Colors.grey[600],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
