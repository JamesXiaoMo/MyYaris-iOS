// Captures only a real empty login page; never sends account credentials.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:myyaris_ios/main.dart' as app;
import 'package:myyaris_ios/api/backend.dart';

Future<void> main() async {
  app.main();
  await Future<void>.delayed(const Duration(seconds: 4));
  final fields = <String, TextField>{};
  void visit(Element e) {
    final w = e.widget;
    if (w is TextField && w.key is ValueKey<String>) {
      fields[(w.key as ValueKey<String>).value] = w;
    }
    e.visitChildElements(visit);
  }

  final root = WidgetsBinding.instance.rootElement;
  if (root == null) return;
  visit(root);
  if (fields['login-username']?.controller?.text != '' ||
      fields['login-password']?.controller?.text != '') {
    return;
  }
  await KeychainStore.channel.invokeMethod<void>(
    'captureHome',
    'login-device.png',
  );
}
