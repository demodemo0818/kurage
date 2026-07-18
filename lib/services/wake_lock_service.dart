// lib/services/wake_lock_service.dart

import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// スリープ無効化（Wake Lock）を管理するサービス
class WakeLockService {
  static bool _isEnabled = false;

  /// Wake Lockを有効化（画面の自動消灯を防ぐ）
  static Future<void> enable() async {
    if (!_isEnabled) {
      try {
        await WakelockPlus.enable();
        _isEnabled = true;
        debugPrint('Wake lock enabled');
      } catch (e) {
        debugPrint('Failed to enable wake lock: $e');
      }
    }
  }

  /// Wake Lockを無効化（画面の自動消灯を許可）
  static Future<void> disable() async {
    if (_isEnabled) {
      try {
        await WakelockPlus.disable();
        _isEnabled = false;
        debugPrint('Wake lock disabled');
      } catch (e) {
        debugPrint('Failed to disable wake lock: $e');
      }
    }
  }

  /// 現在のWake Lock状態を取得
  static Future<bool> isEnabled() async {
    try {
      return await WakelockPlus.enabled;
    } catch (e) {
      debugPrint('Failed to get wake lock status: $e');
      return false;
    }
  }

  /// 設定に基づいてWake Lockを制御
  static Future<void> updateFromSettings(bool keepScreenOn) async {
    if (keepScreenOn) {
      await enable();
    } else {
      await disable();
    }
  }
}