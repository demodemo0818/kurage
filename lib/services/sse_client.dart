// lib/services/sse_client.dart

import 'sse_client_stub.dart'
    if (dart.library.js_interop) 'sse_client_web.dart'
    if (dart.library.io) 'sse_client_io.dart' as impl;

/// SSE (Server-Sent Events) で受信した 1 件のイベント。
///
/// `eventsource` パッケージの `Event` とブラウザ標準 `EventSource` の
/// `MessageEvent` を共通インターフェースにまとめる薄いデータ型。
class SseEvent {
  /// イベント名 (`update` / `notification` / `delete` / ...)。
  /// 名前のないデフォルトイベントは `'message'`。
  ///
  /// io 実装はコメント行 (Mastodon が 15〜30 秒ごとに送る `:thump`
  /// ハートビート等) を `'heartbeat'` (data なし) として流す。呼び出し側の
  /// サイレント切断 watchdog の生存判定に使う。Web はブラウザ標準
  /// EventSource がコメント行を露出しないため `'heartbeat'` は来ない。
  final String event;
  final String? data;
  final String? id;

  const SseEvent({required this.event, this.data, this.id});
}

/// アクティブな SSE 接続を表すハンドル。
///
/// [events] はイベントストリーム (broadcast)。リスナーが全部消えたら
/// 自動で底の native EventSource / HTTP 接続もクローズする実装になっている
/// ので、呼び出し側は通常 `subscription.cancel()` だけで十分。明示的に
/// 切断したい場合は [close] を呼ぶ。
abstract class SseConnection {
  Stream<SseEvent> get events;
  Future<void> close();
}

/// プラットフォーム別 SSE 接続を確立する。
///
/// - **Web**: ブラウザ標準 `EventSource` API (`package:web`) を直接叩く。
///   `package:http` の `BrowserClient` (XHR) はストリーミングレスポンスを
///   扱えないため SSE が成立しない (接続は通るがイベントが 1 件も届かない)。
/// - **Mobile / Desktop**: `dart:io` HttpClient ベースの自前パーサ
///   (sse_client_io.dart)。HttpClient はストリーミング対応なので問題なし。
Future<SseConnection> connectSse(String url) => impl.connectSse(url);
