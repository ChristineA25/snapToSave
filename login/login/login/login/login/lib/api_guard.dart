
import 'package:flutter/material.dart';
import 'package:internet_connection_checker/internet_connection_checker.dart';

typedef OnlineTask<T> = Future<T> Function();

/// Throws when an operation requires internet but the device is offline.
class OfflineException implements Exception {
  const OfflineException();
  @override
  String toString() => 'OfflineException: No internet connection';
}

/// Ensures the device has internet before running [task].
/// If offline, it shows a short SnackBar and throws [OfflineException].
Future<T> requireOnline<T>({
  required BuildContext context,
  required OnlineTask<T> task,
  String offlineMessage = 'No internet. Please connect and try again.',
}) async {
  final hasInternet = await InternetConnectionChecker().hasConnection;
  if (!hasInternet) {
    // surface a short, consistent message
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(offlineMessage),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
    throw const OfflineException();
  }
  return await task();
}

/// Convenience helper if you need a quick check elsewhere.
Future<bool> isOnline() => InternetConnectionChecker().hasConnection;
