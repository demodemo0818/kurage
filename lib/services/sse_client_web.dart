// lib/services/sse_client_web.dart
//
// Web 向け SSE 実装。ブラウザ標準の `EventSource` API を直接叩く。
//
// `eventsource` Dart パッケージは `package:http` 経由で組み立てているため、
// Web では BrowserClient (XHR) を使ってしまい SSE が成立しない (XHR は
// 「全部受信してから配信」モデルなので、サーバが接続を開いたまま少しずつ
// 投げてくるイベントを stream として読めない)。
// 一方、ブラウザの native EventSource API は SSE プロトコル専用に作られて
// いるので自動再接続も含めて正しく動く。CORS / Cookie 周りもブラウザが
// 面倒を見てくれる。
//
// dart:html は deprecated のため package:web + dart:js_interop を使う。

import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'sse_client.dart';

/// Mastodon が使う SSE イベント名のリスト。
///
/// ブラウザ EventSource は **イベント名ごと** に listener を登録する必要が
/// あり、message イベントだけだと「名前なし」 (= type: 'message') の
/// イベントしか拾えない。Mastodon は `update` / `notification` / `delete`
/// などの名前付きイベントを発火するので、それぞれに対して明示的に
/// listener を貼る。
///
/// 参考: https://docs.joinmastodon.org/methods/streaming/#events
const _mastodonEventNames = <String>[
  'update', // タイムライン新着
  'notification', // 通知
  'delete', // 投稿削除
  'status.update', // 投稿編集
  'conversation', // DM
  'announcement', // お知らせ
  'announcement.reaction', // お知らせへのリアクション
  'announcement.delete', // お知らせ削除
  'filters_changed', // フィルタ変更
];

Future<SseConnection> connectSse(String url) async {
  final es = web.EventSource(url);
  // broadcast ストリーム + onCancel で底の EventSource も閉じる。
  // 複数 listener が消えた瞬間に接続も切れるので、明示的な close() 呼び
  // 出しを呼び出し側に強要せず、`subscription.cancel()` で完結する。
  late final StreamController<SseEvent> controller;
  controller = StreamController<SseEvent>.broadcast(
    onCancel: () {
      es.close();
    },
  );

  for (final name in _mastodonEventNames) {
    web.EventStreamProvider<web.MessageEvent>(name).forTarget(es).listen(
      (event) {
        controller.add(SseEvent(
          event: name,
          data: event.data.dartify()?.toString(),
          id: event.lastEventId,
        ));
      },
    );
  }
  // 名前なしのデフォルトイベント (= type === 'message')。サーバ実装が
  // ばらつくケースに備えて拾っておく。
  web.EventStreamProviders.messageEvent.forTarget(es).listen((event) {
    controller.add(SseEvent(
      event: 'message',
      data: event.data.dartify()?.toString(),
      id: event.lastEventId,
    ));
  });
  // 切断 / エラーはストリーム側に流し、呼び出し側の指数バックオフ
  // 再接続ロジック (timeline_view._StreamConnection) に任せる。
  web.EventStreamProviders.errorEvent.forTarget(es).listen((event) {
    controller.addError(Exception('SSE エラー: $url'));
  });

  return _WebSseConnection(es, controller);
}

class _WebSseConnection implements SseConnection {
  final web.EventSource _es;
  final StreamController<SseEvent> _controller;
  _WebSseConnection(this._es, this._controller);

  @override
  Stream<SseEvent> get events => _controller.stream;

  @override
  Future<void> close() async {
    _es.close();
    if (!_controller.isClosed) await _controller.close();
  }
}
