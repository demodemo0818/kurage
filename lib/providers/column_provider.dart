// lib/providers/column_provider.dart

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/analytics_service.dart';
import '../utils/breakpoints.dart';

/// カラム設定を一元管理する Riverpod プロバイダ
final columnProvider = StateNotifierProvider<ColumnNotifier, List<Map<String, dynamic>>>(
  (ref) => ColumnNotifier(),
);

/// このカラムが「通知カラム」(タイムラインではなく通知一覧を表示する特殊
/// カラム) かどうか。sources のいずれかが timelineType 'notifications' を
/// 持てば通知カラムとみなす。
///
/// 注 (方針A): 通知カラムの中身はグローバルな notificationsProvider の選択に
/// 従う (= 通知タブと同じデータ)。source の accountId はカラムヘッダー/タブの
/// アバター・カラー表示用にだけ使う。
bool isNotificationColumn(Map<String, dynamic> column) {
  final sources = (column['sources'] as List?) ?? const [];
  return sources.any((s) => (s as Map)['timelineType'] == 'notifications');
}

/// 通知カラムを 1 つ生成する。表示用に accountId を 1 つ持たせる。
Map<String, dynamic> buildNotificationColumn(String? accountId) => {
      'title': '',
      'sources': [
        {'accountId': accountId, 'timelineType': 'notifications'},
      ],
    };

/// 固定幅モードで使うカラムの幅 (px)。`column['width']` が未設定なら既定幅
/// [kColumnWidth] にフォールバックする。可変幅モードでは使わない。
double columnFixedWidth(Map<String, dynamic> column) =>
    (column['width'] as num?)?.toDouble() ?? kColumnWidth;

class ColumnNotifier extends StateNotifier<List<Map<String, dynamic>>> {
  ColumnNotifier() : super([]) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString('columns');
    if (data != null) {
      try {
        state = (jsonDecode(data) as List).cast<Map<String, dynamic>>();
      } catch (e) {
        // 破損 JSON は空 (デフォルトカラム再生成) のまま続行
        debugPrint('columns の読み込みに失敗: $e');
      }
    }
  }

  /// デフォルトのホームタイムラインカラムを作成
  Future<void> createDefaultColumnsIfEmpty(List<String> accountIds) async {
    if (state.isNotEmpty || accountIds.isEmpty) return;
    
    final defaultColumns = <Map<String, dynamic>>[];
    
    // 各アカウントのホームタイムラインカラムを作成
    for (final accountId in accountIds) {
      defaultColumns.add({
        'title': '',
        'sources': [
          {
            'accountId': accountId,
            'timelineType': 'home',
          }
        ]
      });
    }
    
    await save(defaultColumns);
  }

  /// カラム設定を保存し、SharedPreferences に書き込む
  Future<void> save(List<Map<String, dynamic>> updated) async {
    state = updated;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('columns', jsonEncode(state));
    // 利用状況: カラム構成の更新 (件数のみ。中身は送らない)。
    AnalyticsService.instance
        .logEvent('column_saved', parameters: {'column_count': state.length});
  }
}
