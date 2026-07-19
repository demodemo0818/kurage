// lib/services/sse_client_stub.dart
//
// dart:html / dart:io いずれも無いプラットフォーム向けスタブ。
// 通常到達しない (Flutter は web か io かのどちらかなので)。

import 'sse_client.dart';

Future<SseConnection> connectSse(String url) {
  throw UnsupportedError(
    'SSE is not supported on this platform',
  );
}
