import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'auth/auth_gate.dart';
import 'firebase_options_dev.dart' as dev;
import 'firebase_options_prod.dart' as prod;
import 'theme.dart';

/// Pick the Firebase project at run time:
///   flutter run -d chrome                         -> DEV (default, safe)
///   flutter run -d chrome --dart-define=ENV=prod  -> PROD (real money)
const String kEnv = String.fromEnvironment('ENV', defaultValue: 'dev');
bool get isProd => kEnv == 'prod';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: isProd
        ? prod.DefaultFirebaseOptions.currentPlatform
        : dev.DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const FitnessHubApp());
}

class FitnessHubApp extends StatelessWidget {
  const FitnessHubApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fitness Hub',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      // A visible DEV ribbon so test data is never mistaken for real data.
      builder: (context, child) => isProd
          ? child!
          : Banner(
              message: 'DEV',
              location: BannerLocation.topEnd,
              color: Brand.warn,
              child: child!,
            ),
      home: const AuthGate(),
    );
  }
}