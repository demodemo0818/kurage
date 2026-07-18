// PushNotificationService.readPushEnabledFromPrefs の単体テスト。
//
// settingsProvider の _load() 完了を待てないコンテキスト (起動直後・
// onTokenRefresh・ログイン直後) から SharedPreferences の
// `appearanceSettings` JSON を直読みするヘルパー。デフォルト (未設定・
// 破損 JSON) は true = 従来挙動の維持であることを固定する。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kurage/services/push_notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('未設定 (キーなし) は true', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await PushNotificationService.readPushEnabledFromPrefs(), isTrue);
  });

  test('pushNotificationsEnabled: false は false', () async {
    SharedPreferences.setMockInitialValues({
      'appearanceSettings': jsonEncode({'pushNotificationsEnabled': false}),
    });
    expect(await PushNotificationService.readPushEnabledFromPrefs(), isFalse);
  });

  test('pushNotificationsEnabled: true は true', () async {
    SharedPreferences.setMockInitialValues({
      'appearanceSettings': jsonEncode({'pushNotificationsEnabled': true}),
    });
    expect(await PushNotificationService.readPushEnabledFromPrefs(), isTrue);
  });

  test('JSON にキーが無い場合は true', () async {
    SharedPreferences.setMockInitialValues({
      'appearanceSettings': jsonEncode({'themeMode': 'dark'}),
    });
    expect(await PushNotificationService.readPushEnabledFromPrefs(), isTrue);
  });

  test('破損 JSON は true (起動を止めない)', () async {
    SharedPreferences.setMockInitialValues({
      'appearanceSettings': '{broken json',
    });
    expect(await PushNotificationService.readPushEnabledFromPrefs(), isTrue);
  });
}
