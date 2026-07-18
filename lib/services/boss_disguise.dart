// lib/services/boss_disguise.dart
//
// ボスキー (偽装モード) 中に、ブラウザタブの title / favicon を Google 風に
// 差し替えるためのファサード。Web のみ実装し、それ以外 (デスクトップ/モバイル)
// は no-op。条件付き import は auth_service.dart と同じパターン。
//
// デスクトップのウィンドウタイトル変更は window_manager 等の依存追加が必要な
// ため現状未対応 (Web 限定)。

import 'boss_disguise_stub.dart'
    if (dart.library.js_interop) 'boss_disguise_web.dart' as impl;

/// 偽装を適用する (title → "Google" / favicon → Google 風)。
void applyDisguise() => impl.applyDisguise();

/// 偽装を解除する (退避していた title / favicon を復元)。
void restoreDisguise() => impl.restoreDisguise();
