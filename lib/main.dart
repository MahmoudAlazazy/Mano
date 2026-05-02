import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mano/providers/supabase_provider.dart';
import 'package:mano/services/supabase_service.dart';
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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Supabase
  SupabaseConfig.validate();
  await SupabaseService.initialize(
    supabaseUrl: SupabaseConfig.supabaseUrl,
    supabaseKey: SupabaseConfig.supabaseAnonKey,
  );

  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor:          Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness:     Brightness.light,
    ),
  );

  runApp(const AIOutfitAdvisorApp());
}

class AIOutfitAdvisorApp extends StatefulWidget {
  const AIOutfitAdvisorApp({super.key});

  @override
  State<AIOutfitAdvisorApp> createState() => _AIOutfitAdvisorAppState();
}

class _AIOutfitAdvisorAppState extends State<AIOutfitAdvisorApp> {

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => ProfileProvider()),
        ChangeNotifierProvider(create: (_) => WardrobeProvider()),
        ChangeNotifierProvider(create: (_) => OutfitProvider()),
        ChangeNotifierProvider(create: (_) => StatsProvider()),
      ],
      child: MaterialApp(
        title:                      'AI Outfit Advisor',
        debugShowCheckedModeBanner: false,
        theme:                      AppTheme.lightTheme,
        themeMode:                  ThemeMode.light,
        initialRoute:               AppRoutes.splash,
        routes: {
          AppRoutes.splash:   (_) => const SplashScreen(),
          AppRoutes.login:    (_) => const LoginScreen(),
          AppRoutes.home:     (_) => const HomeScreen(),
          AppRoutes.upload:   (_) => const UploadScreen(),
          AppRoutes.wardrobe: (_) => const WardrobeScreen(),
          AppRoutes.outfit:   (_) => const OutfitScreen(),
          AppRoutes.tryOn:    (_) => const TryOnScreen(),
          AppRoutes.profile:  (_) => const ProfileScreen(),
          AppRoutes.register: (_) => const RegisterScreen(),
          AppRoutes.adminDashboard: (_) => const AdminDashboardScreen(),
          AppRoutes.fashionChatbot: (_) => const ChatbotScreen(),

        },
      ),
    );
  }
}


/// Central route-name registry — no magic strings anywhere.
class AppRoutes {
  AppRoutes._();
  static const String splash   = '/';
  static const String login    = '/login';
  static const String register = '/register';
  static const String home     = '/home';
  static const String upload   = '/upload';
  static const String wardrobe = '/wardrobe';
  static const String outfit   = '/outfit';
  static const String tryOn    = '/try-on';
  static const String profile  = '/profile';
  static const String adminDashboard = '/admin-dashboard';
  static const String fashionChatbot = '/fashion-chatbot';
}
