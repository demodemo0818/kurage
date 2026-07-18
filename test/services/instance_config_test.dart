// InstanceConfig.fromJson のパースのテスト。
//
// 文字数上限 (configuration.statuses.max_characters) と、Mastodon 4.6+ で
// 追加されたプロフィール編集上限 (configuration.accounts.*) を読むこと、
// および古いサーバ (欠落) ではハードコード相当のデフォルトに落ちることを守る。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/services/mastodon_api.dart';

void main() {
  group('InstanceConfig.fromJson 文字数上限', () {
    test('configuration.statuses.max_characters を読む', () {
      final c = InstanceConfig.fromJson({
        'configuration': {
          'statuses': {'max_characters': 1000},
        },
      });
      expect(c.maxTootChars, 1000);
    });

    test('旧 max_toot_chars にフォールバック', () {
      final c = InstanceConfig.fromJson({'max_toot_chars': 800});
      expect(c.maxTootChars, 800);
    });

    test('Pleroma の max_characters にフォールバック', () {
      final c = InstanceConfig.fromJson({'max_characters': 1234});
      expect(c.maxTootChars, 1234);
    });

    test('全欠落時は 500', () {
      expect(InstanceConfig.fromJson({}).maxTootChars, 500);
    });
  });

  group('InstanceConfig.fromJson プロフィール編集上限 (4.6)', () {
    test('configuration.accounts.* を読む', () {
      final c = InstanceConfig.fromJson({
        'configuration': {
          'accounts': {
            'max_note_length': 600,
            'max_display_name_length': 40,
            'max_profile_fields': 6,
            'profile_field_name_limit': 100,
            'profile_field_value_limit': 2048,
          },
        },
      });
      expect(c.maxNoteLength, 600);
      expect(c.maxDisplayNameLength, 40);
      expect(c.maxProfileFields, 6);
      expect(c.profileFieldNameLimit, 100);
      expect(c.profileFieldValueLimit, 2048);
    });

    test('accounts が無い (古いサーバ) はデフォルト 500/30/4/255/255', () {
      final c = InstanceConfig.fromJson({
        'configuration': {
          'statuses': {'max_characters': 500},
        },
      });
      expect(c.maxNoteLength, 500);
      expect(c.maxDisplayNameLength, 30);
      expect(c.maxProfileFields, 4);
      expect(c.profileFieldNameLimit, 255);
      expect(c.profileFieldValueLimit, 255);
    });

    test('accounts の一部だけある場合は残りがデフォルト', () {
      final c = InstanceConfig.fromJson({
        'configuration': {
          'accounts': {'max_note_length': 700},
        },
      });
      expect(c.maxNoteLength, 700);
      expect(c.maxDisplayNameLength, 30); // 欠落 → デフォルト
    });
  });

  group('InstanceConfig.fromJson 4.6 機能対応フラグ (version 判定)', () {
    test('version 4.6.0 なら supportsV46AccountFeatures = true', () {
      final c = InstanceConfig.fromJson({'version': '4.6.0'});
      expect(c.supportsV46AccountFeatures, isTrue);
    });

    test('version 4.6.2+glitch でも true', () {
      final c = InstanceConfig.fromJson({'version': '4.6.2+glitch'});
      expect(c.supportsV46AccountFeatures, isTrue);
    });

    test('version 5.0.0 (メジャー上) は true', () {
      final c = InstanceConfig.fromJson({'version': '5.0.0'});
      expect(c.supportsV46AccountFeatures, isTrue);
    });

    test('version 4.10.0 (マイナー二桁) は true', () {
      final c = InstanceConfig.fromJson({'version': '4.10.0'});
      expect(c.supportsV46AccountFeatures, isTrue);
    });

    test('version 4.5.2 は false (4.6 未満)', () {
      final c = InstanceConfig.fromJson({'version': '4.5.2'});
      expect(c.supportsV46AccountFeatures, isFalse);
    });

    test('version 3.5.3 は false', () {
      final c = InstanceConfig.fromJson({'version': '3.5.3'});
      expect(c.supportsV46AccountFeatures, isFalse);
    });

    test('Pleroma 互換 version "2.7.2 (compatible; Pleroma 2.5.0)" は false', () {
      final c = InstanceConfig.fromJson(
          {'version': '2.7.2 (compatible; Pleroma 2.5.0)'});
      expect(c.supportsV46AccountFeatures, isFalse);
    });

    test('version 欠落は false (判定不能 → 未対応に倒す)', () {
      expect(InstanceConfig.fromJson({}).supportsV46AccountFeatures, isFalse);
    });

    test('configuration.accounts があっても version が 4.6 未満なら false', () {
      // accounts は max_featured_tags 等で 4.6 より前から存在するため、
      // その有無では判定しない (誤検出を防ぐ回帰テスト)。
      final c = InstanceConfig.fromJson({
        'version': '4.5.0',
        'configuration': {
          'accounts': {'max_featured_tags': 10},
        },
      });
      expect(c.supportsV46AccountFeatures, isFalse);
    });
  });
}
