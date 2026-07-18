// AvatarUtils.addCacheBuster のテスト。
//
// clearImageCache は cached_network_image プラグイン依存のため対象外。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/utils/avatar_utils.dart';

void main() {
  group('AvatarUtils.addCacheBuster', () {
    test('空文字はそのまま返す', () {
      expect(AvatarUtils.addCacheBuster(''), '');
    });

    test('クエリ無し URL には ?t=<timestamp> を付ける', () {
      final result =
          AvatarUtils.addCacheBuster('https://example.com/avatar.png');
      expect(result, startsWith('https://example.com/avatar.png?t='));
      expect(RegExp(r'\?t=\d+$').hasMatch(result), true);
    });

    test('クエリ有り URL には &t=<timestamp> を付ける', () {
      final result =
          AvatarUtils.addCacheBuster('https://example.com/avatar.png?v=2');
      expect(result, startsWith('https://example.com/avatar.png?v=2&t='));
      expect(RegExp(r'&t=\d+$').hasMatch(result), true);
    });
  });
}
