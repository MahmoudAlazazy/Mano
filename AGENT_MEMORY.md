# Agent Memory

## Current Focus
- Fix clothing recommendation image mismatches in Home AI Suggestions and Get Outfit.
- Keep gender selection meaningful: Men must produce men's clothing seeds, Women must produce women's clothing seeds.
- Avoid showing a wrong photo with a correct item name. If the API cannot find a confident match, the UI should fall back to the item's emoji/placeholder instead of a generic unrelated photo.
- Ensure every 4-piece suggestion is a wearable coordinated outfit, not four unrelated clothing ideas.

## Important Decisions
- `ClothingImageService` now ranks search results using metadata/title/source text when available, not only the image URL.
- Recommendation flows pass `allowGenericFallback: false` and a higher `minConfidenceScore` so generic Unsplash fallbacks do not create name/image mismatches.
- Get Outfit has separate women's seed outfits instead of reusing men's items with only a women's query prefix.
- Upload online image search also requires a confident match to avoid saving a wrong image into the wardrobe.
- Home and Get Outfit seeds now use coordinated palettes/materials, such as white tee + beige shorts + white sneakers + tortoise sunglasses.
- Gemini prompt now explicitly requires one cohesive 4-piece outfit structure. If Full Outfit Suggestion returns an incomplete structure, Get Outfit falls back to coordinated local seeds.

## Files Touched
- `lib/services/clothing_image_service.dart`
- `lib/screens/home_screen.dart`
- `lib/screens/outfit_screen.dart`
- `lib/services/outfit_suggestion_service.dart`
- `lib/screens/upload_screen.dart`
- `lib/screens/admin_dashboard_screen.dart`

## Next Verification
- Run `flutter analyze`.
- If analyzer passes, manually reload Home and Get Outfit, toggle Men/Women, and confirm mismatched fallback photos are gone.
- Current blocker: `flutter analyze` timed out twice because Dart analyzer processes remained running in the background. Latest observed processes were `dart` PIDs `1580` and `6132`; stopping them was not approved in the last attempt.
