// lib/services/share_intake_service.dart
//
// 他アプリの「共有」メニューから本アプリに送られた text/plain を
// ネイティブ層から取り出すためのラッパー。
//
// AndroidManifest の `ACTION_SEND` intent-filter で起動された MainActivity が
// `pendingSharedText` にテキストを格納しており、Flutter 側はここで
// `consumePendingSharedText` を呼び出して 1 回だけ取り出す (取り出すと同時に
// ネイティブ側でクリアされる)。

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// 注意: `Platform.isAndroid` (dart:io) は Web では未実装で実行時 throw する。
// 各メソッドの先頭で `kIsWeb` を見て早期 return する必要がある。

class ShareIntakeService {
  ShareIntakeService._();

  static final ShareIntakeService instance = ShareIntakeService._();

  static const _channel = MethodChannel('jp.demo2.kurage/share_intake');

  /// ネイティブ側に貯まっている共有テキストを 1 件取り出す。
  ///
  /// - 取り出した時点でネイティブ側はクリアされるので、複数回呼んでも
  ///   2 回目以降は `null` が返る (= 二重投稿防止)。
  /// - Android 以外では何もしない (iOS は Share Extension 未実装)。
  Future<String?> consumePendingSharedText() async {
    // Web では dart:io Platform が実行時 throw するため、`Platform.isAndroid`
    // より先に kIsWeb で抜ける。
    if (kIsWeb) return null;
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('consumePendingSharedText');
    } catch (e) {
      debugPrint('ShareIntakeService.consumePendingSharedText failed: $e');
      return null;
    }
  }
}
