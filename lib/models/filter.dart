// lib/models/filter.dart

import 'package:flutter/widgets.dart';

import '../l10n/l10n.dart';
import 'json_utils.dart';

/// Mastodon Filters v2 のフィルタ。
///
/// クラス名は Dart 標準ライブラリの `Filter` (Stream) と紛らわしいので
/// `MastodonFilter` にしている。
class MastodonFilter {
  final String id;
  final String title;

  /// 適用先コンテキスト。`'home'` / `'notifications'` / `'public'` / `'thread'`
  /// / `'account'` のいずれかが入る (複数可)。
  final List<String> context;

  /// 失効時刻。null なら無期限。
  final DateTime? expiresAt;

  /// マッチ時の挙動。`'warn'` (タイムラインで警告表示) / `'hide'` (非表示) のいずれか。
  final String filterAction;

  final List<FilterKeyword> keywords;
  final List<FilterStatus> statuses;

  MastodonFilter({
    required this.id,
    required this.title,
    required this.context,
    this.expiresAt,
    required this.filterAction,
    this.keywords = const [],
    this.statuses = const [],
  });

  factory MastodonFilter.fromJson(Map<String, dynamic> json) {
    return MastodonFilter(
      id: asIdString(json['id']),
      title: (json['title'] as String?) ?? '',
      context: ((json['context'] as List<dynamic>?) ?? const [])
          .map((e) => e as String)
          .toList(),
      expiresAt: json['expires_at'] != null
          ? DateTime.tryParse(json['expires_at'] as String)
          : null,
      filterAction: (json['filter_action'] as String?) ?? 'warn',
      keywords: ((json['keywords'] as List<dynamic>?) ?? const [])
          .map((k) => FilterKeyword.fromJson(k as Map<String, dynamic>))
          .toList(),
      statuses: ((json['statuses'] as List<dynamic>?) ?? const [])
          .map((s) => FilterStatus.fromJson(s as Map<String, dynamic>))
          .toList(),
    );
  }

  /// 失効済みかどうか
  bool get isExpired {
    final e = expiresAt;
    return e != null && e.isBefore(DateTime.now());
  }
}

/// フィルタに含まれる個別キーワード。
class FilterKeyword {
  final String id;
  final String keyword;

  /// 全単語一致 (true) か部分一致 (false) か。
  final bool wholeWord;

  FilterKeyword({
    required this.id,
    required this.keyword,
    required this.wholeWord,
  });

  factory FilterKeyword.fromJson(Map<String, dynamic> json) {
    return FilterKeyword(
      id: asIdString(json['id']),
      keyword: (json['keyword'] as String?) ?? '',
      wholeWord: (json['whole_word'] as bool?) ?? false,
    );
  }
}

/// 特定投稿を直接フィルタに登録する仕組み。
/// (Kurage では現状 UI 未対応だが、サーバから来た値は保持する)
class FilterStatus {
  final String id;
  final String statusId;

  FilterStatus({required this.id, required this.statusId});

  factory FilterStatus.fromJson(Map<String, dynamic> json) {
    return FilterStatus(
      id: asIdString(json['id']),
      statusId: asIdStringOrNull(json['status_id']) ?? '',
    );
  }
}

/// Status / Notification にネストして返ってくる `filtered` フィールドの 1 要素。
///
/// 各 Status に対し「マッチしたフィルタ + マッチしたキーワード/投稿」がぶら下がる。
/// クライアントは `filter.filterAction` を見て表示挙動を決める。
class FilterResult {
  final MastodonFilter filter;
  final List<String> keywordMatches;
  final List<String> statusMatches;

  FilterResult({
    required this.filter,
    this.keywordMatches = const [],
    this.statusMatches = const [],
  });

  factory FilterResult.fromJson(Map<String, dynamic> json) {
    return FilterResult(
      filter: MastodonFilter.fromJson(json['filter'] as Map<String, dynamic>),
      keywordMatches: ((json['keyword_matches'] as List<dynamic>?) ?? const [])
          .map((e) => e as String)
          .toList(),
      statusMatches: ((json['status_matches'] as List<dynamic>?) ?? const [])
          .map((e) => e as String)
          .toList(),
    );
  }
}

/// フィルタコンテキストの全候補とラベル。UI で multi-select するときに使う。
/// `context.l10n` を参照するため const にはできない。
Map<String, String> kFilterContextLabels(BuildContext context) => {
      'home': context.l10n.filterCtxHome,
      'notifications': context.l10n.filterCtxNotifications,
      'public': context.l10n.filterCtxPublic,
      'thread': context.l10n.filterCtxThread,
      'account': context.l10n.filterCtxAccount,
    };

/// フィルタアクションの全候補とラベル。
Map<String, String> kFilterActionLabels(BuildContext context) => {
      'warn': context.l10n.filterActionWarn,
      'hide': context.l10n.filterActionHide,
    };
