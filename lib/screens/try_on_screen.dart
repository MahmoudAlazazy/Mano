import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;

import '../theme/app_theme.dart';
import '../providers/supabase_provider.dart';
import '../services/supabase_service.dart';
import '../services/admin_api_service.dart';

enum _AvatarChoice { male, female }
enum _AvatarSource { preset, upload }

class _ImagePayload {
  final Uint8List bytes;
  final String mimeType;
  const _ImagePayload({required this.bytes, required this.mimeType});
}

class TryOnScreen extends StatefulWidget {
  const TryOnScreen({super.key});

  @override
  State<TryOnScreen> createState() => _TryOnScreenState();
}

class _TryOnScreenState extends State<TryOnScreen> {
  _AvatarChoice _selectedAvatar = _AvatarChoice.male;
  _AvatarSource _selectedAvatarSource = _AvatarSource.preset;
  List<Map<String, dynamic>> _selectedWardrobeItems = [];
  List<Map<String, dynamic>> _uploadedGarmentItems = [];
  bool _isGenerating = false;
  bool _hasResult = false;
  Uint8List? _resultBytes;
  String? _errorMessage;
  String _selectedFilter = 'All';
  bool _didReadRouteArgs = false;
  List<Map<String, dynamic>> _presetOutfitItems = [];
  String? _presetOutfitTitle;
  String? _generationStatus;
  XFile? _customAvatarImage;
  final AdminApiService _adminApi = AdminApiService();
  final ImagePicker _imagePicker = ImagePicker();

  static const List<String> _categories = [
    'All', 'Tops', 'Bottoms', 'Shoes', 'Jackets', 'Dresses', 'Accessories',
  ];

  bool get _isPresetOutfitMode => _presetOutfitItems.isNotEmpty;
  bool get _hasUploadedLook => _uploadedGarmentItems.isNotEmpty;
  bool get _hasCustomAvatar => _customAvatarImage != null;

  @override
  void initState() {
    super.initState();
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
    if (_didReadRouteArgs) return;
    _didReadRouteArgs = true;
    _hydratePresetOutfitFromRouteArgs();
  }

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

    if (parsed.length < 2) return;

    setState(() {
      _presetOutfitItems = parsed;
      _presetOutfitTitle = args['outfit_title']?.toString();
      _selectedWardrobeItems = [];
      _resetGeneratedPreview();
    });
  }

  void _resetGeneratedPreview() {
    _hasResult = false;
    _resultBytes = null;
    _errorMessage = null;
  }

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
      _selectedWardrobeItems = [];
      _resetGeneratedPreview();
    });
  }

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
        _resetGeneratedPreview();
      });
    } catch (e) {
      _showError('Failed to upload avatar image: $e');
    }
  }

  void _clearCustomAvatarImage() {
    setState(() {
      _customAvatarImage = null;
      _selectedAvatarSource = _AvatarSource.preset;
      _resetGeneratedPreview();
    });
  }

  void _selectAvatarSource(_AvatarSource source) {
    setState(() {
      _selectedAvatarSource = source;
      _resetGeneratedPreview();
    });
  }

  void _removeUploadedGarmentAt(int index) {
    if (index < 0 || index >= _uploadedGarmentItems.length) return;
    setState(() {
      _uploadedGarmentItems.removeAt(index);
      _resetGeneratedPreview();
    });
  }

  bool _isWardrobeItemSelected(Map<String, dynamic> item) {
    final id = item['id']?.toString();
    if (id == null || id.isEmpty) return false;
    return _selectedWardrobeItems.any((e) => e['id']?.toString() == id);
  }

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

  Future<_ImagePayload?> _loadPresetAvatarPayload(_AvatarChoice avatar) async {
    final asset = _avatarAssetPathForChoice(avatar);
    final data = await rootBundle.load(asset);
    final bytes = data.buffer.asUint8List();
    final mime = asset.endsWith('.png') ? 'image/png' : 'image/jpeg';
    return _ImagePayload(bytes: bytes, mimeType: mime);
  }

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

  Future<_ImagePayload?> _loadGarmentPayload(Map<String, dynamic> item) async {
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

  String _inferMime(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  String _displayNameFromPath(String path) {
    final normalized = path.replaceAll('\\', '/');
    final fileName = normalized.split('/').last;
    final withoutExt = fileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
    return withoutExt.replaceAll(RegExp(r'[_-]+'), ' ').trim().isEmpty
        ? 'Garment'
        : withoutExt.replaceAll(RegExp(r'[_-]+'), ' ').trim();
  }

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

  String _emojiForCategory(String category) {
    switch (category) {
      case 'Tops':
        return '\u{1F455}';
      case 'Bottoms':
        return '\u{1F456}';
      case 'Shoes':
        return '\u{1F45F}';
      case 'Jackets':
        return '\u{1F9E5}';
      case 'Dresses':
        return '\u{1F457}';
      case 'Accessories':
        return '\u{1F9E2}';
      default:
        return '\u{2728}';
    }
  }

  String _avatarAssetPathForChoice(_AvatarChoice avatar) {
    return avatar == _AvatarChoice.male
        ? 'assets/images/avatar-male.png'
        : 'assets/images/avatar-female.jpeg';
  }

  String _sanitizeFileName(String value) {
    final sanitized = value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return sanitized.isEmpty ? 'image' : sanitized;
  }

  String _extensionForMime(String mimeType) {
    final lower = mimeType.toLowerCase();
    if (lower.contains('png')) return 'png';
    if (lower.contains('webp')) return 'webp';
    if (lower.contains('gif')) return 'gif';
    if (lower.contains('bmp')) return 'bmp';
    return 'jpg';
  }

  bool _looksLikeImageBytes(Uint8List bytes) {
    if (bytes.length < 8) return false;
    const signatures = <List<int>>[
      <int>[0xFF, 0xD8, 0xFF],
      <int>[0x89, 0x50, 0x4E, 0x47],
      <int>[0x47, 0x49, 0x46, 0x38],
      <int>[0x52, 0x49, 0x46, 0x46],
      <int>[0x42, 0x4D],
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

  Uint8List? _tryDecodeBase64Image(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;

    var payload = trimmed;
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

  Future<Uint8List?> _extractGeneratedImageBytes(AdminApiResult result) async {
    if (result.bodyBytes.isNotEmpty) {
      final contentType = result.contentType?.toLowerCase() ?? '';
      if (contentType.contains('image/') ||
          _looksLikeImageBytes(result.bodyBytes)) {
        return result.bodyBytes;
      }
    }

    final seen = <String>{};
    final sources = <dynamic>[
      if (result.jsonBody != null) result.jsonBody,
      if (result.body.trim().isNotEmpty) result.body,
    ];

    for (final source in sources) {
      for (final candidate in _collectStringCandidates(source)) {
        final trimmed = candidate.trim();
        if (trimmed.isEmpty || !seen.add(trimmed)) continue;

        final inlineBytes = _tryDecodeBase64Image(trimmed);
        if (inlineBytes != null && inlineBytes.isNotEmpty) {
          return inlineBytes;
        }

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

  // ============================================================
  // NEW: بدل _runFullOutfitTryOn → API call واحد بس
  // ============================================================
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
    });

    Directory? tempDir;
    try {
      if (!mounted) return;
      setState(() => _generationStatus = 'Preparing avatar...');

      tempDir = await Directory.systemTemp.createTemp('mano_try_on_');
      final avatarPath = await _materializeAvatarFilePath(tempDir);

      if (!mounted) return;
      setState(() => _generationStatus = 'Preparing selected garments...');

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
      setState(() => _generationStatus = 'Sending images to Generate API...');

      var result = await _adminApi.generate(
        avatarPath: avatarPath,
        garmentPaths: garmentPaths,
      );

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

  // ------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final wardrobe = context.watch<WardrobeProvider>();
    final items = wardrobe.items;
    final filtered = _selectedFilter == 'All'
        ? items
        : items.where((e) => e['category'] == _selectedFilter).toList();

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          _buildHeader(context),
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
            const Text(
              'Choose Avatar',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
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

  Widget _buildCustomAvatarPicker() {
    final customAvatarPath = _customAvatarImage?.path;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
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
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  width: 68,
                  height: 68,
                  color: Colors.white,
                  child: _hasCustomAvatar && customAvatarPath != null
                      ? Image.file(
                          File(customAvatarPath),
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) {
                            return const Icon(
                              Icons.person_outline_rounded,
                              color: AppColors.primary,
                              size: 30,
                            );
                          },
                        )
                      : const Icon(
                          Icons.person_outline_rounded,
                          color: AppColors.primary,
                          size: 30,
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _hasCustomAvatar && customAvatarPath != null
                          ? _displayNameFromPath(customAvatarPath)
                          : 'No custom avatar uploaded yet',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Use a clear full-body photo for better try-on results.',
                      style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickCustomAvatarImage,
                  icon: Icon(
                    _hasCustomAvatar
                        ? Icons.autorenew_rounded
                        : Icons.file_upload_outlined,
                  ),
                  label: Text(
                    _hasCustomAvatar ? 'Change Photo' : 'Upload Photo',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              if (_hasCustomAvatar)
                TextButton(
                  onPressed: _clearCustomAvatarImage,
                  child: const Text('Use Presets'),
                ),
            ],
          ),
        ],
      ),
    );
  }

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

  Widget _buildDefaultAvatarPreview() {
    final avatarAsset = _selectedAvatar == _AvatarChoice.male
        ? 'assets/images/avatar-male.png'
        : 'assets/images/avatar-female.jpeg';
    return Image.asset(avatarAsset, fit: BoxFit.cover);
  }

  Widget _buildPreviewContent() {
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

    if (_hasResult && _resultBytes != null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.memory(_resultBytes!, fit: BoxFit.contain),
          Positioned(
            top: 12,
            right: 12,
            child: GestureDetector(
              onTap: () => setState(() {
                _hasResult = false;
                _resultBytes = null;
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

    if (_errorMessage != null) {
      return _buildErrorState(_errorMessage!);
    }

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
