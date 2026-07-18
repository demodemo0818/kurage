// LiveModeSettings (実況モード設定) のシリアライズとハッシュタグ整形のテスト。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/models/live_mode.dart';

void main() {
  group('デフォルト値と copyWith', () {
    test('デフォルトは無効・タグなし・末尾挿入', () {
      const settings = LiveModeSettings();
      expect(settings.isEnabled, false);
      expect(settings.hashtags, isEmpty);
      expect(settings.insertAtEnd, true);
    });

    test('copyWith は指定フィールドのみ差し替える', () {
      const settings = LiveModeSettings(hashtags: ['live']);
      final copied = settings.copyWith(isEnabled: true);
      expect(copied.isEnabled, true);
      expect(copied.hashtags, ['live']);
      expect(copied.insertAtEnd, true);
    });
  });

  group('JSON シリアライズ', () {
    test('fromJson の欠落キーはデフォルトにフォールバックする', () {
      final settings = LiveModeSettings.fromJson({});
      expect(settings.isEnabled, false);
      expect(settings.hashtags, isEmpty);
      expect(settings.insertAtEnd, true);
    });

    test('toJsonString → fromJsonString のラウンドトリップ', () {
      const settings = LiveModeSettings(
        isEnabled: true,
        hashtags: ['実況', 'live'],
        insertAtEnd: false,
      );
      final restored = LiveModeSettings.fromJsonString(settings.toJsonString());
      expect(restored, settings);
    });

    test('不正な JSON 文字列はデフォルト設定にフォールバックする', () {
      final restored = LiveModeSettings.fromJsonString('{broken json');
      expect(restored, const LiveModeSettings());
    });
  });

  group('formattedHashtags', () {
    test('# 無しのタグには # を付与する', () {
      const settings = LiveModeSettings(hashtags: ['live']);
      expect(settings.formattedHashtags, ['#live']);
    });

    test('先頭の # 連続 (##tag) は除去して 1 つにする', () {
      const settings = LiveModeSettings(hashtags: ['#live', '##実況']);
      expect(settings.formattedHashtags, ['#live', '#実況']);
    });

    test('空白のみ・# のみのタグは除外される', () {
      const settings = LiveModeSettings(hashtags: ['  ', '#', 'live']);
      expect(settings.formattedHashtags, ['#live']);
    });
  });

  group('hashtagString', () {
    test('空なら空文字、非空なら先頭スペース付きで join', () {
      expect(const LiveModeSettings().hashtagString, '');
      const settings = LiveModeSettings(hashtags: ['live', '実況']);
      expect(settings.hashtagString, ' #live #実況');
    });
  });

  group('== / hashCode', () {
    test('同値の設定は等価で hashCode も一致する', () {
      const a = LiveModeSettings(isEnabled: true, hashtags: ['live']);
      const b = LiveModeSettings(isEnabled: true, hashtags: ['live']);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('hashtags が異なれば等価でない', () {
      const a = LiveModeSettings(hashtags: ['live']);
      const b = LiveModeSettings(hashtags: ['other']);
      expect(a == b, false);
    });
  });
}
