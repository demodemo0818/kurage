// lib/models/status.dart

import 'account.dart';
import 'emoji.dart';
import 'filter.dart';
import 'json_utils.dart';
import 'media_attachment.dart';
import 'poll.dart';
import 'preview_card.dart';
import 'quote.dart';

/// 投稿データモデル
class Status {
  final String id;
  final String content;            // HTML を含む
  final DateTime createdAt;
  final Account account;
  final Status? reblog;
  final List<MediaAttachment> mediaAttachments;
  final String spoilerText;        // CW テキスト
  final String visibility;
  final bool favourited;
  final bool reblogged;
  final bool bookmarked;

  /// 自分のプロフィールに固定されているか (`pinned`)。
  ///
  /// Mastodon 仕様では「自分の投稿で、自分自身が見ているとき」だけサーバから
  /// `pinned` フィールドが返る (他人視点では存在しない)。後者の場合の安全側の
  /// デフォルトは false。
  final bool pinned;

  final List<Emoji> emojis;

  /// NSFW（sensitive）フラグ
  final bool sensitive;

  /// in_reply_to_id
  final String? inReplyToId;

  /// 投票
  final Poll? poll;

  /// リアクション数
  final int reblogsCount;
  final int favouritesCount;

  /// ステータスのURL（元のインスタンス情報取得用）
  final String? url;
  final String? uri;

  /// 公式引用 (Mastodon 4.4+)。古いインスタンスや未対応サーバでは null。
  final Quote? quote;

  /// OGP プレビュー情報 (サーバ側で取得済み、クライアントは再取得不要)
  final PreviewCard? card;

  /// 投稿元アプリ名 (`application.name`)。Web 投稿等では null/空のことがある
  final String? applicationName;

  /// 投稿元アプリの公式サイト URL (`application.website`)
  final String? applicationWebsite;

  /// 投稿言語 (ISO 639)。投稿編集時にこの値を初期言語として復元する。
  /// サーバが返さないケース (古いインスタンス等) は null。
  final String? language;

  /// 最終編集時刻 (`edited_at`)。一度も編集されていなければ null。
  /// 投稿が編集済みかどうかの判定と、UI で「編集済み (XX 分前)」を出すのに使う。
  final DateTime? editedAt;

  /// サーバ側のフィルタマッチ結果 (Mastodon Filters v2 の `filtered` フィールド)。
  ///
  /// 受信したタイムライン/通知の各投稿について、ユーザーのフィルタにマッチした
  /// ら FilterResult のリストがぶら下がる。空または null なら無マッチ。
  /// クライアントは [isFilterHidden] / [isFilterWarned] / [filterDisplayTitle] を
  /// 使って表示挙動を決める。
  final List<FilterResult> filtered;

  Status({
    required this.id,
    required this.content,
    required this.createdAt,
    required this.account,
    this.reblog,
    this.mediaAttachments = const [],
    this.spoilerText = '',
    required this.visibility,
    required this.favourited,
    required this.reblogged,
    required this.bookmarked,
    this.pinned = false,
    this.emojis = const [],
    this.sensitive = false,       // デフォルト false
    this.inReplyToId,
    this.poll,
    this.reblogsCount = 0,
    this.favouritesCount = 0,
    this.url,
    this.uri,
    this.quote,
    this.card,
    this.applicationName,
    this.applicationWebsite,
    this.language,
    this.editedAt,
    this.filtered = const [],
  });

  factory Status.fromJson(Map<String, dynamic> json) {
    final ems = (json['emojis'] as List<dynamic>?)
            ?.map((e) => Emoji.fromJson(e as Map<String, dynamic>))
            .toList() ??
        <Emoji>[];

    return Status(
      // 派生サーバは ID を JSON int で返すことがある。account 欠落だけは
      // 表示不能なので throw のまま (リスト系デコーダが 1 件単位で skip する)。
      id: asIdString(json['id']),
      content: json['content'] as String? ?? '',
      createdAt: parseDateTimeOr(json['created_at']),
      account: Account.fromJson(json['account'] as Map<String, dynamic>),
      reblog: json['reblog'] != null
          ? Status.fromJson(json['reblog'] as Map<String, dynamic>)
          : null,
      mediaAttachments: (json['media_attachments'] as List<dynamic>?)
              ?.map((m) => MediaAttachment.fromJson(m as Map<String, dynamic>))
              .toList() ??
          <MediaAttachment>[],
      spoilerText: (json['spoiler_text'] as String?) ?? '',
      visibility: (json['visibility'] as String?) ?? 'public',
      favourited: (json['favourited'] as bool?) ?? false,
      reblogged: (json['reblogged'] as bool?) ?? false,
      bookmarked: (json['bookmarked'] as bool?) ?? false,
      pinned: (json['pinned'] as bool?) ?? false,
      emojis: ems,
      sensitive: (json['sensitive'] as bool?) ?? false,
      inReplyToId: asIdStringOrNull(json['in_reply_to_id']),
      poll: json['poll'] != null 
          ? Poll.fromJson(json['poll'] as Map<String, dynamic>)
          : null,
      reblogsCount: (json['reblogs_count'] as int?) ?? 0,
      favouritesCount: (json['favourites_count'] as int?) ?? 0,
      url: json['url'] as String?,
      uri: json['uri'] as String?,
      quote: json['quote'] != null
          ? Quote.fromJson(json['quote'] as Map<String, dynamic>)
          : null,
      card: json['card'] != null
          ? PreviewCard.fromJson(json['card'] as Map<String, dynamic>)
          : null,
      applicationName: json['application'] is Map<String, dynamic>
          ? (json['application'] as Map<String, dynamic>)['name'] as String?
          : null,
      applicationWebsite: json['application'] is Map<String, dynamic>
          ? (json['application'] as Map<String, dynamic>)['website'] as String?
          : null,
      language: json['language'] as String?,
      editedAt: json['edited_at'] != null
          ? DateTime.tryParse(json['edited_at'] as String)
          : null,
      filtered: (json['filtered'] as List<dynamic>?)
              ?.map((f) => FilterResult.fromJson(f as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }

  /// このステータスに該当するフィルタのうち `filter_action == 'hide'` を
  /// 持つものがあるか。失効済みフィルタは除外。
  bool get isFilterHidden {
    for (final f in filtered) {
      if (f.filter.isExpired) continue;
      if (f.filter.filterAction == 'hide') return true;
    }
    return false;
  }

  /// `filter_action == 'warn'` のフィルタが当たっているか。
  bool get isFilterWarned {
    for (final f in filtered) {
      if (f.filter.isExpired) continue;
      if (f.filter.filterAction == 'warn') return true;
    }
    return false;
  }

  /// 警告表示用の「フィルタ条件: XX」テキスト。最初に当たっている
  /// `warn` フィルタのタイトルを返す。
  String? get filterDisplayTitle {
    for (final f in filtered) {
      if (f.filter.isExpired) continue;
      if (f.filter.filterAction == 'warn') return f.filter.title;
    }
    return null;
  }

  /// 公式引用が承認済みか
  bool get hasAcceptedQuote =>
      quote != null && quote!.state == QuoteState.accepted && quote!.quotedStatus != null;

  /// 公式引用フィールドが存在する (Mastodon 4.4+)
  bool get hasOfficialQuote => quote != null;

  /// 何らかの引用がある (公式引用 or Misskey/Fedibird 形式)
  bool get hasAnyQuote => hasOfficialQuote || isQuoteRenote;

  /// リブログ判定
  bool get isReblog => reblog != null;

  // 引用リノート判定用の正規表現はモジュールレベルで一度だけコンパイル
  // (タイムライン描画中に各投稿で繰り返し評価されるため)
  static final _quoteMarker =
      RegExp(r'(?:RE|QT):', caseSensitive: false);
  static final _quotePatterns = [
    RegExp(r'^RE:\s*https?://[^\s<>]+', caseSensitive: false),
    RegExp(r'^QT:\s*https?://[^\s<>]+', caseSensitive: false),
    RegExp(r'RE:\s*https?://[^\s<>]+', caseSensitive: false),
    RegExp(r'QT:\s*https?://[^\s<>]+', caseSensitive: false),
    RegExp(r'^https?://[^\s<>]+\s*RE:', caseSensitive: false),
    RegExp(r'^https?://[^\s<>]+\s*QT:', caseSensitive: false),
  ];
  static final _quoteUrlExtractors = [
    RegExp(r'RE:\s*(https?://[^\s<>]+)', caseSensitive: false),
    RegExp(r'QT:\s*(https?://[^\s<>]+)', caseSensitive: false),
    RegExp(r'(https?://[^\s<>]+)\s*RE:', caseSensitive: false),
    RegExp(r'(https?://[^\s<>]+)\s*QT:', caseSensitive: false),
    RegExp(r'(https?://[^\s<>]+)', caseSensitive: false),
  ];
  static final _htmlTag = RegExp(r'<[^>]*>');

  /// 引用リノート判定（Misskey/Fedibird 等の「RE: URL」「QT: URL」形式）
  bool get isQuoteRenote {
    if (content.isEmpty) return false;
    // 早期 return: そもそも RE:/QT: マーカーが存在しないなら確実に false
    // 通常投稿はここで弾けるので HTML 除去や 6 個のパターン照合をスキップできる
    if (!_quoteMarker.hasMatch(content)) return false;

    final plainText = _stripHtmlEntities(content);
    for (final pattern in _quotePatterns) {
      if (pattern.hasMatch(plainText)) return true;
    }
    return false;
  }

  /// 引用元URLを取得（引用リノートの場合）
  String? get quotedUrl {
    if (!isQuoteRenote) return null;
    final plainText = _stripHtmlEntities(content);
    for (final pattern in _quoteUrlExtractors) {
      final match = pattern.firstMatch(plainText);
      if (match != null) return match.group(1);
    }
    return null;
  }

  /// HTML タグ除去 + よく使う entity デコード (引用判定用の共通処理)
  static String _stripHtmlEntities(String html) {
    return html
        .replaceAll(_htmlTag, '')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .trim();
  }

  /// HTML タグを除去した本文テキスト
  String get cleanedContent =>
      content.replaceAll(RegExp(r'<[^>]*>'), '');
}
