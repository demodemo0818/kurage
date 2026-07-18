// lib/models/annual_report.dart
//
// Mastodon 4.6+ の AnnualReport (通称 Wrapstodon / 年間まとめ) エンティティ。
// `/api/v1/annual_reports` 系が返す。
//
// `data` の内訳 (archetype / time_series / top_hashtags / top_statuses) は
// docs の構造記述が薄く、スキーマも schema_version で変わり得るため、
// 固めすぎず生の Map / List を保持する寛容パースにする (未知フィールドや
// スキーマ変更で落とさない)。表示は別フェーズ。

import 'json_utils.dart';

/// AnnualReport の `data` ペイロード。型を固定しすぎないよう、明示フィールドは
/// archetype のみとし、残りは生のコレクションとして保持する。
class AnnualReportData {
  /// ユーザーの「タイプ」(例: lurker / pollster / ...)。欠落なら空文字。
  final String archetype;

  /// 月次の時系列 (month / statuses / followers 等)。生のまま保持。
  final List<Map<String, dynamic>> timeSeries;

  /// 上位ハッシュタグ (name / count 等)。生のまま保持。
  final List<Map<String, dynamic>> topHashtags;

  /// 上位投稿 (by_reblogs / by_replies / by_favourites 等)。生のまま保持。
  final Map<String, dynamic> topStatuses;

  /// 取りこぼし防止に data 全体も保持。
  final Map<String, dynamic> raw;

  const AnnualReportData({
    this.archetype = '',
    this.timeSeries = const [],
    this.topHashtags = const [],
    this.topStatuses = const {},
    this.raw = const {},
  });

  factory AnnualReportData.fromJson(Map<String, dynamic> json) {
    List<Map<String, dynamic>> listOf(Object? v) =>
        (v as List<dynamic>?)?.whereType<Map<String, dynamic>>().toList() ??
        const [];
    return AnnualReportData(
      archetype: (json['archetype'] as String?) ?? '',
      timeSeries: listOf(json['time_series']),
      topHashtags: listOf(json['top_hashtags']),
      topStatuses: (json['top_statuses'] as Map<String, dynamic>?) ?? const {},
      raw: json,
    );
  }
}

class AnnualReport {
  final int year;
  final AnnualReportData data;
  final int schemaVersion;
  final String? accountId;
  final String? shareUrl;

  const AnnualReport({
    required this.year,
    required this.data,
    this.schemaVersion = 0,
    this.accountId,
    this.shareUrl,
  });

  factory AnnualReport.fromJson(Map<String, dynamic> json) {
    return AnnualReport(
      year: (json['year'] as int?) ??
          int.tryParse((json['year'] ?? '').toString()) ??
          0,
      data: json['data'] is Map<String, dynamic>
          ? AnnualReportData.fromJson(json['data'] as Map<String, dynamic>)
          : const AnnualReportData(),
      schemaVersion: (json['schema_version'] as int?) ?? 0,
      accountId: asIdStringOrNull(json['account_id']),
      shareUrl: json['share_url'] as String?,
    );
  }

  /// `GET /api/v1/annual_reports[/:year]` のレスポンスから AnnualReport の配列を
  /// 取り出す。レスポンスは `{ "annual_reports": [...], "accounts": [...],
  /// "statuses": [...] }` という封筒形式 (生配列のこともあるので両対応)。
  /// accounts / statuses 参照解決は表示フェーズに委ねる。
  static List<AnnualReport> listFromResponse(Object? decoded) {
    final List<dynamic> reports;
    if (decoded is Map<String, dynamic>) {
      reports = (decoded['annual_reports'] as List<dynamic>?) ?? const [];
    } else if (decoded is List<dynamic>) {
      reports = decoded;
    } else {
      reports = const [];
    }
    return reports
        .whereType<Map<String, dynamic>>()
        .map(AnnualReport.fromJson)
        .toList();
  }
}
