
import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:internet_connection_checker/internet_connection_checker.dart';

/// Simple online/offline state exposed to the app.
enum NetworkStatus { online, offline }

/// Singleton that merges OS connectivity signals with a real reachability check.
class ConnectivityService {
  ConnectivityService._();
  static final ConnectivityService instance = ConnectivityService._();

  final _controller = StreamController<NetworkStatus>.broadcast();

  // NOTE: v6 emits List<ConnectivityResult>
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  StreamSubscription<InternetConnectionStatus>? _internetSub;

  NetworkStatus _current = NetworkStatus.online;

  NetworkStatus get current => _current;
  Stream<NetworkStatus> get stream => _controller.stream;

  /// Start listening; call this early (e.g., before runApp).
  Future<void> start() async {
    // Initial reachability snapshot
    final hasInternet =
    await InternetConnectionChecker.instance.hasConnection;
    _set(hasInternet ? NetworkStatus.online : NetworkStatus.offline);

    // 1) Listen to OS connectivity changes (now List<ConnectivityResult> in v6)
    _connSub = Connectivity().onConnectivityChanged.listen((results) async {
      // If the OS gives us an empty list, treat as offline; otherwise confirm with reachability.
      final osSaysConnected = results.isNotEmpty &&
          !results.every((r) => r == ConnectivityResult.none);

      if (!osSaysConnected) {
        _set(NetworkStatus.offline);
        return;
      }

      // Confirm real internet (handles captive portals / no-route cases)
      final ok =
    await InternetConnectionChecker.instance.hasConnection;
      _set(ok ? NetworkStatus.online : NetworkStatus.offline);
    });

    // 2) Also listen to reachability stream (more responsive on flaky networks)
    _internetSub =
        InternetConnectionChecker.instance.onStatusChange.listen((status) {
      final ok = status == InternetConnectionStatus.connected;
      _set(ok ? NetworkStatus.online : NetworkStatus.offline);
    });
  }

  void _set(NetworkStatus next) {
    if (_current == next) return;
    _current = next;
    _controller.add(next);
  }

  Future<void> dispose() async {
    await _connSub?.cancel();
    await _internetSub?.cancel();
    await _controller.close();
  }
}
