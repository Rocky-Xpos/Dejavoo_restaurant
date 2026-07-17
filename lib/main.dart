import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'src/models.dart';
import 'src/screens/floor_screen.dart';

/// XPOS Tableside — order-taking app for Dejavoo P-series (Android) payment
/// terminals. Connects to the XPOS register over the restaurant's Wi-Fi:
/// the floor plan and menu come from the register, and placed orders fire the
/// kitchen display and station chit printers there. Works with no internet.
///
/// Payments run in-app through DvPayLite (the Dejavoo payment app on this
/// same terminal) over the `xpos/dvpay` MethodChannel: the register issues a
/// payment intent, this app drives the SALE/VOID/STATUS, and the result is
/// persisted until the register acks it (see src/services/payment_outbox.dart).
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations(
      [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
  WakelockPlus.enable().catchError((_) {});
  runApp(const TablesideApp());
}

class TablesideApp extends StatelessWidget {
  const TablesideApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ThemeData.dark(useMaterial3: true);
    return MaterialApp(
      title: 'XPOS Tableside',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        scaffoldBackgroundColor: DColors.bg,
        colorScheme: base.colorScheme.copyWith(
          primary: DColors.primary,
          surface: DColors.surface,
        ),
      ),
      home: const FloorScreen(),
    );
  }
}
