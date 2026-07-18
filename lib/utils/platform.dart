// lib/utils/platform.dart

import 'package:flutter/foundation.dart';

/// Web またはデスクトップ (Windows / macOS / Linux) かどうか。
///
/// 物理キーボード前提の機能 (ボスキー＝偽装モード等) の出し分けや、
/// CJK フォールバックフォントの付与判定に使う。
///
/// `dart:io` の `Platform` を Web で参照すると実行時に throw するため、
/// `kIsWeb` と `defaultTargetPlatform` だけで判定する (dart:io 非依存)。
bool isWebOrDesktop() =>
    kIsWeb ||
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.linux;

/// デスクトップ (Windows / macOS / Linux) かどうか (Web は除く)。
///
/// 画像のネイティブ保存ダイアログ / 既定フォルダ保存のように、Web では使えず
/// モバイルとも挙動を分けたい機能の出し分けに使う。`isWebOrDesktop()` と同様、
/// `dart:io` の `Platform` を避けて `kIsWeb` + `defaultTargetPlatform` で判定する。
bool isDesktop() =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux);
