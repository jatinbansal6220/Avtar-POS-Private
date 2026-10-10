import 'package:flutter/material.dart';

import '../../ui/shared.dart';

// Exact built-in menu matches only. Unknown/new dishes keep a neutral icon.
// Portion labels share a dish photo without changing item IDs or prices.
const generatedDishSlugs = <String>{
  'aloo-aloo-pyaz-kulcha',
  'aloo-gobhi',
  'aloo-mutter',
  'aloo-pyaz-parantha',
  'aloo-raita',
  'banana-shake',
  'boondi-raita',
  'butter-naan',
  'butter-roti',
  'butterscotch-shake',
  'chana-masala',
  'cheese-burst-kulcha',
  'cheese-butter-masala',
  'cheese-chilly',
  'cheese-garlic-naan',
  'cheese-tomato',
  'chocolate-shake',
  'chole-bhature-2-pcs',
  'cholia-paneer-seasonal',
  'city-kulcha-spicy',
  'coffee',
  'cold-drink-mrp',
  'dal-fry',
  'dal-makhani',
  'dry-papad',
  'extra-butter',
  'extra-dahi',
  'french-fries',
  'garlic-naan',
  'gobi-kulcha',
  'gobi-parantha',
  'green-chilli-parantha',
  'green-salad',
  'gulab-jamun-per-pcs',
  'honey-chilly-potato',
  'jeera-rice',
  'karahi-paneer',
  'kitkat-shake',
  'laccha-parantha',
  'malai-kofta',
  'mango-lassi',
  'mango-shake',
  'masala-papad',
  'missi-pyaz-roti',
  'missi-roti',
  'mix-raita',
  'mix-sauce-pasta',
  'mix-veg',
  'mix-veg-pulao',
  'mushroom-chilly',
  'mushroom-do-pyaza',
  'mushroom-masala',
  'mutter-paneer',
  'namkeen-lassi',
  'onion-kulcha',
  'onion-salad',
  'oreo-shake',
  'paneer-burji',
  'paneer-do-pyaza',
  'paneer-kulcha',
  'paneer-pyaz-parantha',
  'patty-kulcha',
  'peri-peri-fries',
  'plain-naan',
  'plain-roti',
  'pyaz-roti',
  'sarson-da-saag-seasonal',
  'sev-bhaji',
  'shahi-paneer',
  'simple-thali',
  'special-dry-fruit-kheer',
  'special-hot-chocolate-coffee',
  'special-laung-elaichi-dhood-patti',
  'special-mix-kulcha',
  'special-thali',
  'spl-chur-chur-kulcha',
  'strawberry-shake',
  'stuff-naan-with-amul-butter',
  'sweet-lassi',
  'tea',
  'veg-biryani',
};

String? generatedDishImage(String name) {
  final slug = name
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'\s*\((half|full)\)\s*$'), '')
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
  return generatedDishSlugs.contains(slug)
      ? 'assets/images/menu_generated/$slug.webp'
      : null;
}

class DishPhoto extends StatelessWidget {
  final String name;
  final double width, height;
  final bool veg;
  const DishPhoto({
    super.key,
    required this.name,
    this.width = 74,
    this.height = 74,
    this.veg = true,
  });

  @override
  Widget build(BuildContext context) {
    final asset = generatedDishImage(name);
    final fallback = ColoredBox(
      color: lightIndigo,
      child: Center(
        child: Icon(
          veg ? Icons.eco_outlined : Icons.restaurant,
          color: veg ? Colors.teal : accent,
          size: 30,
        ),
      ),
    );
    return Tooltip(
      message: asset == null ? name : 'AI-generated illustration of $name',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: width,
          height: height,
          child: asset == null
              ? fallback
              : Image.asset(
                  asset,
                  fit: BoxFit.contain,
                  cacheWidth: 256,
                  cacheHeight: 256,
                  filterQuality: FilterQuality.low,
                  excludeFromSemantics: true,
                  errorBuilder: (_, _, _) => fallback,
                ),
        ),
      ),
    );
  }
}
