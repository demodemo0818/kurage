// lib/services/sse_client_io.dart
//
// Mobile / Desktop (dart:io 環境) 向け SSE 実装。
//
// 以前は `eventsource` パッケージに依存していたが、これが `http ^0.13` を
// 要求して http の 1.x 化 (= google_fonts ^6.x 等の新しい依存を入れる前提) を
// ブロックしていたため、`dart:io` の `HttpClient` を使った自前 SSE パーサに
// 置き換えた。`HttpClient` はストリーミングレスポンスをそのまま読めるので
// SSE にそのまま使える (eventsource も内部ではこれを使っていた)。
//
// 自動再接続はこのレイヤーでは行わない。切断 (onError / onDone) を
// ストリームにそのまま流し、呼び出し側 (timeline_view._StreamConnection /
// notifications_provider) の指数バックオフ再接続に任せる設計を維持する。
// Web 側 (sse_client_web.dart) がブラウザ native EventSource を使うのと
// 同様に、close()/cancel() で底の接続を確実に閉じる。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'sse_client.dart';

Future<SseConnection> connectSse(String url) async {
  final client = HttpClient();
  final request = await client.getUrl(Uri.parse(url));
  request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
  // SSE は長時間 idle になり得る。プロキシ/CDN のキャッシュを避ける。
  request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
  final response = await request.close();

  if (response.statusCode != HttpStatus.ok) {
    // 接続自体は張れたが 4xx/5xx。ボディを読み捨ててからエラーにする。
    // (呼び出し側の backoff 再接続に拾わせる。)
    await response.drain<void>().catchError((_) {});
    client.close(force: true);
    throw HttpException('SSE 接続失敗 (HTTP ${response.statusCode}): $url');
  }

  return _IoSseConnection(client, response);
}

class _IoSseConnection implements SseConnection {
  final HttpClient _client;
  late final StreamController<SseEvent> _controller;
  StreamSubscription<String>? _lineSub;

  // 現在組み立て中のイベントのフィールド。SSE 仕様 (W3C) に従い、
  // 空行が来るまで data/event/id を溜め、空行で 1 イベントとして dispatch する。
  String _eventName = '';
  final StringBuffer _dataBuffer = StringBuffer();
  bool _hasData = false;
  String? _lastEventId;

  _IoSseConnection(this._client, HttpClientResponse response) {
    // broadcast + onCancel で底の HttpClient も閉じる。複数 listener が消えた
    // 瞬間に接続も切れるので、呼び出し側は subscription.cancel() で完結できる
    // (Web 実装と同じ契約)。
    _controller = StreamController<SseEvent>.broadcast(onCancel: _close);
    _lineSub = response
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _handleLine,
          onError: (Object e, StackTrace st) {
            if (!_controller.isClosed) _controller.addError(e, st);
          },
          onDone: () {
            // サーバ/プロキシ側の切断。ストリームを閉じて呼び出し側の onDone を
            // 発火させる (そこで指数バックオフ再接続される)。
            if (!_controller.isClosed) _controller.close();
            _client.close(force: true);
          },
          cancelOnError: false,
        );
  }

  void _handleLine(String line) {
    // 空行 = イベント区切り。組み立て済みのイベントを dispatch する。
    if (line.isEmpty) {
      _dispatch();
      return;
    }
    // コメント行 (`:` 始まり、Mastodon の `:thump` ハートビート等)。
    // 捨てずに 'heartbeat' イベントとして流し、呼び出し側の生存監視
    // (watchdog の lastEventAt 更新) に使えるようにする。イベント名で
    // フィルタしている既存の消費側 ('update' / 'notification') には届かない。
    if (line.startsWith(':')) {
      if (!_controller.isClosed) {
        _controller.add(const SseEvent(event: 'heartbeat'));
      }
      return;
    }

    final String field;
    String value;
    final colon = line.indexOf(':');
    if (colon == -1) {
      field = line;
      value = '';
    } else {
      field = line.substring(0, colon);
      value = line.substring(colon + 1);
      // 値の先頭スペース 1 つだけ除去 (SSE 仕様)。
      if (value.startsWith(' ')) value = value.substring(1);
    }

    switch (field) {
      case 'event':
        _eventName = value;
        break;
      case 'data':
        // data 行は複数来たら "\n" で連結する (SSE 仕様)。
        if (_hasData) _dataBuffer.write('\n');
        _dataBuffer.write(value);
        _hasData = true;
        break;
      case 'id':
        _lastEventId = value;
        break;
      // 'retry' は呼び出し側の再接続戦略を使うので無視。
    }
  }

  void _dispatch() {
    // data も event 名も無い空イベントは無視。
    if (!_hasData && _eventName.isEmpty) return;
    if (!_controller.isClosed) {
      _controller.add(SseEvent(
        event: _eventName.isEmpty ? 'message' : _eventName,
        data: _hasData ? _dataBuffer.toString() : null,
        id: _lastEventId,
      ));
    }
    // 次イベントのためにリセット (lastEventId は仕様上 reconnect まで永続)。
    _eventName = '';
    _dataBuffer.clear();
    _hasData = false;
  }

  Future<void> _close() async {
    await _lineSub?.cancel();
    _lineSub = null;
    _client.close(force: true);
    if (!_controller.isClosed) await _controller.close();
  }

  @override
  Stream<SseEvent> get events => _controller.stream;

  @override
  Future<void> close() => _close();
}
