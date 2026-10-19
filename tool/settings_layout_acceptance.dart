// Read-only real UI acceptance; never sends navigation/music or account writes.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:myyaris_ios/main.dart' as app;
import 'package:myyaris_ios/glass_tab_bar.dart';
import 'package:myyaris_ios/api/pages.dart';
import 'package:myyaris_ios/api/backend.dart';
import 'package:myyaris_ios/verification/favorites_evidence.dart'
    show saveEvidence;

List<Element> elements([Element? scope]) {
  final result = <Element>[];
  void visit(Element e) {
    result.add(e);
    e.visitChildElements(visit);
  }

  final root = scope ?? WidgetsBinding.instance.rootElement;
  if (root != null) visit(root);
  return result;
}

Future<void> main() async {
  app.main();
  final proof = <String, dynamic>{
    'version': '0.5.6+24',
    'business_writes_sent': false,
    'completed': false,
  };
  try {
    await Future<void>.delayed(const Duration(seconds: 8));
    final bar =
        elements().firstWhere((e) => e.widget is GlassTabBar).widget
            as GlassTabBar;
    bar.onChanged(3);
    await Future<void>.delayed(const Duration(seconds: 1));
    final settingsElement = elements().firstWhere(
      (e) => e.widget is SettingsPage,
    );
    final settings = settingsElement.widget as SettingsPage;
    final origin = settings.session.api.baseUrl;
    final device = settings.session.api.deviceId;
    proof['root_hides_fields'] = !elements(
      settingsElement,
    ).any((e) => e.widget is TextField);
    proof['root_hides_prose'] = !elements(settingsElement).any(
      (e) =>
          e.widget is Text &&
          ((e.widget as Text).data ?? '').contains('密码不持久化'),
    );
    await KeychainStore.channel.invokeMethod<void>(
      'captureHome',
      'glass-settings-device.png',
    );
    (elements()
                .firstWhere(
                  (e) => e.widget.key == const ValueKey('settings-user-open'),
                )
                .widget
            as ListTile)
        .onTap!();
    await Future<void>.delayed(const Duration(seconds: 1));
    proof['account_menu_opened'] = elements().any(
      (e) => e.widget.key == const ValueKey('settings-account-menu'),
    );
    final texts = elements()
        .map((e) => e.widget)
        .whereType<Text>()
        .map((w) => w.data)
        .toList();
    proof['account_actions_present'] = [
      '修改昵称',
      '刷新个人资料/权限',
      '退出 MyYaris 登录',
    ].every(texts.contains);
    await KeychainStore.channel.invokeMethod<void>(
      'captureHome',
      'glass-login-device.png',
    );
    Navigator.of(
      elements().firstWhere(
        (e) => e.widget.key == const ValueKey('settings-account-menu'),
      ),
    ).pop();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    (elements()
                .firstWhere(
                  (e) =>
                      e.widget.key ==
                      const ValueKey('settings-connection-open'),
                )
                .widget
            as ListTile)
        .onTap!();
    await Future<void>.delayed(const Duration(seconds: 1));
    final connection = elements().firstWhere(
      (e) => e.widget is ConnectionSettingsPage,
    );
    final fields = elements(
      connection,
    ).map((e) => e.widget).whereType<TextField>().toList();
    proof['configuration_prefilled'] =
        fields.length == 2 &&
        fields[0].controller!.text == origin &&
        fields[1].controller!.text == device;
    await KeychainStore.channel.invokeMethod<void>(
      'captureHome',
      'glass-drag-device.png',
    );
    Navigator.of(connection).pop();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    proof['configuration_unchanged'] =
        settings.session.api.baseUrl == origin &&
        settings.session.api.deviceId == device;
    proof['completed'] = [
      'root_hides_fields',
      'root_hides_prose',
      'account_menu_opened',
      'account_actions_present',
      'configuration_prefilled',
      'configuration_unchanged',
    ].every((k) => proof[k] == true);
  } catch (_) {
    proof['blocked'] = true;
  } finally {
    await saveEvidence(
      'glass-tabs-proof.json',
      Uint8List.fromList(utf8.encode(jsonEncode(proof))),
    );
  }
}
