import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myyaris_ios/api/pages.dart';
import 'package:myyaris_ios/api/backend.dart';
import 'widget_test.dart' show FixtureSession;

class SettingsFixture extends FixtureSession {
  SettingsFixture()
    : super(
        api: BackendApi(baseUrl: 'https://backend.example.test')
          ..deviceId = 'fixture-car',
      );
  int saves = 0, logouts = 0;
  String? savedBase, savedDevice;
  bool failSave = false;
  @override
  Future<void> saveConnection(String base, String device) async {
    saves++;
    if (failSave) throw ApiFailure('测试连接保存失败');
    savedBase = base;
    savedDevice = device;
  }

  @override
  Future<void> logout() async {
    logouts++;
  }
}

void main() {
  testWidgets(
    'settings root hides prose and fields, account actions require user card and logout confirmation',
    (tester) async {
      final session = SettingsFixture()
        ..userProfile = {'username': 'fixture-user', 'nickname': '测试用户'};
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SettingsPage(session: session)),
        ),
      );
      expect(find.text('HTTPS 后端地址'), findsNothing);
      expect(find.text('修改昵称'), findsNothing);
      expect(find.textContaining('Keychain'), findsNothing);
      expect(find.textContaining('旧固定凭据'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('settings-user-open')));
      await tester.pumpAndSettle();
      expect(find.text('修改昵称'), findsOneWidget);
      expect(find.text('刷新个人资料/权限'), findsOneWidget);
      await tester.tap(find.text('退出 MyYaris 登录'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-account-menu')), findsNothing);
      expect(find.text('退出登录'), findsWidgets);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(session.logouts, 0);
      expect(session.saves, 0);
    },
  );
  testWidgets(
    'connection subpage retains saved configuration, forwards save and does not save on back',
    (tester) async {
      final session = SettingsFixture();
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SettingsPage(session: session)),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('settings-connection-open')));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      expect(
        tester.widget<TextField>(fields.at(0)).controller!.text,
        'https://backend.example.test',
      );
      expect(
        tester.widget<TextField>(fields.at(1)).controller!.text,
        'fixture-car',
      );
      await tester.enterText(fields.at(1), 'another-fixture-car');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(session.saves, 0);
      await tester.tap(find.byKey(const ValueKey('settings-connection-open')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
        'fixture-car',
      );
      await tester.tap(find.text('保存并连接'));
      await tester.pumpAndSettle();
      expect(session.saves, 1);
      expect(session.savedBase, 'https://backend.example.test');
      expect(session.savedDevice, 'fixture-car');
      expect(find.text('连接设置已保存'), findsOneWidget);
    },
  );
  testWidgets(
    'connection subpage reports failure without false saved success',
    (tester) async {
      final session = SettingsFixture()..failSave = true;
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(home: ConnectionSettingsPage(session: session)),
      );
      await tester.tap(find.text('保存并连接'));
      await tester.pumpAndSettle();
      expect(find.textContaining('测试连接保存失败'), findsOneWidget);
      expect(find.text('连接设置已保存'), findsNothing);
    },
  );
}
