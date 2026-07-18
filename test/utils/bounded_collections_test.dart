// BoundedMap / BoundedSet の FIFO eviction 挙動テスト。
//
// PostTile の static cache 群が無制限に膨らむのを防ぐためのユーティリティ。
// アルゴリズムを変えると tile の UI 状態保持が壊れる (展開した CW が
// 折り畳まれる等) のでテストで挙動を固定する。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/utils/bounded_collections.dart';

void main() {
  group('BoundedMap', () {
    test('上限未満では evict しない', () {
      final m = BoundedMap<String, int>(3);
      m['a'] = 1;
      m['b'] = 2;
      m['c'] = 3;
      expect(m.length, 3);
      expect(m['a'], 1);
    });

    test('上限超え時は最古を 1 件 evict', () {
      final m = BoundedMap<String, int>(3);
      m['a'] = 1;
      m['b'] = 2;
      m['c'] = 3;
      m['d'] = 4; // 'a' が evict されるはず
      expect(m.length, 3);
      expect(m.containsKey('a'), isFalse);
      expect(m.containsKey('d'), isTrue);
      expect(m['b'], 2);
      expect(m['c'], 3);
    });

    test('既存キーの上書きは evict を引き起こさない', () {
      final m = BoundedMap<String, int>(3);
      m['a'] = 1;
      m['b'] = 2;
      m['c'] = 3;
      m['b'] = 20; // 上書き、サイズは 3 のまま
      expect(m.length, 3);
      expect(m['a'], 1);
      expect(m['b'], 20);
      expect(m['c'], 3);
    });

    test('複数回 evict が連鎖する', () {
      final m = BoundedMap<int, String>(2);
      m[1] = 'a';
      m[2] = 'b';
      m[3] = 'c'; // 1 evict
      m[4] = 'd'; // 2 evict
      m[5] = 'e'; // 3 evict
      expect(m.length, 2);
      expect(m.containsKey(1), isFalse);
      expect(m.containsKey(2), isFalse);
      expect(m.containsKey(3), isFalse);
      expect(m.containsKey(4), isTrue);
      expect(m.containsKey(5), isTrue);
    });

    test('remove は明示的にエントリを削除', () {
      final m = BoundedMap<String, int>(3);
      m['a'] = 1;
      m['b'] = 2;
      m.remove('a');
      expect(m.length, 1);
      expect(m.containsKey('a'), isFalse);
    });

    test('maxSize == 1 でも動作', () {
      final m = BoundedMap<String, int>(1);
      m['a'] = 1;
      m['b'] = 2;
      expect(m.length, 1);
      expect(m['b'], 2);
    });
  });

  group('BoundedSet', () {
    test('上限未満では evict しない', () {
      final s = BoundedSet<String>(3);
      s.addAll(['a', 'b', 'c']);
      expect(s.length, 3);
      expect(s.contains('a'), isTrue);
    });

    test('上限超え時は最古を 1 件 evict', () {
      final s = BoundedSet<String>(3);
      s.addAll(['a', 'b', 'c']);
      s.add('d');
      expect(s.length, 3);
      expect(s.contains('a'), isFalse);
      expect(s.contains('d'), isTrue);
    });

    test('既存要素の再 add は evict を引き起こさない', () {
      final s = BoundedSet<String>(3);
      s.addAll(['a', 'b', 'c']);
      final added = s.add('b'); // 既存
      expect(added, isFalse);
      expect(s.length, 3);
      expect(s.contains('a'), isTrue);
    });
  });
}
