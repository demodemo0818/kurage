// lib/utils/bounded_collections.dart
//
// 「最大件数つき」の Map / Set。`scrollable_positioned_list` 配下の tile が
// 自身の State 破棄を跨いで UI 状態を保持するための static cache が、長時間
// 運用で無制限に膨らむのを防ぐ。
//
// アルゴリズムは FIFO (= insertion order, 最古の追加が evict 対象)。LRU では
// ない理由は、(a) 読み出しのたびに頻度を更新するコストを払いたくない、
// (b) tile のキャッシュ用途では「ユーザーが現在見ている status の周辺数百件」
// が hot で、それ以上古いものは消えてもユーザーの体感に影響しないため。
//
// Dart 標準の `Map` / `Set` リテラルは `LinkedHashMap` / `LinkedHashSet` で、
// 挿入順を保持する。`keys.first` / `first` が常に最古を指す。

import 'dart:collection';

/// 最大サイズに達したら最古エントリを 1 件 evict してから put する Map。
///
/// 既存キーの上書きはサイズに影響しない (insertion order での位置も維持)。
class BoundedMap<K, V> extends MapBase<K, V> {
  final Map<K, V> _inner = <K, V>{};
  final int maxSize;

  BoundedMap(this.maxSize) : assert(maxSize > 0);

  @override
  V? operator [](Object? key) => _inner[key];

  @override
  void operator []=(K key, V value) {
    if (!_inner.containsKey(key) && _inner.length >= maxSize) {
      _inner.remove(_inner.keys.first);
    }
    _inner[key] = value;
  }

  @override
  V? remove(Object? key) => _inner.remove(key);

  @override
  void clear() => _inner.clear();

  @override
  Iterable<K> get keys => _inner.keys;
}

/// 最大サイズに達したら最古エントリを 1 件 evict してから add する Set。
class BoundedSet<E> extends SetBase<E> {
  final Set<E> _inner = <E>{};
  final int maxSize;

  BoundedSet(this.maxSize) : assert(maxSize > 0);

  @override
  bool add(E value) {
    if (!_inner.contains(value) && _inner.length >= maxSize) {
      _inner.remove(_inner.first);
    }
    return _inner.add(value);
  }

  @override
  bool contains(Object? element) => _inner.contains(element);

  @override
  Iterator<E> get iterator => _inner.iterator;

  @override
  int get length => _inner.length;

  @override
  E? lookup(Object? element) => _inner.lookup(element);

  @override
  bool remove(Object? value) => _inner.remove(value);

  @override
  Set<E> toSet() => _inner.toSet();
}
