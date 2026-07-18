// lib/models/json_utils.dart
//
// Mastodon API レスポンスの防御的パース用ヘルパー。
// Mastodon 派生サーバ (Pleroma / Akkoma / Misskey ブリッジ等) は
// ID を JSON int で返したり、本家では非 null のフィールドを null で
// 返したりするため、生の `as String` / `DateTime.parse` キャストは
// 1 件の投稿でタイムライン全体のパースを巻き込んで失敗させる。
// モデルの fromJson は原則ここの関数を経由する。

/// JSON 値を文字列の ID として取り出す (nullable 版)。
/// `num` の場合は `toString()` に正規化する。
String? asIdStringOrNull(Object? v) {
  if (v == null) return null;
  if (v is String) return v;
  if (v is num) return v.toString();
  return null;
}

/// JSON 値を文字列の ID として取り出す (必須版)。
/// ID が欠落した entity はそもそも扱えないので [FormatException] を投げる。
/// リスト系のデコーダ (`_decodeStatusListIsolate` 等) は 1 件の失敗を
/// skip する設計なので、throw により「その 1 件だけ落とす」挙動になる。
String asIdString(Object? v) {
  final id = asIdStringOrNull(v);
  if (id == null) {
    throw FormatException('ID フィールドがパースできません: $v');
  }
  return id;
}

/// JSON 値を DateTime として取り出す (nullable 版)。
/// null / 非文字列 / 不正な ISO 8601 はすべて null に倒す。
DateTime? tryParseDateTime(Object? v) {
  if (v is! String || v.isEmpty) return null;
  return DateTime.tryParse(v);
}

/// JSON 値を DateTime として取り出す (必須版)。
/// パースできない場合は [fallback] (省略時は現在時刻) に倒し、クラッシュさせない。
DateTime parseDateTimeOr(Object? v, [DateTime? fallback]) {
  return tryParseDateTime(v) ?? fallback ?? DateTime.now();
}
