
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:internet_connection_checker/internet_connection_checker.dart';
import 'connectivity_service.dart';
import 'login_page.dart';
import 'signup_page.dart';
import 'photo_taking.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.dumpErrorToConsole(details);
  };

  try {
    await ConnectivityService.instance.start();
  } catch (e, stack) {
    debugPrint('ConnectivityService startup failed: $e');
    debugPrintStack(stackTrace: stack);
  }

  runApp(const SaveToPlantApp());
}


class SaveToPlantApp extends StatelessWidget {
  const SaveToPlantApp({super.key});

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFF7B6CF6);
    const surfaceTint = Color(0xFFF3ECFF);

    final colorScheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: Brightness.light,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Snap To Save',
      themeMode: ThemeMode.light,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colorScheme.copyWith(
          surfaceContainerLowest: surfaceTint,
        ),
        scaffoldBackgroundColor: surfaceTint,
      ),

      //home: const _WithConnectivityBanner(child: LoginPage()),
      
      home: const _WithConnectivityBanner(child: LoginPage()),

      routes: {
        '/signup': (_) =>
            const _WithConnectivityBanner(child: SignupPage()),

        // FIXED ROUTE ↓↓↓
        '/input': (context) {
          // receive the arguments passed from HomePage
          final args = ModalRoute.of(context)!.settings.arguments
              as Map<String, dynamic>?;

          final userId = args?['userId'] ?? 'unknown';

          return _WithConnectivityBanner(
            child: CaptureAndRecognizePage(
              title: 'Item Input',
              userId: userId,
            ),
          );
        },
      },
    );
  }
}

// Overlay connectivity banner wrapper (your original code)
class _WithConnectivityBanner extends StatefulWidget {
  const _WithConnectivityBanner({required this.child});
  final Widget child;

  @override
  State<_WithConnectivityBanner> createState() =>
      _WithConnectivityBannerState();
}

class _WithConnectivityBannerState
    extends State<_WithConnectivityBanner> {
  late NetworkStatus _status;
  StreamSubscription<NetworkStatus>? _sub;

  @override
  void initState() {
    super.initState();
    _status = ConnectivityService.instance.current;
    _sub = ConnectivityService.instance.stream.listen((s) {
      if (!mounted) return;
      setState(() => _status = s);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final offline = _status == NetworkStatus.offline;

    return Stack(
      children: [
        widget.child,

        if (offline)
          Align(
            alignment: Alignment.topCenter,
            child: SafeArea(
              bottom: false,
              child: Material(
                elevation: 6,
                color: Theme.of(context).colorScheme.errorContainer,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 64),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    child: Row(
                      children: [
                        const Icon(Icons.wifi_off, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            "You're offline. Connect to the internet to continue.",
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () async {
                            final ok = await InternetConnectionChecker.instance
                                .hasConnection;
                            if (!mounted) return;
                            final text =
                                ok ? 'Connection detected' : 'Still offline';
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(text),
                                behavior: SnackBarBehavior.floating,
                                duration: const Duration(seconds: 1),
                              ),
                            );
                          },
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
