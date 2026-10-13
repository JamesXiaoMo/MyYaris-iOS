import 'dart:convert';
import 'dart:typed_data';
import '../api/backend.dart';
import 'favorites_evidence.dart' show saveEvidence;

/// Read-only health acceptance, with a labelled UI-only offline simulation.
Future<void> verifyHomeOnDevice(BackendSession session) async {
  await Future<void>.delayed(const Duration(seconds: 5));
  if (session.disposed) return;
  try {
    final health = await session.api.call('GET', '/health', auth: false);
    session.health = health;
    session.backendOnline = {'ok', 'healthy'}.contains(health['status']);
  } catch (_) {
    session.backendOnline = false;
  }
  session.publish();
  await Future<void>.delayed(const Duration(milliseconds: 300));
  final proof = <String, dynamic>{
    'backend_online': session.backendOnline,
    'label': session.backendLabel,
    'health_status': session.health['status'],
    'offline_screenshot_mocked': true,
    'navigation_or_music_sent': false,
  };
  await KeychainStore.channel.invokeMethod<void>(
    'captureHome',
    'home-device.png',
  );
  final original = session.backendOnline;
  session.verificationBackendOverride = false;
  session.publish();
  await Future<void>.delayed(const Duration(milliseconds: 200));
  await KeychainStore.channel.invokeMethod<void>(
    'captureHome',
    'home-offline-device.png',
  );
  session.verificationBackendOverride = null;
  session.backendOnline = original;
  session.publish();
  await saveEvidence(
    'home-proof.json',
    Uint8List.fromList(utf8.encode(jsonEncode(proof))),
  );
}
