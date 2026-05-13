import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:outfitadvisor/providers/supabase_provider.dart';
import 'package:outfitadvisor/services/supabase_service.dart';
import 'package:provider/provider.dart';

import 'theme/app_theme.dart';

// ── All screens ───────────────────────────────────────────────────
import 'screens/splash_screen.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';
import 'screens/upload_screen.dart';
import 'screens/wardrobe_screen.dart';
import 'screens/outfit_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/register_screen.dart';
import 'screens/try_on_screen.dart';
import 'screens/admin_dashboard_screen.dart';
import 'features/chatbot/chatbot_screen.dart';

import 'config/supabase_config.dart';

/// Entry point of the application.
/// Handles all async initialization before the UI is rendered.
void main() async {
  // Ensures Flutter engine & widget binding are ready before any
  // platform channel calls (required when using async in main).
  WidgetsFlutterBinding.ensureInitialized();

  // ── Supabase Initialization ──────────────────────────────────────
  // Validate that all required Supabase config values are present,
  // then initialize the Supabase client with the project URL and anon key.
  SupabaseConfig.validate();
  await SupabaseService.initialize(
    supabaseUrl: SupabaseConfig.supabaseUrl,
    supabaseKey: SupabaseConfig.supabaseAnonKey,
  );

  // ── Orientation Lock ─────────────────────────────────────────────
  // Restrict the app to portrait mode only (up & down) to ensure a
  // consistent UI layout across all devices.
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // ── Status Bar Styling ───────────────────────────────────────────
  // Make the status bar transparent with dark icons to match the
  // app's light theme and blend with the top of the screen.
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor:          Colors.transparent, // Transparent so the app background shows through
      statusBarIconBrightness: Brightness.dark,    // Dark icons for light backgrounds
      statusBarBrightness:     Brightness.light,   // iOS-specific: light status bar background
    ),
  );

  // Launch the root widget of the application.
  runApp(const AIOutfitAdvisorApp());
}

/// Root widget of the AI Outfit Advisor application.
///
/// Declared as a [StatefulWidget] to allow future top-level state
/// management (e.g., theme switching, locale changes) without
/// restructuring the widget tree.
class AIOutfitAdvisorApp extends StatefulWidget {
  const AIOutfitAdvisorApp({super.key});

  @override
  State<AIOutfitAdvisorApp> createState() => _AIOutfitAdvisorAppState();
}

class _AIOutfitAdvisorAppState extends State<AIOutfitAdvisorApp> {

  @override
  Widget build(BuildContext context) {
    // ── State Management Setup ───────────────────────────────────────
    // Wraps the entire app in a MultiProvider so all descendant widgets
    // can access shared state via Provider without prop drilling.
    return MultiProvider(
      providers: [
        // Manages authentication state (login, logout, session).
        ChangeNotifierProvider(create: (_) => AuthProvider()),

        // Manages user profile data (name, avatar, preferences).
        ChangeNotifierProvider(create: (_) => ProfileProvider()),

        // Manages the user's wardrobe items (clothing catalog).
        ChangeNotifierProvider(create: (_) => WardrobeProvider()),

        // Manages outfit combinations and suggestions.
        ChangeNotifierProvider(create: (_) => OutfitProvider()),

        // Manages usage statistics (e.g., items worn, outfit history).
        ChangeNotifierProvider(create: (_) => StatsProvider()),
      ],
      child: MaterialApp(
        title:                      'AI Outfit Advisor',
        debugShowCheckedModeBanner: false,           // Hide the debug banner in all builds
        theme:                      AppTheme.lightTheme, // Apply the global light theme
        themeMode:                  ThemeMode.light, // Force light mode (ignores system setting)
        initialRoute:               AppRoutes.splash, // Start at the splash screen on launch

        // ── Named Route Table ──────────────────────────────────────────
        // Maps route name strings to their corresponding screen widgets.
        // Using AppRoutes constants avoids hard-coded strings throughout the codebase.
        routes: {
          AppRoutes.splash:          (_) => const SplashScreen(),          // Launch / loading screen
          AppRoutes.login:           (_) => const LoginScreen(),           // User sign-in
          AppRoutes.home:            (_) => const HomeScreen(),            // Main dashboard
          AppRoutes.upload:          (_) => const UploadScreen(),          // Add new clothing item
          AppRoutes.wardrobe:        (_) => const WardrobeScreen(),        // Browse clothing catalog
          AppRoutes.outfit:          (_) => const OutfitScreen(),          // View / manage outfits
          AppRoutes.tryOn:           (_) => const TryOnScreen(),           // Virtual try-on feature
          AppRoutes.profile:         (_) => const ProfileScreen(),         // User profile & settings
          AppRoutes.register:        (_) => const RegisterScreen(),        // New user registration
          AppRoutes.adminDashboard:  (_) => const AdminDashboardScreen(),  // Admin control panel
          AppRoutes.fashionChatbot:  (_) => const ChatbotScreen(),         // AI fashion assistant chat
        },
      ),
    );
  }
}


/// Central route-name registry.
///
/// All navigation route strings are defined here as constants,
/// ensuring a single source of truth and eliminating magic strings
/// scattered across the codebase.
class AppRoutes {
  // Private constructor prevents instantiation — this is a pure constants class.
  AppRoutes._();

  static const String splash          = '/';                  // Initial splash / loading screen
  static const String login           = '/login';             // Authentication screen
  static const String register        = '/register';          // New account registration
  static const String home            = '/home';              // Main home dashboard
  static const String upload          = '/upload';            // Upload a clothing item
  static const String wardrobe        = '/wardrobe';          // Wardrobe browsing screen
  static const String outfit          = '/outfit';            // Outfit builder / viewer
  static const String tryOn           = '/try-on';            // Virtual try-on screen
  static const String profile         = '/profile';           // User profile & settings
  static const String adminDashboard  = '/admin-dashboard';   // Admin-only dashboard
  static const String fashionChatbot  = '/fashion-chatbot';   // AI chatbot for fashion advice
}
