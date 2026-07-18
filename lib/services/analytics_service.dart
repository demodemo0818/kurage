// lib/services/analytics_service.dart
import 'dart:async';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';

/// Firebase Analytics (GA4) の薄いラッパー。
///
/// - **対象は Web + Android のみ** (desktop/iOS は Firebase 非対応)。
/// - Firebase init 失敗時・解析オプトアウト時・init 前は **全 API が no-op**。
///   呼び出し側はプラットフォーム分岐や null チェックをしなくてよい。
/// - **プライバシー方針**: 送るのは集計用の真偽値/件数/enum のみ。
///   instance URL / 投稿 ID / アカウント ID / 本文 等の個人特定・追跡可能情報は
///   **載せないこと**。
/// - Firebase Analytics のイベントパラメータは String / num しか受け付けない
///   ため、bool は 0/1 に、その他は toString() に正規化してから送る。
class AnalyticsService {
  AnalyticsService._();
  static final AnalyticsService instance = AnalyticsService._();

  FirebaseAnalytics? _analytics;
  bool _enabled = true;

  bool get _ready => _analytics != null && _enabled;

  /// Firebase init 完了後に main.dart から一度だけ呼ぶ。
  /// [available] には「Firebase init 成功 && (Web または Android)」を渡す。
  Future<void> configure({
    required bool available,
    required bool enabled,
  }) async {
    _enabled = enabled;
    if (!available) {
      _analytics = null;
      return;
    }
    try {
      _analytics = FirebaseAnalytics.instance;
      await _analytics!.setAnalyticsCollectionEnabled(enabled);
    } catch (e) {
      _analytics = null;
      debugPrint('Analytics 初期化エラー: $e');
    }
  }

  /// 設定トグルからの ON/OFF。Firebase 側の収集フラグにも反映する。
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    final a = _analytics;
    if (a == null) return;
    try {
      await a.setAnalyticsCollectionEnabled(value);
    } catch (e) {
      debugPrint('Analytics 収集フラグ変更エラー: $e');
    }
  }

  /// 任意のイベントを送る (fire-and-forget)。
  /// [parameters] には真偽値/件数/enum 文字列のみを渡すこと (PII 禁止)。
  void logEvent(String name, {Map<String, Object?>? parameters}) {
    if (!_ready) return;
    final coerced = _coerce(parameters);
    unawaited(
      _analytics!
          .logEvent(name: name, parameters: coerced)
          .catchError((Object _) {}),
    );
  }

  /// 画面表示 (タブ遷移)。[screenName] は enum 文字列 (PII を含めない)。
  void logScreenView(String screenName) {
    if (!_ready) return;
    unawaited(
      _analytics!
          .logScreenView(screenName: screenName, screenClass: 'RootPage')
          .catchError((Object _) {}),
    );
  }

  /// Firebase Analytics は String / num のみ許可。bool→0/1、その他→toString()。
  Map<String, Object>? _coerce(Map<String, Object?>? params) {
    if (params == null) return null;
    final out = <String, Object>{};
    params.forEach((k, v) {
      if (v == null) return;
      if (v is bool) {
        out[k] = v ? 1 : 0;
      } else if (v is String || v is num) {
        out[k] = v;
      } else {
        out[k] = v.toString();
      }
    });
    return out;
  }
}
