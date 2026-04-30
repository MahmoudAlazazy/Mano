/// Represents a single clothing item in the wardrobe.
class ClothingItem {
  final String   id;
  final String   name;
  final String   category;
  final String   emoji;
  final String?  imagePath;   // local file path after upload
  final DateTime addedAt;
  final String?  color;
  final String?  brand;
  final String?  size;
  final String   condition;
  final bool     isFavorite;
  final int      wearCount;
  final DateTime? lastWornAt;

  const ClothingItem({
    required this.id,
    required this.name,
    required this.category,
    required this.emoji,
    this.imagePath,
    required this.addedAt,
    this.color,
    this.brand,
    this.size,
    this.condition = 'Good',
    this.isFavorite = false,
    this.wearCount = 0,
    this.lastWornAt,
  });

  // From DB map
  ClothingItem.fromMap(Map<String, dynamic> map)
      : id = map['id'] as String,
        name = map['name'] as String,
        category = map['category'] as String,
        emoji = map['emoji'] as String? ?? '',
        imagePath = map['image_path'] as String?,
        addedAt = DateTime.parse(map['added_at'] as String),
        color = map['color'] as String?,
        brand = map['brand'] as String?,
        size = map['size'] as String?,
        condition = map['condition'] as String? ?? 'Good',
        isFavorite = (map['is_favorite'] ?? false) as bool,
        wearCount = map['wear_count'] as int? ?? 0,
        lastWornAt = map['last_worn_at'] != null 
            ? DateTime.parse(map['last_worn_at'] as String)
            : null;

  // To DB map
  Map<String, dynamic> toMap(String userId) => {
        'id': id,
        'user_id': userId,
        'name': name,
        'category': category,
        'emoji': emoji.isEmpty ? null : emoji,
        'image_path': imagePath,
        'color': color,
        'brand': brand,
        'size': size,
        'condition': condition,
        'is_favorite': isFavorite,
        'wear_count': wearCount,
        'last_worn_at': lastWornAt?.toIso8601String(),
        'added_at': addedAt.toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      };


  // ── Category constants ────────────────────────────────────────
  static const String catTops     = 'Tops';
  static const String catBottoms  = 'Bottoms';
  static const String catShoes    = 'Shoes';
  static const String catJackets  = 'Jackets';
  static const String catDresses  = 'Dresses';
  static const String catAcc      = 'Accessories';

  static const List<String> allCategories = [
    catTops,
    catBottoms,
    catShoes,
    catJackets,
    catDresses,
    catAcc,
  ];

  // ── Sample wardrobe data ──────────────────────────────────────
  static List<ClothingItem> get sampleItems => [
    ClothingItem(id: '1',  name: 'White Shirt',     category: catTops,    emoji: '👔', addedAt: DateTime.now().subtract(const Duration(days: 1))),
    ClothingItem(id: '2',  name: 'Navy Polo',        category: catTops,    emoji: '👕', addedAt: DateTime.now().subtract(const Duration(days: 2))),
    ClothingItem(id: '3',  name: 'Beige Tank',       category: catTops,    emoji: '🎽', addedAt: DateTime.now().subtract(const Duration(days: 3))),
    ClothingItem(id: '4',  name: 'Blue Jeans',       category: catBottoms, emoji: '👖', addedAt: DateTime.now().subtract(const Duration(days: 4))),
    ClothingItem(id: '5',  name: 'Black Chinos',     category: catBottoms, emoji: '👖', addedAt: DateTime.now().subtract(const Duration(days: 5))),
    ClothingItem(id: '6',  name: 'Khaki Shorts',     category: catBottoms, emoji: '🩳', addedAt: DateTime.now().subtract(const Duration(days: 6))),
    ClothingItem(id: '7',  name: 'White Sneakers',   category: catShoes,   emoji: '👟', addedAt: DateTime.now().subtract(const Duration(days: 7))),
    ClothingItem(id: '8',  name: 'Brown Loafers',    category: catShoes,   emoji: '👞', addedAt: DateTime.now().subtract(const Duration(days: 8))),
    ClothingItem(id: '9',  name: 'Beige Blazer',     category: catJackets, emoji: '🧥', addedAt: DateTime.now().subtract(const Duration(days: 9))),
    ClothingItem(id: '10', name: 'Denim Jacket',     category: catJackets, emoji: '🧥', addedAt: DateTime.now().subtract(const Duration(days: 10))),
    ClothingItem(id: '11', name: 'Floral Dress',     category: catDresses, emoji: '👗', addedAt: DateTime.now().subtract(const Duration(days: 11))),
    ClothingItem(id: '12', name: 'Silver Watch',     category: catAcc,     emoji: '⌚', addedAt: DateTime.now().subtract(const Duration(days: 12))),
  ];

  // ── Items count per category ──────────────────────────────────
  static Map<String, int> countByCategory(List<ClothingItem> items) {
    final map = <String, int>{};
    for (final cat in allCategories) {
      map[cat] = items.where((e) => e.category == cat).length;
    }
    return map;
  }
}
