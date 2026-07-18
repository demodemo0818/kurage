// lib/services/mastodon_api.dart

import 'dart:async';
import 'dart:convert';

import 'package:cross_file/cross_file.dart';
import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';
import 'package:http_parser/http_parser.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter/foundation.dart';

import 'sse_client.dart';

import '../models/status.dart';
import '../models/account.dart';
import '../models/notification_item.dart';
import '../models/relationship.dart';
import '../models/status_context.dart';
import '../models/status_edit.dart';
import '../models/emoji.dart';
import '../models/announcement.dart';
import '../models/poll.dart';
import '../models/conversation.dart';
import '../models/mastodon_list.dart';
import '../models/instance_rule.dart';
import '../models/filter.dart';
import '../models/notification_group.dart';
import '../models/profile.dart';
import '../models/collection.dart';
import '../models/annual_report.dart';
import '../pages/search_page.dart';
import '../utils/bounded_collections.dart';

/// HTTP クライアントの注入口 (テスト用 seam)。
///
/// 本ファイルの API 関数は全てこのクライアント経由で HTTP を叩く。
/// プロダクションでは素の [http.Client] のままで挙動は従来と同一。
/// テストからは `package:http/testing.dart` の `MockClient` 等に差し替える
/// ことで、API レイヤーやその上のプロバイダ (競合・状態遷移) を偽レスポンス
/// で検証できる。flutter_test 環境は実ネットワークを遮断する (全リクエストが
/// 400 になる) ため、この seam がないと「失敗ケース」しかテストできない。
@visibleForTesting
http.Client httpClient = http.Client();

/// キャッシュ用ボックス (String: 生 JSON)
final _cacheBox = Hive.box<String>('timelineCache');

/// `compute()` 用の isolate-safe な JSON → `List<Status>` デコーダ。
///
/// `jsonDecode` (~ms) + `Status.fromJson` × 40 件 (~50〜200ms) を UI スレッド
/// で実行すると、引っ張って更新 / loadMore / initial load のタイミングで
/// フレーム予算を直撃して「待たされる」体感の原因になる。`compute()` 経由で
/// background isolate に逃がすことで UI スレッドはレスポンシブを保つ。
///
/// 1 件パース失敗してもリスト全体は返す (malformed entry はスキップ)。
/// 旧実装の per-item debugPrint は isolate 越境を避けるため省略。
List<Status> _decodeStatusListIsolate(String body) {
  final list = jsonDecode(body) as List<dynamic>;
  final statuses = <Status>[];
  for (int i = 0; i < list.length; i++) {
    try {
      statuses.add(Status.fromJson(list[i] as Map<String, dynamic>));
    } catch (_) {
      // skip malformed
    }
  }
  return statuses;
}

/// `compute()` 用 `List<Account>` デコーダ。フォロー/フォロワー/ブースト等で使う。
List<Account> _decodeAccountListIsolate(String body) {
  final list = jsonDecode(body) as List<dynamic>;
  final accounts = <Account>[];
  for (int i = 0; i < list.length; i++) {
    try {
      accounts.add(Account.fromJson(list[i] as Map<String, dynamic>));
    } catch (_) {
      // skip malformed
    }
  }
  return accounts;
}

// `NotificationItem.listFromJson` を `compute()` に直接渡しているので
// _decodeNotificationListIsolate は不要 (削除済み)。

/// キャッシュ最大エントリ数 (FIFO エビクション)。
///
/// 1 エントリは limit=40 のタイムライン JSON で平均 50〜300KB。50 エントリ
/// なら最大 15MB 程度。Hive は `box.keys` が insertion order を保つので、
/// 最古のキーから順に削除する単純な FIFO で十分。
const int _maxCacheEntries = 50;

/// 新キャッシュキーのプレフィックス。`migrateCacheKeysIfNeeded` での
/// 旧キー (`timeline_*` / `account_*_statuses`) 検出に使う。
const _kCachePrefixes = ['tl:', 'acct:'];

/// エラー時の `resp.body` をスナックバー表示用に短く整形する。
///
/// Mastodon サーバは正常時に `{"error":"..."}` 形式の JSON を返すが、500 や
/// Cloudflare 経由のエラーでは丸ごと HTML を返してくることがあり、それを
/// そのまま例外メッセージに入れると画面いっぱいに HTML タグが展開されて
/// 何が起きたか分からなくなる (実害として 2026-05 にユーザーから報告)。
///
/// 優先度:
/// 1. JSON で `error` キーが取れればそれを返す (Mastodon の通常エラー)
/// 2. それ以外で `<` 始まりなら HTML 扱いで「(HTML レスポンス、N bytes)」に潰す
/// 3. それ以外は 200 文字までトリミング
String _summarizeErrorBody(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return '(本文なし)';

  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map && decoded['error'] is String) {
      final err = decoded['error'] as String;
      final desc = decoded['error_description'];
      return desc is String ? '$err: $desc' : err;
    }
  } catch (_) {
    // JSON ではない (HTML / プレーンテキスト) なので下の分岐に流す
  }

  if (trimmed.startsWith('<')) {
    return '(HTML レスポンス、${body.length} bytes)';
  }

  if (trimmed.length > 200) {
    return '${trimmed.substring(0, 200)}…';
  }
  return trimmed;
}

/// instanceUrl をキャッシュキーに埋め込める形へ正規化する。
///
/// 旧実装は `instanceUrl.hashCode` を使っていたが、Dart の String ハッシュは
/// SDK 実装依存で永続キーには不向き (SDK 更新でキーが変わり既存キャッシュが
/// 全ミスになる)。URL 文字列から英数 / `.` / `-` 以外を落として直接使う。
String _cacheKeyHost(String instanceUrl) =>
    instanceUrl.replaceAll(RegExp(r'[^a-zA-Z0-9.\-]'), '');

/// `put` 後に LRU 上限を超えていたら最古のエントリを削除する。
///
/// 既存実装は `_cacheBox.put` を await せずに fire-and-forget していたので
/// それに揃える (本キャッシュは fallback 用途で、書き込み完了を呼び出し側が
/// 待つ意味はない)。エビクションも同様 non-blocking。
void _writeCache(String key, String value) {
  _cacheBox.put(key, value);
  // Hive の `keys` は insertion order なので先頭が最古。書き直し (update)
  // が末尾に移るのは LinkedHashMap 由来の挙動。
  while (_cacheBox.length > _maxCacheEntries) {
    final oldest = _cacheBox.keys.first;
    if (oldest == key) break; // 念のため自分自身は消さない
    _cacheBox.delete(oldest);
  }
}

/// 起動時に呼んで旧形式のキャッシュキーを掃除する。
///
/// 旧 `timeline_$type` キーは複数アカウントで衝突しており、内容が
/// 信頼できないため一度全消去して fresh fetch に任せる。
/// `account_${id}_statuses` も `onlyMedia` の有無を区別していなかった
/// ので同様。新形式 (`tl:` / `acct:` プレフィックス) のキーは残す。
void migrateCacheKeysIfNeeded() {
  final toDelete = <dynamic>[];
  for (final k in _cacheBox.keys) {
    if (k is! String) {
      toDelete.add(k);
      continue;
    }
    final isNewFormat = _kCachePrefixes.any(k.startsWith);
    if (!isNewFormat) toDelete.add(k);
  }
  for (final k in toDelete) {
    _cacheBox.delete(k);
  }
}

/// インスタンス設定
/// Mastodon の version 文字列 (例: "4.6.0", "4.6.1+glitch",
/// "2.7.2 (compatible; Pleroma 2.5.0)") の先頭 "major.minor" を取り出し、
/// [major].[minor] 以上かを判定する。先頭が "数値.数値" でない (version を
/// 解釈できない互換実装など) ときは false。コレクション等 4.6 固有機能の
/// 出し分けに使うので、判定不能なら「未対応」に倒す方が安全。
bool mastodonVersionAtLeast(String version, int major, int minor) {
  final m = RegExp(r'^\s*(\d+)\.(\d+)').firstMatch(version);
  if (m == null) return false;
  final maj = int.parse(m.group(1)!);
  final min = int.parse(m.group(2)!);
  if (maj != major) return maj > major;
  return min >= minor;
}

class InstanceConfig {
  final int maxTootChars;
  final bool translationEnabled;

  // Mastodon 4.6+: configuration.accounts 配下のプロフィール編集上限。
  // 古いサーバでは欠落するので、従来 UI のハードコード値をデフォルトにする。
  final int maxNoteLength; // 自己紹介の最大文字数
  final int maxDisplayNameLength; // 表示名の最大文字数
  final int maxProfileFields; // プロフィール補足フィールドの最大数
  final int profileFieldNameLimit; // 補足フィールド名の最大文字数
  final int profileFieldValueLimit; // 補足フィールド値の最大文字数

  /// Mastodon 4.6 で追加された `configuration.accounts` を持つか。
  /// コレクション (accounts/:id/collections) や投稿タブの DM 除外フィルタ
  /// (exclude_direct) など 4.6 世代のプロフィール機能に対応しているかの目安。
  /// 古いサーバ / 互換実装では欠落するので false になり、対応 UI を隠せる。
  final bool supportsV46AccountFeatures;

  InstanceConfig({
    required this.maxTootChars,
    this.translationEnabled = false,
    this.maxNoteLength = 500,
    this.maxDisplayNameLength = 30,
    this.maxProfileFields = 4,
    this.profileFieldNameLimit = 255,
    this.profileFieldValueLimit = 255,
    this.supportsV46AccountFeatures = false,
  });

  factory InstanceConfig.fromJson(Map<String, dynamic> json) {
    // 現代のMastodon APIではconfiguration.statuses.max_charactersを使用
    int maxChars = 500; // デフォルト値
    bool translationEnabled = false;
    int maxNoteLength = 500;
    int maxDisplayNameLength = 30;
    int maxProfileFields = 4;
    int profileFieldNameLimit = 255;
    int profileFieldValueLimit = 255;
    bool supportsV46AccountFeatures = false;

    // 新しいAPI構造を試す
    if (json['configuration'] != null) {
      final config = json['configuration'] as Map<String, dynamic>;

      // 文字数制限
      if (config['statuses'] != null &&
          config['statuses']['max_characters'] != null) {
        maxChars = config['statuses']['max_characters'] as int;
      }

      // 翻訳機能の有効確認
      if (config['translation'] != null &&
          config['translation']['enabled'] != null) {
        translationEnabled = config['translation']['enabled'] as bool;
      }

      // プロフィール編集上限 (Mastodon 4.6+, configuration.accounts)
      final accounts = config['accounts'];
      if (accounts is Map<String, dynamic>) {
        maxNoteLength =
            (accounts['max_note_length'] as int?) ?? maxNoteLength;
        maxDisplayNameLength =
            (accounts['max_display_name_length'] as int?) ??
                maxDisplayNameLength;
        maxProfileFields =
            (accounts['max_profile_fields'] as int?) ?? maxProfileFields;
        profileFieldNameLimit =
            (accounts['profile_field_name_limit'] as int?) ??
                profileFieldNameLimit;
        profileFieldValueLimit =
            (accounts['profile_field_value_limit'] as int?) ??
                profileFieldValueLimit;
      }
    }
    // 古いAPI構造を試す（後方互換性のため）
    else if (json['max_toot_chars'] != null) {
      maxChars = json['max_toot_chars'] as int;
    }
    // Pleromaなどの別の構造を試す
    else if (json['max_characters'] != null) {
      maxChars = json['max_characters'] as int;
    }

    // 4.6 世代のプロフィール機能 (コレクション / DM 除外フィルタ) の対応判定は
    // version 文字列で行う。configuration.accounts は max_featured_tags 等の
    // ために 4.6 より前から存在するため、その有無では判定できない。
    final versionStr = json['version']?.toString() ?? '';
    supportsV46AccountFeatures = mastodonVersionAtLeast(versionStr, 4, 6);

    return InstanceConfig(
      maxTootChars: maxChars,
      translationEnabled: translationEnabled,
      maxNoteLength: maxNoteLength,
      maxDisplayNameLength: maxDisplayNameLength,
      maxProfileFields: maxProfileFields,
      profileFieldNameLimit: profileFieldNameLimit,
      profileFieldValueLimit: profileFieldValueLimit,
      supportsV46AccountFeatures: supportsV46AccountFeatures,
    );
  }
}

/// 投稿をお気に入り／解除
Future<void> toggleFavourite({
  required String instanceUrl,
  required String accessToken,
  required String statusId,
  required bool currentlyFavourited,
}) async {
  final endpoint = currentlyFavourited
      ? '/api/v1/statuses/$statusId/unfavourite'
      : '/api/v1/statuses/$statusId/favourite';
  final uri = Uri.parse('$instanceUrl$endpoint');
  final resp = await httpClient.post(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw Exception('お気に入り操作失敗: ${resp.statusCode}');
  }
}

/// 投稿をブースト／解除
Future<void> toggleReblog({
  required String instanceUrl,
  required String accessToken,
  required String statusId,
  required bool currentlyReblogged,
}) async {
  final endpoint = currentlyReblogged
      ? '/api/v1/statuses/$statusId/unreblog'
      : '/api/v1/statuses/$statusId/reblog';
  final uri = Uri.parse('$instanceUrl$endpoint');
  final resp = await httpClient.post(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw Exception('ブースト操作失敗: ${resp.statusCode}');
  }
}

/// 自分の投稿をプロフィールにピン留め／解除する
/// (`POST /api/v1/statuses/:id/pin` / `unpin`)。
///
/// Mastodon 仕様の制約:
///  - 自分の投稿でしかピンできない (他人の投稿だと 422)。
///  - 同時にピンできるのは 5 件まで。超えると 422 が返るので、呼び出し側で
///    SnackBar 等にエラー文言を出すこと。
///  - public / unlisted 以外 (フォロワー限定 / DM 等) はピンできない。
class PinStatusLimitException implements Exception {
  final String message;
  PinStatusLimitException(this.message);
  @override
  String toString() => message;
}

Future<void> togglePin({
  required String instanceUrl,
  required String accessToken,
  required String statusId,
  required bool currentlyPinned,
}) async {
  final endpoint = currentlyPinned
      ? '/api/v1/statuses/$statusId/unpin'
      : '/api/v1/statuses/$statusId/pin';
  final uri = Uri.parse('$instanceUrl$endpoint');
  final resp = await httpClient.post(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode == 422) {
    // 422 は「上限超過」「フォロワー限定投稿」「他人の投稿」など複合的だが、
    // ピンの文脈で一番起きやすいのは上限超過 (5 件) なので、それ風のメッセージ
    // をデフォルトにする。サーバが返した本文は呼び出し側の SnackBar には乗せ
    // ないが、デバッグ時に拾えるよう例外には含めておく。
    throw PinStatusLimitException(
        'ピン留めできません (上限 5 件 / 投稿の公開範囲に注意): ${resp.body}');
  }
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw Exception('ピン留め操作失敗: ${resp.statusCode}');
  }
}

/// 投稿をブックマーク／解除
Future<void> toggleBookmark({
  required String instanceUrl,
  required String accessToken,
  required String statusId,
  required bool currentlyBookmarked,
}) async {
  final endpoint = currentlyBookmarked
      ? '/api/v1/statuses/$statusId/unbookmark'
      : '/api/v1/statuses/$statusId/bookmark';
  final uri = Uri.parse('$instanceUrl$endpoint');
  final resp = await httpClient.post(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw Exception('ブックマーク操作失敗: ${resp.statusCode}');
  }
}

/// インスタンス設定の in-memory キャッシュ。
/// 文字数上限などインスタンス毎の設定はめったに変わらないので、同一プロセス
/// 内では一度取得したら使い回す (アプリ起動毎に再取得)。
final Map<String, InstanceConfig> _instanceConfigCache = {};

/// キャッシュをクリアするテスト用 / 設定変更時用フック (現状未使用)。
// ignore: unused_element
void clearInstanceConfigCache() => _instanceConfigCache.clear();

/// インスタンス設定を取得 (in-memory キャッシュ付き)。
Future<InstanceConfig> fetchInstanceConfig({
  required String instanceUrl,
  required String accessToken,
}) async {
  final cached = _instanceConfigCache[instanceUrl];
  if (cached != null) return cached;

  // まずv2 APIを試す（翻訳機能の情報を含む）
  try {
    final v2Uri = Uri.parse('$instanceUrl/api/v2/instance');
    final v2Resp = await httpClient.get(
      v2Uri,
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    if (v2Resp.statusCode == 200) {
      final cfg = InstanceConfig.fromJson(
        jsonDecode(v2Resp.body) as Map<String, dynamic>,
      );
      _instanceConfigCache[instanceUrl] = cfg;
      return cfg;
    }
  } catch (_) {
    // v2 APIが失敗した場合はv1にフォールバック
  }

  // v1 APIにフォールバック
  final uri = Uri.parse('$instanceUrl/api/v1/instance');
  final resp = await httpClient.get(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode == 200) {
    final cfg = InstanceConfig.fromJson(
      jsonDecode(resp.body) as Map<String, dynamic>,
    );
    _instanceConfigCache[instanceUrl] = cfg;
    return cfg;
  } else {
    throw Exception('インスタンス情報取得失敗: ${resp.statusCode}');
  }
}

/// メディア処理ステータスをチェック
Future<bool> _checkMediaProcessingStatus({
  required String instanceUrl,
  required String accessToken,
  required String mediaId,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/media/$mediaId');
  final resp = await httpClient.get(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  
  if (resp.statusCode == 200) {
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final url = json['url'] as String?;
    return url != null && url.isNotEmpty;
  }
  return false;
}

/// 動画処理完了まで待機
Future<void> _waitForMediaProcessing({
  required String instanceUrl,
  required String accessToken,
  required String mediaId,
}) async {
  int attempts = 0;
  const maxAttempts = 30; // 最大30秒待機
  const delay = Duration(seconds: 1);
  
  while (attempts < maxAttempts) {
    final isReady = await _checkMediaProcessingStatus(
      instanceUrl: instanceUrl,
      accessToken: accessToken,
      mediaId: mediaId,
    );
    
    if (isReady) {
      return; // 処理完了
    }
    
    await Future.delayed(delay);
    attempts++;
  }
  
  // タイムアウト時はWarningを出すが処理は継続
  if (kDebugMode) print('Warning: Media processing timeout for $mediaId');
}

/// メディアをアップロードして media_id を返す。
///
/// Web では `file.path` が `blob:` URL になるため `MultipartFile.fromPath` は
/// 使えない。XFile.readAsBytes() でバイト列を得て `MultipartFile.fromBytes` に
/// 渡す。mime type は XFile が image_picker / file_selector から受け取った
/// `mimeType` を最優先、無ければ拡張子から推定、最後の砦は octet-stream。
Future<String> uploadMedia({
  required String instanceUrl,
  required String accessToken,
  required XFile file,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v2/media');
  final req = http.MultipartRequest('POST', uri)
    ..headers['Authorization'] = 'Bearer $accessToken';

  final mimeType = file.mimeType ??
      lookupMimeType(file.name) ??
      'application/octet-stream';
  final parts = mimeType.split('/');
  final bytes = await file.readAsBytes();
  // filename が空だと Mastodon (Rails) がマルチパートを「ファイル」と認識せず
  // 422 "File can't be blank" になる。cross_file の `XFile.fromData` は io
  // (Windows/デスクトップ) 実装で name を保持しない (path から導出するため、
  // path 無しだと name が空) ので、クリップボード貼り付け等で空になりうる。
  // 空のときは MIME サブタイプから補う。
  final filename = file.name.isNotEmpty
      ? file.name
      : 'upload.${parts.length > 1 ? parts[1] : 'bin'}';
  req.files.add(http.MultipartFile.fromBytes(
    'file',
    bytes,
    filename: filename,
    contentType: MediaType(parts[0], parts[1]),
  ));

  final streamed = await httpClient.send(req);
  final resp = await http.Response.fromStream(streamed);
  if (resp.statusCode == 200 || resp.statusCode == 202) {
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final mediaId = json['id'].toString();
    
    // 動画の場合は処理完了を待つ
    if (mimeType.startsWith('video/')) {
      await _waitForMediaProcessing(
        instanceUrl: instanceUrl,
        accessToken: accessToken,
        mediaId: mediaId,
      );
    }
    
    return mediaId;
  } else {
    // サーバの検証メッセージ (例: 422 の "Validation failed: ...") を含めて
    // 原因を追えるようにする。Mastodon のエラーボディは UTF-8 JSON。
    String detail;
    try {
      detail = utf8.decode(resp.bodyBytes);
    } catch (_) {
      detail = resp.body;
    }
    if (detail.length > 300) detail = '${detail.substring(0, 300)}…';
    throw Exception('メディアアップロード失敗: ${resp.statusCode} $detail');
  }
}

/// メディアのALT文を更新
Future<void> updateMediaDescription({
  required String instanceUrl,
  required String accessToken,
  required String mediaId,
  required String description,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/media/$mediaId');
  final headers = {
    'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/x-www-form-urlencoded',
  };

  final body = 'description=${Uri.encodeQueryComponent(description)}';

  final resp = await httpClient.put(
    uri,
    headers: headers,
    body: body,
  );

  if (resp.statusCode != 200) {
    throw Exception('ALT文の更新失敗: ${resp.statusCode}');
  }
}

/// 投稿 API 呼び出し
Future<Status> postStatus({
  required String instanceUrl,
  required String accessToken,
  required String statusText,
  String visibility = 'public',
  List<String>? mediaIds,
  String? spoilerText,
  String? inReplyToId,
  PollData? poll,
  bool sensitive = false,
  String? language,
  DateTime? scheduledAt,
  String? quotedStatusId, // Mastodon 4.4+ 公式引用用
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/statuses');
  final headers = {
    'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/x-www-form-urlencoded',
  };

  final parts = <String>[
    'status=${Uri.encodeQueryComponent(statusText)}',
    'visibility=${Uri.encodeQueryComponent(visibility)}',
    if (spoilerText != null && spoilerText.isNotEmpty)
      'spoiler_text=${Uri.encodeQueryComponent(spoilerText)}',
    if (inReplyToId != null)
      'in_reply_to_id=${Uri.encodeQueryComponent(inReplyToId)}',
    if (mediaIds != null)
      for (var id in mediaIds) 'media_ids[]=${Uri.encodeQueryComponent(id)}',
    if (poll != null) ...[
      for (var option in poll.options) 'poll[options][]=${Uri.encodeQueryComponent(option)}',
      'poll[expires_in]=${poll.expiresInSeconds}',
      'poll[multiple]=${poll.multiple}',
      'poll[hide_totals]=${poll.hideTotals}',
    ],
    if (sensitive) 'sensitive=true',
    if (language != null) 'language=${Uri.encodeQueryComponent(language)}',
    if (scheduledAt != null) 'scheduled_at=${Uri.encodeQueryComponent(scheduledAt.toUtc().toIso8601String())}',
    if (quotedStatusId != null) 'quoted_status_id=${Uri.encodeQueryComponent(quotedStatusId)}',
  ];

  final req = http.Request('POST', uri)
    ..headers.addAll(headers)
    ..body = parts.join('&');

  final streamed = await httpClient.send(req);
  final resp = await http.Response.fromStream(streamed);


  if (resp.statusCode == 200 || resp.statusCode == 202) {
    try {
      final responseBody = jsonDecode(resp.body) as Map<String, dynamic>;
      
      // 予約投稿の場合は特別な処理をする（通常のStatusオブジェクトとは構造が異なるため）
      if (scheduledAt != null) {
        
        // 予約投稿専用の成功レスポンスを作成（Status.fromJsonを使わずに直接作成）
        return _createScheduledPostStatus(
          responseBody: responseBody,
          statusText: statusText,
          visibility: visibility,
          sensitive: sensitive,
          spoilerText: spoilerText,
          scheduledAt: scheduledAt,
        );
      }
      
      return Status.fromJson(responseBody);
    } catch (e) {
      // 予約投稿の場合、レスポンス解析に失敗しても投稿は成功している可能性が高い
      if (scheduledAt != null) {
        return _createScheduledPostStatus(
          responseBody: {},
          statusText: statusText,
          visibility: visibility,
          sensitive: sensitive,
          spoilerText: spoilerText,
          scheduledAt: scheduledAt,
        );
      }
      
      throw Exception('投稿成功だがレスポンス解析失敗: $e');
    }
  } else {
    throw Exception('投稿失敗: ${resp.statusCode} ${_summarizeErrorBody(resp.body)}');
  }
}

/// 投稿の編集 (Mastodon 4.x+ `PUT /api/v1/statuses/:id`)。
///
/// 仕様上の制約:
/// - **`visibility` は変更できない**。サーバ側で固定のため、引数では受け取らない。
/// - **`in_reply_to_id` / `quoted_status_id` も変更不可** (返信先や引用先を後から
///   付け替えるのは禁止)。同様に引数に含めない。
/// - **`scheduled_at` は edit では使えない**。予約投稿の再スケジュールは別エンド
///   ポイント (`PUT /api/v1/scheduled_statuses/:id`) で行う。
///
/// `media_ids` には現状この投稿に紐づけたい media id を全て含める (= 既存の
/// 添付を残したい場合もそれらを含む)。`media_ids` に渡さなかった既存添付は
/// 投稿から外れる。新規添付したい場合は事前に [uploadMedia] で id を取得する。
///
/// 既存添付の ALT 文 (description) 更新は `PUT /api/v1/media/:id`
/// ([updateMediaDescription]) では行えない (サーバ側で `unattached` の media に
/// しかマッチしないため、投稿済みの添付には 404 が返る)。投稿済みメディアの
/// description を更新したい場合は [mediaAttributes] に `{id, description}` を
/// 並べて渡す。サーバ側で `media_attributes[][id]=...&media_attributes[][description]=...`
/// として送信される。`mediaIds` と併用可。
///
/// `language` を空文字列で送ると detection リセット扱いになる。null の場合は
/// パラメタごと送信しない (= サーバ側の値を維持)。
Future<Status> editStatus({
  required String instanceUrl,
  required String accessToken,
  required String statusId,
  required String statusText,
  List<String>? mediaIds,
  List<Map<String, String>>? mediaAttributes,
  String? spoilerText,
  PollData? poll,
  bool sensitive = false,
  String? language,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/statuses/$statusId');
  final headers = {
    'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/x-www-form-urlencoded',
  };

  // CW を空に戻したい場合は空文字を明示送信する必要がある (省略すると変更
  // されないサーバ実装が多い)。null と '' を区別する。
  final parts = <String>[
    'status=${Uri.encodeQueryComponent(statusText)}',
    'spoiler_text=${Uri.encodeQueryComponent(spoilerText ?? '')}',
    'sensitive=$sensitive',
    if (mediaIds != null)
      for (var id in mediaIds) 'media_ids[]=${Uri.encodeQueryComponent(id)}',
    // mediaIds == null の場合は media_ids を送らないので、サーバ側のメディアは
    // 維持される。空配列を明示的に送りたいときは呼び出し側で `mediaIds: []`
    // を渡してこのループが 0 回展開される (この場合 media_ids[]= 自体が
    // bodyから消えるので、サーバによっては「未指定」扱いになる懸念がある)。
    // 全消ししたいケースは確実にゼロ件にするため `media_ids[]=` 1 件を送る方
    // が安全だが、現状の UI では「ゼロ枚に編集」を直感的に打てる導線が
    // 限られているので、必要になったら追加する。
    // Mastodon (Rails) の strong params が `media_attributes: [:id, :description, ...]`
    // で配列前提なので、`media_attributes[0][id]=` (数値インデックス) で送るとハッシュ
    // 扱いになり 500 になる。`media_attributes[][id]=` (空ブラケット) で送る。
    // Rack は同じサブキーの再出現で配列要素を区切るので、各 attrs を 'id' → 'description'
    // の順に並べることで `[{id, description}, {id, description}, ...]` に組み上がる。
    if (mediaAttributes != null)
      for (var attrs in mediaAttributes)
        for (var entry in attrs.entries)
          'media_attributes[][${entry.key}]=${Uri.encodeQueryComponent(entry.value)}',
    if (poll != null) ...[
      for (var option in poll.options)
        'poll[options][]=${Uri.encodeQueryComponent(option)}',
      'poll[expires_in]=${poll.expiresInSeconds}',
      'poll[multiple]=${poll.multiple}',
      'poll[hide_totals]=${poll.hideTotals}',
    ],
    if (language != null)
      'language=${Uri.encodeQueryComponent(language)}',
  ];

  final resp = await httpClient.put(uri, headers: headers, body: parts.join('&'));

  if (resp.statusCode == 200) {
    return Status.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  // 404 / 405 は「このサーバは PUT /statuses/:id に対応していない」(古い
  // Mastodon や派生実装) サインなので、判別しやすい例外メッセージにする。
  if (resp.statusCode == 404 || resp.statusCode == 405) {
    throw Exception('このサーバは投稿の編集に対応していません (HTTP ${resp.statusCode})');
  }
  throw Exception('編集失敗: ${resp.statusCode} ${_summarizeErrorBody(resp.body)}');
}

/// ブックマーク・お気に入り専用のページネーション関数
Future<Map<String, dynamic>> fetchBookmarksOrFavouritesWithPagination({
  required String instanceUrl,
  required String accessToken,
  required String timelineType, // 'bookmarks' or 'favourites'
  String? nextUrl, // Use full URL for pagination instead of maxId
  int limit = 40,
}) async {
  final Uri uri;
  
  if (nextUrl != null) {
    // Use the next URL from Link header for proper pagination
    uri = Uri.parse(nextUrl);
  } else {
    // Initial request
    final endpoint = timelineType == 'bookmarks' ? '/api/v1/bookmarks' : '/api/v1/favourites';
    final params = <String>[];
    params.add('limit=$limit');
    final query = params.isNotEmpty ? '?${params.join('&')}' : '';
    uri = Uri.parse('$instanceUrl$endpoint$query');
  }
  
  try {
    final resp = await httpClient.get(
      uri,
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    
    if (resp.statusCode == 200) {
      final statuses = await compute(_decodeStatusListIsolate, resp.body);

      // Parse Link header for pagination info
      final linkHeader = resp.headers['link'];
      String? nextUrl;
      
      if (linkHeader != null) {
        // Parse Link header to extract next URL
        final regex = RegExp(r'<([^>]+)>; rel="next"');
        final match = regex.firstMatch(linkHeader);
        if (match != null) {
          nextUrl = match.group(1);
        }
      }
      
      return {
        'statuses': statuses,
        'nextUrl': nextUrl,
      };
    }
    throw Exception('$timelineType取得エラー: ${resp.statusCode}');
  } catch (e) {
    rethrow;
  }
}


/// 汎用 fetchTimeline: キャッシュ対応。
///
/// `accountId` はキャッシュキー discriminator として使う。同一インスタンス上の
/// 別アカウントでホーム TL が衝突しないようにするため (なお Mastodon の
/// account ID はインスタンス内ユニークなので `instanceUrl` のハッシュも
/// 併用してインスタンス跨ぎ衝突も避ける)。
Future<List<Status>> fetchTimelineForAccount({
  required String instanceUrl,
  required String accessToken,
  required String accountId,
  required String timelineType,
  String? listId,
  String? sinceId,
  String? maxId,
  int limit = 40, // デフォルト40件、最大40件まで指定可能
}) async {
  final base = timelineType == 'home'
      ? '/api/v1/timelines/home'
      : timelineType == 'local'
          ? '/api/v1/timelines/public?local=true'
          : timelineType == 'favourites'
              ? '/api/v1/favourites'
              : timelineType == 'bookmarks'
                  ? '/api/v1/bookmarks'
                  : timelineType == 'lists'
                      ? (listId != null ? '/api/v1/timelines/list/$listId' : '/api/v1/timelines/public')
                      : timelineType.startsWith('list_')
                          ? '/api/v1/timelines/list/${timelineType.substring(5)}'
                          : '/api/v1/timelines/public';

  final params = <String>[];
  if (sinceId != null) params.add('since_id=$sinceId');
  if (maxId != null) params.add('max_id=$maxId');
  params.add('limit=$limit'); // limit パラメータを追加
  final query = params.isNotEmpty ? (base.contains('?') ? '&' : '?') + params.join('&') : '';
  final uri = Uri.parse('$instanceUrl$base$query');
  
  final cacheKey =
      'tl:${_cacheKeyHost(instanceUrl)}:$accountId:$timelineType:${listId ?? ""}';

  try {
    final resp = await httpClient.get(
      uri,
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    if (resp.statusCode == 200) {
      _writeCache(cacheKey, resp.body);
      // jsonDecode + Status.fromJson × 40 件は UI スレッドで 50〜200ms 食うので
      // background isolate に逃がす。
      final statuses = await compute(_decodeStatusListIsolate, resp.body);

      // ブックマークとお気に入りでは追加順序を保持（ソートしない）
      if (timelineType != 'bookmarks' && timelineType != 'favourites') {
        statuses.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      }

      return statuses;
    }
    throw Exception('タイムライン取得エラー: ${resp.statusCode}');
  } catch (_) {
    final cached = _cacheBox.get(cacheKey);
    if (cached != null) {
      final statuses = await compute(_decodeStatusListIsolate, cached);

      // ブックマークとお気に入りでは追加順序を保持（ソートしない）
      if (timelineType != 'bookmarks' && timelineType != 'favourites') {
        statuses.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      }

      return statuses;
    }
    rethrow;
  }
}

/// アカウントのリスト一覧を取得
Future<List<MastodonList>> fetchLists({
  required String instanceUrl,
  required String accessToken,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/lists');

  try {
    final resp = await httpClient.get(
      uri,
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    if (resp.statusCode == 200) {
      final list = jsonDecode(resp.body) as List<dynamic>;
      return list
          .map((j) => MastodonList.fromJson(j as Map<String, dynamic>))
          .toList();
    }
    throw Exception('リスト取得エラー: ${resp.statusCode}');
  } catch (e) {
    throw Exception('リスト取得エラー: $e');
  }
}

/// リストを新規作成。
///
/// `repliesPolicy` は `'followed'` (フォロー中ユーザーへの返信のみ含める) /
/// `'list'` (リスト内ユーザーへの返信のみ) / `'none'` (返信を含めない) のいずれか。
/// 既定は Mastodon と揃えて `'list'`。
Future<MastodonList> createList({
  required String instanceUrl,
  required String accessToken,
  required String title,
  String repliesPolicy = 'list',
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/lists');
  final resp = await httpClient.post(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
    body: {
      'title': title,
      'replies_policy': repliesPolicy,
    },
  );
  if (resp.statusCode == 200 || resp.statusCode == 201) {
    return MastodonList.fromJson(
      jsonDecode(resp.body) as Map<String, dynamic>,
    );
  }
  throw Exception('リスト作成エラー: ${resp.statusCode}');
}

/// リスト名 / 返信ポリシーを更新
Future<MastodonList> updateList({
  required String instanceUrl,
  required String accessToken,
  required String listId,
  String? title,
  String? repliesPolicy,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/lists/$listId');
  final body = <String, String>{};
  if (title != null) body['title'] = title;
  if (repliesPolicy != null) body['replies_policy'] = repliesPolicy;

  final resp = await httpClient.put(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
    body: body,
  );
  if (resp.statusCode == 200) {
    return MastodonList.fromJson(
      jsonDecode(resp.body) as Map<String, dynamic>,
    );
  }
  throw Exception('リスト更新エラー: ${resp.statusCode}');
}

/// リストを削除
Future<void> deleteList({
  required String instanceUrl,
  required String accessToken,
  required String listId,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/lists/$listId');
  final resp = await httpClient.delete(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode != 200) {
    throw Exception('リスト削除エラー: ${resp.statusCode}');
  }
}

/// リストに含まれているアカウント一覧を取得 (ページネーション対応)。
///
/// Mastodon API は `limit` 既定 40、最大 80。`maxId` を渡すと続きを
/// 取得できる (ヘッダ Link に基づき呼び出し側でハンドリング)。
Future<List<Account>> fetchListAccounts({
  required String instanceUrl,
  required String accessToken,
  required String listId,
  String? maxId,
  int limit = 40,
}) async {
  final query = <String, String>{
    'limit': limit.toString(),
    if (maxId != null) 'max_id': maxId,
  };
  final uri = Uri.parse('$instanceUrl/api/v1/lists/$listId/accounts')
      .replace(queryParameters: query);
  final resp = await httpClient.get(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode == 200) {
    return compute(_decodeAccountListIsolate, resp.body);
  }
  throw Exception('リストメンバー取得エラー: ${resp.statusCode}');
}

/// 指定アカウントを 1 つ以上のリストに追加。
///
/// **注意**: Mastodon は「フォローしているアカウントのみリストに追加できる」
/// という制約があり、未フォローのアカウントを渡すと 422 で失敗する。
/// 呼び出し側でフォロー関係を確認してから渡すか、エラーを上位で捕捉して
/// SnackBar で案内すること。
Future<void> addAccountsToList({
  required String instanceUrl,
  required String accessToken,
  required String listId,
  required List<String> accountIds,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/lists/$listId/accounts');
  // Mastodon は配列パラメタを `account_ids[]=A&account_ids[]=B` の形で
  // 受け取る。Dart の http パッケージは同じキーの複数値を直接渡せないため、
  // application/x-www-form-urlencoded の手書きで対応。
  final body = accountIds
      .map((id) => 'account_ids[]=${Uri.encodeQueryComponent(id)}')
      .join('&');
  final resp = await httpClient.post(
    uri,
    headers: {
      'Authorization': 'Bearer $accessToken',
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: body,
  );
  if (resp.statusCode != 200) {
    throw Exception('リスト追加エラー: ${resp.statusCode} ${resp.body}');
  }
}

/// 指定アカウントをリストから外す
Future<void> removeAccountsFromList({
  required String instanceUrl,
  required String accessToken,
  required String listId,
  required List<String> accountIds,
}) async {
  final query = accountIds
      .map((id) => 'account_ids[]=${Uri.encodeQueryComponent(id)}')
      .join('&');
  final uri = Uri.parse(
      '$instanceUrl/api/v1/lists/$listId/accounts?$query');
  final resp = await httpClient.delete(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode != 200) {
    throw Exception('リスト除外エラー: ${resp.statusCode}');
  }
}

/// 指定アカウントが現在所属している全リストを取得。
/// 「このユーザーをリストに追加」UI で「既に入っているリスト」をチェック
/// 状態にするのに使う。
Future<List<MastodonList>> fetchListsContainingAccount({
  required String instanceUrl,
  required String accessToken,
  required String accountId,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/accounts/$accountId/lists');
  final resp = await httpClient.get(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode == 200) {
    final list = jsonDecode(resp.body) as List<dynamic>;
    return list
        .map((j) => MastodonList.fromJson(j as Map<String, dynamic>))
        .toList();
  }
  throw Exception('所属リスト取得エラー: ${resp.statusCode}');
}

/// ユーザー投稿一覧取得（キャッシュ対応）
Future<List<Status>> fetchAccountStatuses({
  required String instanceUrl,
  // 相手サーバーの公開投稿を認証なしで取得するケース (プロフィールの
  // 「相手サーバーから読み込む」) があるため nullable。null のときは
  // Authorization ヘッダを付けない (= 匿名アクセス = 公開/未収載のみ)。
  required String? accessToken,
  required String accountId,
  String? sinceId,
  String? maxId,
  int limit = 20,
  bool onlyMedia = false,
  // Mastodon 4.6+: DM (visibility = direct) を一覧から除外する。
  bool excludeDirect = false,
}) async {
  final params = <String>[];
  if (sinceId != null) params.add('since_id=$sinceId');
  if (maxId != null) params.add('max_id=$maxId');
  params.add('limit=$limit');
  if (onlyMedia) params.add('only_media=true');
  if (excludeDirect) params.add('exclude_direct=true');
  final query = params.isNotEmpty ? '?${params.join('&')}' : '';
  final uri = Uri.parse('$instanceUrl/api/v1/accounts/$accountId/statuses$query');
  // `onlyMedia` / `excludeDirect` の有無で内容が変わるので別キャッシュキー。
  // 旧実装は両者を同じキーで上書きし合っていたため、メディアタブと投稿タブで
  // 取り違えが起きていた (オフライン時に顕在化)。instanceUrl を含むので
  // home インスタンスと相手サーバーのキャッシュは衝突しない。
  final cacheKey =
      'acct:${_cacheKeyHost(instanceUrl)}:$accountId:${onlyMedia ? "media" : "all"}${excludeDirect ? ":nodirect" : ""}';

  try {
    final resp = await httpClient.get(
      uri,
      headers: {
        if (accessToken != null) 'Authorization': 'Bearer $accessToken',
      },
    );
    if (resp.statusCode == 200) {
      _writeCache(cacheKey, resp.body);
      final statuses = await compute(_decodeStatusListIsolate, resp.body);
      statuses.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return statuses;
    }
    throw Exception('ユーザー投稿取得失敗: ${resp.statusCode}');
  } catch (_) {
    final cached = _cacheBox.get(cacheKey);
    if (cached != null) {
      final statuses = await compute(_decodeStatusListIsolate, cached);
      statuses.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return statuses;
    }
    rethrow;
  }
}

/// アカウント詳細取得
Future<Account> fetchAccount({
  required String instanceUrl,
  required String accessToken,
  required String accountId,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/accounts/$accountId');
  final resp = await httpClient.get(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode != 200) {
    throw Exception('アカウント情報取得失敗: ${resp.statusCode}');
  }
  return Account.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
}

/// 複数アカウントを 1 リクエストでまとめて取得 (`GET /api/v1/accounts?id[]=`)。
/// コレクションのメンバー (account_id のみ持つ) をアバター/表示名付きで描画する
/// のに使う。返り順はサーバ依存なので、呼び出し側で id をキーに引き当てる前提。
/// 空 [accountIds] は空配列を返す (リクエストしない)。
Future<List<Account>> fetchAccountsByIds({
  required String instanceUrl,
  required String accessToken,
  required List<String> accountIds,
}) async {
  if (accountIds.isEmpty) return const [];
  final query =
      accountIds.map((id) => 'id[]=${Uri.encodeQueryComponent(id)}').join('&');
  final uri = Uri.parse('$instanceUrl/api/v1/accounts?$query');
  final resp = await httpClient.get(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode != 200) {
    throw Exception('アカウント一括取得失敗: ${resp.statusCode}');
  }
  return (jsonDecode(resp.body) as List<dynamic>)
      .whereType<Map<String, dynamic>>()
      .map(Account.fromJson)
      .toList();
}

/// acct (ユーザー名 / `user@host`) からアカウントを解決する。
///
/// プロフィールの「相手サーバーから最新を読み込む」で、相手インスタンスの
/// 公開 API (`/api/v1/accounts/lookup`) を **認証なし** で直接叩いて、連合
/// スナップショットではない正確なカウント / bio / fields を得るのに使う。
/// その場合 [instanceUrl] に相手サーバー、[accessToken] に null、[acct] に
/// 相手サーバー上のローカル名 (username 部分) を渡す。
///
/// 注: lookup 非対応サーバー (Misskey 等) や secure mode / authorized_fetch
/// では非 200 を返すので、呼び出し側で握って fallback (ブラウザで開く) する。
Future<Account> lookupAccount({
  required String instanceUrl,
  required String? accessToken,
  required String acct,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/accounts/lookup')
      .replace(queryParameters: {'acct': acct});
  final resp = await httpClient.get(
    uri,
    headers: {
      if (accessToken != null) 'Authorization': 'Bearer $accessToken',
    },
  );
  if (resp.statusCode != 200) {
    throw Exception('アカウント lookup 失敗: ${resp.statusCode}');
  }
  return Account.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
}

/// 固定投稿取得
Future<List<Status>> fetchPinnedStatuses({
  required String instanceUrl,
  // 相手サーバーから認証なしで取得するケースがあるため nullable。
  required String? accessToken,
  required String accountId,
}) async {
  final uri = Uri.parse(
      '$instanceUrl/api/v1/accounts/$accountId/statuses?limit=5&pinned=true');
  final resp = await httpClient.get(
    uri,
    headers: {
      if (accessToken != null) 'Authorization': 'Bearer $accessToken',
    },
  );
  if (resp.statusCode != 200) {
    throw Exception('固定投稿取得失敗: ${resp.statusCode}');
  }
  // pinned は最大 5 件と小さいので isolate 越境コストとの比較は微妙だが、
  // プロフィールページ表示の他の重い処理と並走するので逃がしておく。
  return compute(_decodeStatusListIsolate, resp.body);
}

/// フォロー／フォロワー一覧取得
///
/// [maxId] を渡すと続きのページが取れる (`fetchListAccounts` 等と同じく
/// 末尾アカウントの id を渡す簡易ページング)。Mastodon は本来 Link ヘッダ
/// pagination を返すが、UI 側で max_id を組み立てる方が単純。
Future<List<Account>> fetchAccountFollowing({
  required String instanceUrl,
  required String accessToken,
  required String accountId,
  String? maxId,
  int limit = 80,
}) async {
  final query = <String, String>{
    'limit': limit.toString(),
    if (maxId != null) 'max_id': maxId,
  };
  final uri =
      Uri.parse('$instanceUrl/api/v1/accounts/$accountId/following')
          .replace(queryParameters: query);
  final resp = await httpClient.get(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode != 200) {
    throw Exception('フォロー一覧取得失敗: ${resp.statusCode}');
  }
  return compute(_decodeAccountListIsolate, resp.body);
}

/// フォロワー一覧取得
Future<List<Account>> fetchAccountFollowers({
  required String instanceUrl,
  required String accessToken,
  required String accountId,
  String? maxId,
  int limit = 80,
}) async {
  final query = <String, String>{
    'limit': limit.toString(),
    if (maxId != null) 'max_id': maxId,
  };
  final uri =
      Uri.parse('$instanceUrl/api/v1/accounts/$accountId/followers')
          .replace(queryParameters: query);
  final resp = await httpClient.get(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode != 200) {
    throw Exception('フォロワー一覧取得失敗: ${resp.statusCode}');
  }
  return compute(_decodeAccountListIsolate, resp.body);
}

/// 共通のフォロワー (familiar followers) を取得する。
/// `GET /api/v1/accounts/familiar_followers?id[]=...`
///
/// 「あなたのフォロー中のユーザー (= 自分の followee) のうち、指定アカウントを
/// フォローしている人」のリスト。Twitter の "Followed by ..." と同じ。
///
/// API は複数アカウント分まとめて取れる仕様だが、現状は 1 アカウントずつ呼ぶ
/// 用途しかないので簡略化して accountId を 1 つだけ受ける。レスポンスは
/// `[{id: "...", accounts: [Account, ...]}]` の配列なので、対応する id の
/// 内側 accounts を返す。
///
/// 古い Mastodon (3.5 未満) や派生実装で 404 等が返るケースは空配列として扱う
/// (この機能無しでもプロフィールは普通に開けるべきなので、ここで例外を上げて
/// 全体を止めない)。
Future<List<Account>> fetchFamiliarFollowers({
  required String instanceUrl,
  required String accessToken,
  required String accountId,
}) async {
  final uri = Uri.parse(
      '$instanceUrl/api/v1/accounts/familiar_followers?id[]=${Uri.encodeQueryComponent(accountId)}');
  try {
    final resp = await httpClient.get(
      uri,
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    if (resp.statusCode != 200) return <Account>[];
    final list = jsonDecode(resp.body) as List<dynamic>;
    for (final entry in list) {
      if (entry is Map<String, dynamic> && entry['id'] == accountId) {
        final accounts = entry['accounts'] as List<dynamic>? ?? const [];
        return accounts
            .map((j) => Account.fromJson(j as Map<String, dynamic>))
            .toList();
      }
    }
    return <Account>[];
  } catch (_) {
    return <Account>[];
  }
}

/// 自分のフォロワーから指定アカウントを外す (Mastodon 4.0+)。
/// `POST /api/v1/accounts/:id/remove_from_followers`
///
/// 「ブロックはしたくないが相手のフォローだけ解除したい」用途。レスポンスは
/// 操作後の Relationship。古い Mastodon (3.x 以前) や派生実装では 404 が
/// 返るので [PostStatusNotSupportedException] 相当の固有例外で区別する。
class RemoveFromFollowersNotSupportedException implements Exception {
  final String message;
  RemoveFromFollowersNotSupportedException(this.message);
  @override
  String toString() => message;
}

Future<Relationship> removeFromFollowers({
  required String instanceUrl,
  required String accessToken,
  required String accountId,
}) async {
  final uri = Uri.parse(
      '$instanceUrl/api/v1/accounts/$accountId/remove_from_followers');
  final resp = await httpClient.post(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode == 200) {
    return Relationship.fromJson(jsonDecode(resp.body));
  }
  if (resp.statusCode == 404 || resp.statusCode == 405) {
    throw RemoveFromFollowersNotSupportedException(
        'このサーバーは「フォロワーから外す」に対応していません (Mastodon 4.0+ が必要)');
  }
  throw Exception('フォロワー除外失敗: ${resp.statusCode} ${resp.body}');
}

/// 通知一覧取得（ページング対応）
Future<List<NotificationItem>> fetchNotifications({
  required String instanceUrl,
  required String accessToken,
  int limit = 20,
  String? sinceId,
  String? maxId,
  List<String>? supportedTypes,
}) async {
  final params = <String>['limit=$limit'];
  if (sinceId != null) params.add('since_id=$sinceId');
  if (maxId   != null) params.add('max_id=$maxId');
  // Mastodon 4.6+: supported_types に列挙したタイプ以外は fallback 表現に
  // 落とされる。デフォルト null で従来挙動 (全タイプそのまま) を維持する。
  if (supportedTypes != null) {
    for (final t in supportedTypes) {
      params.add('supported_types[]=${Uri.encodeQueryComponent(t)}');
    }
  }
  final uri = Uri.parse('$instanceUrl/api/v1/notifications?${params.join('&')}');
  final res = await httpClient.get(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (res.statusCode == 200) {
    // listFromJson は jsonDecode + map + filter を実行するため、通知ページ
    // 表示中は UI スレッドで 50〜100ms 食う。background isolate に逃がす。
    return compute(NotificationItem.listFromJson, res.body);
  }
  throw Exception('通知取得失敗: ${res.statusCode}');
}

/// サーバ管理者からのお知らせ一覧を取得 (`GET /api/v1/announcements`)。
///
/// 既定では既読/未読を区別せず現在表示すべき (= expired していない)
/// ものを全部返す。Mastodon サーバ側で publish 済みでまだ ends_at に
/// 達していないものが対象。`with_dismissed=true` を付けて過去も含めても
/// よいが、デフォルト挙動でも `read: true` が返るので明示的に渡さない。
Future<List<Announcement>> fetchAnnouncements({
  required String instanceUrl,
  required String accessToken,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/announcements');
  final res = await httpClient.get(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (res.statusCode == 200) {
    return Announcement.listFromJson(res.body);
  }
  // /announcements を実装していないインスタンス (古い fork など) は
  // 404 を返す。空リストで扱えば一覧側で「お知らせはありません」表示に
  // なるだけなので、エラーにせず空配列で吸収する。
  if (res.statusCode == 404) return [];
  throw Exception('お知らせ取得失敗: ${res.statusCode}');
}

/// お知らせを既読化 (`POST /api/v1/announcements/:id/dismiss`)。
Future<void> dismissAnnouncement({
  required String instanceUrl,
  required String accessToken,
  required String announcementId,
}) async {
  final uri =
      Uri.parse('$instanceUrl/api/v1/announcements/$announcementId/dismiss');
  final res = await httpClient.post(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (res.statusCode != 200) {
    throw Exception('お知らせ既読化失敗: ${res.statusCode}');
  }
}

/// お知らせにリアクションを追加 (`PUT /api/v1/announcements/:id/reactions/:name`)。
/// [name] は Unicode 絵文字または カスタム絵文字の shortcode (`:` なし)。
Future<void> addAnnouncementReaction({
  required String instanceUrl,
  required String accessToken,
  required String announcementId,
  required String name,
}) async {
  // `name` は絵文字を含む可能性があるので encodeComponent する。
  final encoded = Uri.encodeComponent(name);
  final uri = Uri.parse(
      '$instanceUrl/api/v1/announcements/$announcementId/reactions/$encoded');
  final res = await httpClient.put(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (res.statusCode != 200) {
    throw Exception('リアクション追加失敗: ${res.statusCode}');
  }
}

/// お知らせのリアクションを削除 (`DELETE /api/v1/announcements/:id/reactions/:name`)。
Future<void> removeAnnouncementReaction({
  required String instanceUrl,
  required String accessToken,
  required String announcementId,
  required String name,
}) async {
  final encoded = Uri.encodeComponent(name);
  final uri = Uri.parse(
      '$instanceUrl/api/v1/announcements/$announcementId/reactions/$encoded');
  final res = await httpClient.delete(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (res.statusCode != 200) {
    throw Exception('リアクション削除失敗: ${res.statusCode}');
  }
}

/// SSE で notification イベントのみ受信。
///
/// [httpClient] と同じ発想のテスト用 seam (関数型トップレベル変数)。
/// flutter_test 環境は実ネットワークを遮断するため、この差し替え口が
/// ないと notifications_provider の SSE 系レース (二重接続等) を
/// 決定的に再現できない。プロダクションでは従来実装のまま。
/// (`@visibleForTesting` はプロダクションの呼び出し元があるため付けない。
/// テスト以外で差し替えないこと。)
Future<Stream<NotificationItem>> Function({
  required String instanceUrl,
  required String accessToken,
}) subscribeNotifications = _subscribeNotificationsImpl;

Future<Stream<NotificationItem>> _subscribeNotificationsImpl({
  required String instanceUrl,
  required String accessToken,
}) async {
  final url    = '$instanceUrl/api/v1/streaming/user?access_token=$accessToken';
  final conn = await connectSse(url);
  return conn.events
      .where((e) => e.event == 'notification' && e.data != null)
      .map((e) => NotificationItem.fromJson(
            json.decode(e.data!) as Map<String, dynamic>,
          ));
}

/// SSE でタイムラインの新規投稿 (`update` イベント) を購読する。
///
/// 対応する [timelineType]:
///   - `home`     : ホームタイムライン (要 access_token)
///   - `local`    : ローカルタイムライン
///   - `public` / `federated` : 連合タイムライン
///   - `lists`    : 指定リスト ([listId] 必須)
///   - `hashtag`  : 指定ハッシュタグ ([hashtag] 必須)
///
/// `bookmarks` / `favourites` は streaming 非対応のため呼び出し側で除外すること。
///
/// **戻り値は生 JSON 文字列のストリーム** (パース前)。これは
/// `json.decode` + `Status.fromJson` (再帰的なオブジェクト構築) が 5KB 級
/// JSON で 1〜3ms かかり、SSE は UI スレッドで同期に `.map` を回すため
/// 5〜10 イベント/秒の高頻度ストリームではそれだけでフレーム予算を食い
/// 潰してスクロールを止めるため。呼び出し側はバッファに raw を溜めて
/// `idle` のときにまとめてパースすること。
///
/// [onHeartbeat] はサーバの `:thump` ハートビート受信ごとに呼ばれる
/// (io 実装のみ。Web の EventSource はコメント行を露出しないため呼ばれない)。
/// 呼び出し側のサイレント切断 watchdog が「生きているが静かな接続」と
/// 「死んだ接続」を区別するのに使う。notifications ストリーム
/// (subscribeNotifications) は watchdog を持たないため未対応
/// (必要になったら同様に拡張する)。
Future<Stream<String>> subscribeTimelineUpdates({
  required String instanceUrl,
  required String accessToken,
  required String timelineType,
  String? listId,
  String? hashtag,
  void Function()? onHeartbeat,
}) async {
  final String streamPath;
  switch (timelineType) {
    case 'home':
      streamPath = 'user';
      break;
    case 'local':
      streamPath = 'public/local';
      break;
    case 'public':
    case 'federated':
      streamPath = 'public';
      break;
    case 'lists':
      if (listId == null) {
        throw ArgumentError('listId is required for list streaming');
      }
      streamPath = 'list?list=${Uri.encodeQueryComponent(listId)}';
      break;
    case 'hashtag':
      if (hashtag == null) {
        throw ArgumentError('hashtag is required for hashtag streaming');
      }
      streamPath = 'hashtag?tag=${Uri.encodeQueryComponent(hashtag)}';
      break;
    default:
      throw UnsupportedError(
          'Streaming not supported for timeline type "$timelineType"');
  }
  final separator = streamPath.contains('?') ? '&' : '?';
  final url =
      '$instanceUrl/api/v1/streaming/$streamPath${separator}access_token=$accessToken';
  final conn = await connectSse(url);
  return conn.events.where((e) {
    if (e.event == 'heartbeat') {
      onHeartbeat?.call();
      return false;
    }
    return e.event == 'update' && e.data != null;
  }).map((e) => e.data!);
}

/// 特定ユーザーとのリレーションシップを取得
Future<Relationship> fetchRelationship({
  required String instanceUrl,
  required String accessToken,
  required String accountId,
}) async {
  // クエリパラメータは id[] です（ids[] では動きません）
  final uri = Uri.parse(
    '$instanceUrl/api/v1/accounts/relationships?id[]=$accountId',
  );
  final res = await httpClient.get(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (res.statusCode == 200) {
    final List<dynamic> arr = jsonDecode(res.body) as List<dynamic>;
    if (arr.isEmpty) {
      throw Exception('Relationship 配列が空です');
    }
    return Relationship.fromJson(arr.first as Map<String, dynamic>);
  }
  throw Exception('Relationship取得失敗: ${res.statusCode}');
}

/// フォロー／アンフォロー
Future<Relationship> followAccount({
  required String instanceUrl,
  required String accessToken,
  required String accountId,
  bool notify = false, // 通知購読フラグ
}) async {
  final uri = Uri.parse(
    '$instanceUrl/api/v1/accounts/$accountId/follow?notify=$notify',
  );
  final res = await httpClient.post(uri, headers: {
    'Authorization': 'Bearer $accessToken',
  });
  if (res.statusCode == 200) {
    return Relationship.fromJson(
      jsonDecode(res.body) as Map<String, dynamic>,
    );
  }
  throw Exception('フォローに失敗: ${res.statusCode}');
}

/// アカウントに対する自分専用メモ (private note) を更新する。
/// 空文字を渡すと削除と同じ扱い (Mastodon 側は note を空文字にする)。
/// 戻り値は更新後の Relationship。
Future<Relationship> updateAccountNote({
  required String instanceUrl,
  required String accessToken,
  required String accountId,
  required String comment,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/accounts/$accountId/note');
  final res = await httpClient.post(
    uri,
    headers: {
      'Authorization': 'Bearer $accessToken',
      'Content-Type': 'application/json',
    },
    body: jsonEncode({'comment': comment}),
  );
  if (res.statusCode == 200) {
    return Relationship.fromJson(
      jsonDecode(res.body) as Map<String, dynamic>,
    );
  }
  throw Exception('メモの保存に失敗: ${res.statusCode}');
}

Future<Relationship> unfollowAccount({
  required String instanceUrl,
  required String accessToken,
  required String accountId,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/accounts/$accountId/unfollow');
  final res = await httpClient.post(uri, headers: {
    'Authorization': 'Bearer $accessToken',
  });
  if (res.statusCode == 200) {
    return Relationship.fromJson(
      jsonDecode(res.body) as Map<String, dynamic>,
    );
  }
  throw Exception('アンフォローに失敗: ${res.statusCode}');
}

/// 指定した statusId の返信ツリー（先祖／子孫）を取得する
Future<StatusContext> fetchStatusContext({
  required String instanceUrl,
  required String accessToken,
  required String statusId,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/statuses/$statusId/context');
  // accessToken が空なら認証なしでアクセスする (投稿元サーバを直接開く用途)。
  final resp = await httpClient.get(
    uri,
    headers: accessToken.isEmpty
        ? <String, String>{}
        : {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode == 200) {
    final jsonMap = jsonDecode(resp.body) as Map<String, dynamic>;
    return StatusContext.fromJson(jsonMap);
  } else {
    throw Exception('ステータスコンテキスト取得失敗: ${resp.statusCode}');
  }
}

/// 注目の投稿を取得
Future<List<Status>> fetchTrendingPosts({
  required String instanceUrl,
  required String accessToken,
  int limit = 20,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/trends/statuses?limit=$limit');
  
  try {
    final response = await httpClient.get(
      uri,
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (response.statusCode == 200) {
      return await compute(_decodeStatusListIsolate, response.body);
    } else {
      throw Exception('Failed to fetch trending posts: ${response.statusCode}');
    }
  } catch (e) {
    return [];
  }
}

/// 注目のハッシュタグを取得
Future<List<TrendingHashtag>> fetchTrendingHashtags({
  required String instanceUrl,
  required String accessToken,
  int limit = 10,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/trends/tags?limit=$limit');
  
  try {
    final response = await httpClient.get(
      uri,
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (response.statusCode == 200) {
      final List<dynamic> jsonList = jsonDecode(response.body);
      return jsonList.map((json) => TrendingHashtag(
        name: json['name'] ?? '',
        uses: int.tryParse(json['uses']?.toString() ?? '0') ?? 0,
        history: (json['history'] as List<dynamic>?)
            ?.map((h) => TrendHistory(
                  day: h['day']?.toString() ?? '',
                  uses: int.tryParse(h['uses']?.toString() ?? '0') ?? 0,
                  accounts: int.tryParse(h['accounts']?.toString() ?? '0') ?? 0,
                ))
            .toList() ?? [],
      )).toList();
    } else {
      throw Exception('Failed to fetch trending hashtags: ${response.statusCode}');
    }
  } catch (e) {
    return [];
  }
}

/// おすすめユーザーを取得
Future<List<SuggestedAccount>> fetchSuggestedUsers({
  required String instanceUrl,
  required String accessToken,
  int limit = 20,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v2/suggestions?limit=$limit');
  
  try {
    final response = await httpClient.get(
      uri,
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (response.statusCode == 200) {
      final List<dynamic> jsonList = jsonDecode(response.body);
      return jsonList.map((json) {
        final account = json['account'] ?? json; // v2 APIでは account フィールド内にある場合がある
        return SuggestedAccount(
          id: account['id']?.toString() ?? '',
          username: account['username'] ?? '',
          acct: account['acct'] ?? account['username'] ?? '',
          displayName: account['display_name'] ?? account['username'] ?? '',
          note: account['note'] ?? '',
          avatarStatic: account['avatar_static'] ?? account['avatar'] ?? '',
          followersCount: int.tryParse(account['followers_count']?.toString() ?? '0'),
          emojis: (account['emojis'] as List<dynamic>?)
              ?.map((emojiJson) => Emoji.fromJson(emojiJson as Map<String, dynamic>))
              .toList() ?? [],
        );
      }).toList();
    } else {
      throw Exception('Failed to fetch suggested users: ${response.statusCode}');
    }
  } catch (e) {
    return [];
  }
}

/// 注目のニュース/リンクを取得
Future<List<TrendingLink>> fetchTrendingLinks({
  required String instanceUrl,
  required String accessToken,
  int limit = 10,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/trends/links?limit=$limit');
  
  try {
    final response = await httpClient.get(
      uri,
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (response.statusCode == 200) {
      final List<dynamic> jsonList = jsonDecode(response.body);
      return jsonList.map((json) => TrendingLink(
        url: json['url'] ?? '',
        title: json['title'] ?? '',
        description: json['description'],
        image: json['image'],
        uses: int.tryParse(json['uses']?.toString() ?? '0') ?? 0,
      )).toList();
    } else {
      throw Exception('Failed to fetch trending links: ${response.statusCode}');
    }
  } catch (e) {
    return [];
  }
}

/// 検索リクエストのタイムアウト。`resolve: true` はサーバ側の ActivityPub
/// リモート解決で正当に十数秒かかることがあるため長め。これが無いと
/// リモートサーバ不達時に await が永久に返らず、呼び出し側のローディング
/// ダイアログが閉じなくなる。
const _searchTimeout = Duration(seconds: 30);

/// 検索機能
Future<Map<String, dynamic>> searchContent({
  required String instanceUrl,
  required String accessToken,
  required String query,
  String type = 'accounts,hashtags,statuses',
  bool resolve = true,
  int limit = 20,
}) async {
  // まずv2 APIを試す
  final v2Uri = Uri.parse('$instanceUrl/api/v2/search').replace(queryParameters: {
    'q': query,
    'resolve': resolve.toString(),
    'limit': limit.toString(),
  });
  
  try {
    final response = await httpClient.get(
      v2Uri,
      headers: {'Authorization': 'Bearer $accessToken'},
    ).timeout(_searchTimeout);

    if (response.statusCode == 200) {
      final Map<String, dynamic> jsonData = jsonDecode(response.body);
      
      return {
        'statuses': (jsonData['statuses'] as List<dynamic>?)
            ?.map((json) => Status.fromJson(json))
            .toList() ?? [],
        'accounts': (jsonData['accounts'] as List<dynamic>?)
            ?.map((json) => SuggestedAccount(
                  id: json['id']?.toString() ?? '',
                  username: json['username'] ?? '',
                  acct: json['acct'] ?? json['username'] ?? '',
                  displayName: json['display_name'] ?? json['username'] ?? '',
                  note: json['note'] ?? '',
                  avatarStatic: json['avatar_static'] ?? json['avatar'] ?? '',
                  followersCount: int.tryParse(json['followers_count']?.toString() ?? '0'),
                  emojis: (json['emojis'] as List<dynamic>?)
                      ?.map((emojiJson) => Emoji.fromJson(emojiJson as Map<String, dynamic>))
                      .toList() ?? [],
                ))
            .toList() ?? [],
        'hashtags': (jsonData['hashtags'] as List<dynamic>?)
            ?.map((json) => TrendingHashtag(
                  name: json['name'] ?? '',
                  uses: int.tryParse(json['uses']?.toString() ?? '0') ?? 0,
                  history: [],
                ))
            .toList() ?? [],
      };
    } else {
      // v2が失敗した場合はv1を試す
      return await _searchContentV1(
        instanceUrl: instanceUrl,
        accessToken: accessToken,
        query: query,
        resolve: resolve,
        limit: limit,
      );
    }
  } on TimeoutException {
    // タイムアウト時は v1 にフォールバックしない (同じ resolve で再度詰まって
    // 最悪 2 倍待たされる)。呼び出し元にエラーとして伝える。
    rethrow;
  } catch (e) {
    // v2でエラーが発生した場合はv1を試す
    return await _searchContentV1(
      instanceUrl: instanceUrl,
      accessToken: accessToken,
      query: query,
      resolve: resolve,
      limit: limit,
    );
  }
}

/// v1 検索API（フォールバック用）
Future<Map<String, List<dynamic>>> _searchContentV1({
  required String instanceUrl,
  required String accessToken,
  required String query,
  bool resolve = true,
  int limit = 20,
}) async {
  final v1Uri = Uri.parse('$instanceUrl/api/v1/search').replace(queryParameters: {
    'q': query,
    'resolve': resolve.toString(),
    'limit': limit.toString(),
  });
  
  try {
    final response = await httpClient.get(
      v1Uri,
      headers: {'Authorization': 'Bearer $accessToken'},
    ).timeout(_searchTimeout);

    if (response.statusCode == 200) {
      final Map<String, dynamic> jsonData = jsonDecode(response.body);
      
      return {
        'statuses': (jsonData['statuses'] as List<dynamic>?)
            ?.map((json) => Status.fromJson(json))
            .toList() ?? [],
        'accounts': (jsonData['accounts'] as List<dynamic>?)
            ?.map((json) => SuggestedAccount(
                  id: json['id']?.toString() ?? '',
                  username: json['username'] ?? '',
                  acct: json['acct'] ?? json['username'] ?? '',
                  displayName: json['display_name'] ?? json['username'] ?? '',
                  note: json['note'] ?? '',
                  avatarStatic: json['avatar_static'] ?? json['avatar'] ?? '',
                  followersCount: int.tryParse(json['followers_count']?.toString() ?? '0'),
                  emojis: (json['emojis'] as List<dynamic>?)
                      ?.map((emojiJson) => Emoji.fromJson(emojiJson as Map<String, dynamic>))
                      .toList() ?? [],
                ))
            .toList() ?? [],
        'hashtags': (jsonData['hashtags'] as List<dynamic>?)
            ?.map((json) => TrendingHashtag(
                  name: json['name'] ?? '',
                  uses: int.tryParse(json['uses']?.toString() ?? '0') ?? 0,
                  history: [],
                ))
            .toList() ?? [],
      };
    } else {
      throw Exception('Failed to search: ${response.statusCode}');
    }
  } on TimeoutException {
    // 空マップで握りつぶすと「投稿が見つかりません」誤表示になるので伝播する
    rethrow;
  } catch (e) {
    return {
      'statuses': <Status>[],
      'accounts': <SuggestedAccount>[],
      'hashtags': <TrendingHashtag>[],
    };
  }
}

/// ハッシュタグのタイムラインを取得
Future<List<Status>> fetchHashtagTimeline({
  required String instanceUrl,
  required String accessToken,
  required String hashtag,
  String? maxId,
  String? sinceId,
  int limit = 20,
  bool local = false,
  bool onlyMedia = false,
}) async {
  var queryParams = <String, String>{
    'limit': limit.toString(),
  };
  
  if (maxId != null) queryParams['max_id'] = maxId;
  if (sinceId != null) queryParams['since_id'] = sinceId;
  if (local) queryParams['local'] = 'true';
  if (onlyMedia) queryParams['only_media'] = 'true';

  final uri = Uri.parse('$instanceUrl/api/v1/timelines/tag/$hashtag')
      .replace(queryParameters: queryParams);

  try {
    final response = await httpClient.get(
      uri,
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (response.statusCode == 200) {
      return await compute(_decodeStatusListIsolate, response.body);
    } else {
      throw Exception('Failed to fetch hashtag timeline: ${response.statusCode}');
    }
  } catch (e) {
    rethrow;
  }
}

/// ハッシュタグをフォローしているかチェック
Future<bool> isFollowingHashtag({
  required String instanceUrl,
  required String accessToken,
  required String hashtag,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/followed_tags');

  try {
    final response = await httpClient.get(
      uri,
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (response.statusCode == 200) {
      final List<dynamic> jsonList = jsonDecode(response.body);
      return jsonList.any((tag) => tag['name'] == hashtag);
    } else {
      throw Exception('Failed to check hashtag follow status: ${response.statusCode}');
    }
  } catch (e) {
    return false;
  }
}

/// ハッシュタグのフォロー状態をトグル
Future<bool> toggleHashtagFollow({
  required String instanceUrl,
  required String accessToken,
  required String hashtag,
  required bool currentlyFollowing,
}) async {
  final action = currentlyFollowing ? 'unfollow' : 'follow';
  final uri = Uri.parse('$instanceUrl/api/v1/tags/$hashtag/$action');

  try {
    final response = await httpClient.post(
      uri,
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (response.statusCode == 200) {
      return !currentlyFollowing;
    } else {
      throw Exception('Failed to $action hashtag: ${response.statusCode}');
    }
  } catch (e) {
    rethrow;
  }
}

/// アカウントをミュート
Future<Relationship> muteAccount({
  required String instanceUrl,
  required String accessToken,
  required String accountId,
  bool notifications = true,
  int? duration,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/accounts/$accountId/mute');
  
  Map<String, dynamic> body = {
    'notifications': notifications.toString(),
  };
  
  if (duration != null) {
    body['duration'] = duration.toString();
  }

  try {
    final response = await httpClient.post(
      uri,
      headers: {'Authorization': 'Bearer $accessToken'},
      body: body,
    );

    if (response.statusCode == 200) {
      return Relationship.fromJson(jsonDecode(response.body));
    } else {
      throw Exception('Failed to mute account: ${response.statusCode}');
    }
  } catch (e) {
    rethrow;
  }
}

/// アカウントのミュートを解除
Future<Relationship> unmuteAccount({
  required String instanceUrl,
  required String accessToken,
  required String accountId,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/accounts/$accountId/unmute');

  try {
    final response = await httpClient.post(
      uri,
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (response.statusCode == 200) {
      return Relationship.fromJson(jsonDecode(response.body));
    } else {
      throw Exception('Failed to unmute account: ${response.statusCode}');
    }
  } catch (e) {
    rethrow;
  }
}

/// アカウントをブロック
Future<Relationship> blockAccount({
  required String instanceUrl,
  required String accessToken,
  required String accountId,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/accounts/$accountId/block');

  try {
    final response = await httpClient.post(
      uri,
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (response.statusCode == 200) {
      return Relationship.fromJson(jsonDecode(response.body));
    } else {
      throw Exception('Failed to block account: ${response.statusCode}');
    }
  } catch (e) {
    rethrow;
  }
}

/// アカウントのブロックを解除
Future<Relationship> unblockAccount({
  required String instanceUrl,
  required String accessToken,
  required String accountId,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/accounts/$accountId/unblock');

  try {
    final response = await httpClient.post(
      uri,
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (response.statusCode == 200) {
      return Relationship.fromJson(jsonDecode(response.body));
    } else {
      throw Exception('Failed to unblock account: ${response.statusCode}');
    }
  } catch (e) {
    rethrow;
  }
}

/// ドメインをブロック
Future<void> blockDomain({
  required String instanceUrl,
  required String accessToken,
  required String domain,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/domain_blocks');

  try {
    final response = await httpClient.post(
      uri,
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: {'domain': domain},
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to block domain: ${response.statusCode}');
    }
  } catch (e) {
    rethrow;
  }
}

/// ドメインのブロックを解除
Future<void> unblockDomain({
  required String instanceUrl,
  required String accessToken,
  required String domain,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/domain_blocks');

  try {
    final response = await httpClient.delete(
      uri,
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: {'domain': domain},
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to unblock domain: ${response.statusCode}');
    }
  } catch (e) {
    rethrow;
  }
}

/// ブロックしているドメインのリストを取得
Future<List<String>> fetchBlockedDomains({
  required String instanceUrl,
  required String accessToken,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/domain_blocks');

  try {
    final response = await httpClient.get(
      uri,
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (response.statusCode == 200) {
      final List<dynamic> jsonList = jsonDecode(response.body);
      return jsonList.cast<String>();
    } else {
      throw Exception('Failed to fetch blocked domains: ${response.statusCode}');
    }
  } catch (e) {
    return [];
  }
}

/// アカウント一覧 + 次ページカーソルの組。
///
/// `/api/v1/mutes` `/api/v1/blocks` のように Link ヘッダでページングする
/// エンドポイント用。`nextMaxId` が null なら「これ以上ページが無い」。
typedef AccountPage = (List<Account> accounts, String? nextMaxId);

/// HTTP `Link` ヘッダ値から `rel="next"` の `max_id` を取り出す。
///
/// **なぜ必要か**: `/api/v1/mutes` `/api/v1/blocks` のページネーション
/// カーソルはサーバ内部の関係 ID であり、返ってくる `Account.id` とは別物。
/// フォロー/フォロワー等で使っている「最後の Account.id を max_id に渡す」
/// 簡易方式はこの 2 エンドポイントでは正しく動かない (2 ページ目が空 or
/// 重複する) ため、Link ヘッダから本物のカーソルを取り出す必要がある。
///
/// ヘッダ値の例:
/// `<https://ex.com/api/v1/mutes?limit=40&max_id=12345>; rel="next", <...?since_id=67890>; rel="prev"`
///
/// URL クエリ内のカンマと区切りのカンマを混同しないよう、`<URL>; rel="..."`
/// の形を正規表現で全マッチさせて `next` のものだけ採用する。`max_id` が
/// 取れなければ null (= 末尾ページ) を返す。テスト可能にするためトップレベル
/// 公開関数にしている。
String? parseNextMaxIdFromLinkHeader(String? linkHeader) {
  if (linkHeader == null || linkHeader.isEmpty) return null;
  final re = RegExp(r'<([^>]+)>\s*;\s*rel="?([a-zA-Z]+)"?');
  for (final m in re.allMatches(linkHeader)) {
    if (m.group(2) == 'next') {
      final url = m.group(1);
      if (url == null) return null;
      return Uri.tryParse(url)?.queryParameters['max_id'];
    }
  }
  return null;
}

/// Link ヘッダ方式でページングするアカウント一覧取得の共通実装。
///
/// [treat404AsEmpty] が true のときは 404 も空一覧扱いにする (鍵投稿などで
/// サーバが一覧を見せない場合や、エンドポイント非対応の古い派生実装で 404 が
/// 返るケースを区別せず握りつぶしたい reblogged_by/favourited_by 用)。
Future<AccountPage> _fetchAccountPageWithLinkPagination({
  required String instanceUrl,
  required String accessToken,
  required String path,
  String? maxId,
  int limit = 40,
  bool treat404AsEmpty = false,
}) async {
  final query = <String, String>{
    'limit': limit.toString(),
    if (maxId != null) 'max_id': maxId,
  };
  final uri =
      Uri.parse('$instanceUrl$path').replace(queryParameters: query);
  final resp = await httpClient.get(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode == 200) {
    // body のデコードは isolate に逃がし、Link ヘッダは compute 後に
    // メインスレッドで同期的に処理する (ヘッダを isolate に持ち込まない)。
    final accounts = await compute(_decodeAccountListIsolate, resp.body);
    final nextMaxId = parseNextMaxIdFromLinkHeader(resp.headers['link']);
    return (accounts, nextMaxId);
  }
  // 権限不足やトークン失効は空一覧扱い (画面をクラッシュさせない)。
  if (resp.statusCode == 401 || resp.statusCode == 403) {
    return (const <Account>[], null);
  }
  if (treat404AsEmpty && resp.statusCode == 404) {
    return (const <Account>[], null);
  }
  throw Exception('一覧取得エラー ($path): ${resp.statusCode}');
}

/// ミュート中のアカウント一覧を取得 (`GET /api/v1/mutes`)。
/// ページングは Link ヘッダ方式 ([parseNextMaxIdFromLinkHeader] 参照)。
Future<AccountPage> fetchMutedAccounts({
  required String instanceUrl,
  required String accessToken,
  String? maxId,
  int limit = 40,
}) =>
    _fetchAccountPageWithLinkPagination(
      instanceUrl: instanceUrl,
      accessToken: accessToken,
      path: '/api/v1/mutes',
      maxId: maxId,
      limit: limit,
    );

/// ブロック中のアカウント一覧を取得 (`GET /api/v1/blocks`)。
/// ページングは Link ヘッダ方式 ([parseNextMaxIdFromLinkHeader] 参照)。
Future<AccountPage> fetchBlockedAccounts({
  required String instanceUrl,
  required String accessToken,
  String? maxId,
  int limit = 40,
}) =>
    _fetchAccountPageWithLinkPagination(
      instanceUrl: instanceUrl,
      accessToken: accessToken,
      path: '/api/v1/blocks',
      maxId: maxId,
      limit: limit,
    );

/// ハッシュタグの情報を取得
Future<Map<String, dynamic>> getHashtagInfo({
  required String instanceUrl,
  required String accessToken,
  required String hashtag,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/tags/$hashtag');

  try {
    final response = await httpClient.get(
      uri,
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception('Failed to fetch hashtag info: ${response.statusCode}');
    }
  } catch (e) {
    rethrow;
  }
}

/// アカウントを検索
Future<List<Account>> searchAccounts({
  required String instanceUrl,
  required String accessToken,
  required String query,
  int limit = 10,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v2/search').replace(
    queryParameters: {
      'q': query,
      'type': 'accounts',
      'limit': limit.toString(),
      'resolve': 'true', // リモートアカウントも検索
    },
  );

  try {
    final response = await httpClient.get(
      uri,
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (response.statusCode == 200) {
      final Map<String, dynamic> result = jsonDecode(response.body);
      final List<dynamic> accountsJson = result['accounts'] ?? [];
      return accountsJson.map((json) => Account.fromJson(json)).toList();
    } else {
      throw Exception('Failed to search accounts: ${response.statusCode}');
    }
  } catch (e) {
    rethrow;
  }
}

/// 予約投稿用の安全なStatusオブジェクトを作成
Status _createScheduledPostStatus({
  required Map<String, dynamic> responseBody,
  required String statusText,
  required String visibility,
  required bool sensitive,
  String? spoilerText,
  required DateTime scheduledAt,
}) {
  // 安全にIDを取得
  final id = responseBody['id']?.toString() ?? 'scheduled_${DateTime.now().millisecondsSinceEpoch}';
  
  // 最小限かつ安全なStatusオブジェクトを作成
  return Status(
    id: id,
    createdAt: scheduledAt,
    content: statusText,
    visibility: visibility,
    account: Account(
      id: 'temp_scheduled',
      username: 'scheduled',
      displayName: 'Scheduled Post',
      acct: 'scheduled',
      url: '',
      avatarUrl: '',
      headerUrl: '',
      note: '',
      fields: [],
      followersCount: 0,
      followingCount: 0,
      statusesCount: 0,
      createdAt: DateTime.now(),
      locked: false,
      bot: false,
      emojis: [],
    ),
    mediaAttachments: [],
    emojis: [],
    reblogged: false,
    favourited: false,
    bookmarked: false,
    sensitive: sensitive,
    spoilerText: spoilerText ?? '',
    poll: null,
  );
}

/// 投票を取得
Future<Poll> fetchPoll({
  required String instanceUrl,
  required String accessToken,
  required String pollId,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/polls/$pollId');
  final resp = await httpClient.get(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  
  if (resp.statusCode == 200) {
    return Poll.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  } else {
    throw Exception('投票取得失敗: ${resp.statusCode}');
  }
}

/// 他のインスタンスでステータスを解決
Future<String?> resolveStatusOnInstance({
  required String instanceUrl,
  required String accessToken,
  required String originalStatusUrl,
}) async {
  try {
    debugPrint('Resolving status on instance: $instanceUrl');
    debugPrint('Original status URL: $originalStatusUrl');
    
    // 検索APIを使用してステータスを解決
    final searchResult = await searchContent(
      instanceUrl: instanceUrl,
      accessToken: accessToken,
      query: originalStatusUrl,
      resolve: true,
      limit: 1,
    );
    
    final statuses = searchResult['statuses'] as List<Status>?;
    if (statuses != null && statuses.isNotEmpty) {
      final resolvedStatus = statuses.first;
      debugPrint('Resolved status ID: ${resolvedStatus.id}');
      return resolvedStatus.id;
    } else {
      debugPrint('No statuses found in search result');
      return null;
    }
  } catch (e) {
    debugPrint('Error resolving status: $e');
    return null;
  }
}

/// [resolveStatusOnInstanceCached] の成功結果キャッシュ
/// ("instanceUrl|originalStatusUrl" → 解決済みローカル status ID)。
/// `_instanceConfigCache` と同方針の in-memory キャッシュ。ID は不変なので
/// TTL は不要。失敗 (null) はキャッシュしない (連合遅延・一時エラーで
/// 後から成功しうるため)。
final BoundedMap<String, String> _resolvedStatusIdCache = BoundedMap(500);

/// テスト用: 解決結果キャッシュをクリアする。
@visibleForTesting
void clearResolvedStatusIdCacheForTest() => _resolvedStatusIdCache.clear();

/// [resolveStatusOnInstance] のキャッシュ付きラッパー。
///
/// リモートビュー (プロフィールの「相手サーバーから読み込む」等) の投稿に
/// 同じアカウントで複数回アクションする際、毎回 search (resolve=true、
/// サーバー側のリモート fetch を伴い数秒かかりうる) を飛ばさないため。
Future<String?> resolveStatusOnInstanceCached({
  required String instanceUrl,
  required String accessToken,
  required String originalStatusUrl,
}) async {
  final key = '$instanceUrl|$originalStatusUrl';
  final hit = _resolvedStatusIdCache[key];
  if (hit != null) return hit;
  final id = await resolveStatusOnInstance(
    instanceUrl: instanceUrl,
    accessToken: accessToken,
    originalStatusUrl: originalStatusUrl,
  );
  if (id != null) _resolvedStatusIdCache[key] = id;
  return id;
}

/// `isMisskeyInstance` の判定結果キャッシュ (instanceUrl → bool)。
/// 同一プロセス内で同じサーバーへ何度も `/api/meta` を投げないため。
final Map<String, bool> _misskeyInstanceCache = {};

/// インスタンスが Misskey 系かどうかを判定する。
///
/// Misskey は Mastodon API (`/api/v1/accounts/lookup` 等) を実装しないため、
/// 「相手サーバーからプロフィールを読み込む」の失敗時に、原因が Misskey か
/// どうかを切り分けてユーザー向けメッセージを出し分けるのに使う。
///
/// Misskey 系（Misskey / Firefish / Sharkey / CherryPick 等）かどうかを判定する。
///
/// 判定は 2 段:
/// 1. **nodeinfo**（標準・GET）: `/.well-known/nodeinfo` → `links[].href` →
///    nodeinfo 本体の `software.name` を見る。Mastodon/Misskey 双方が実装する
///    クロスプラットフォーム標準なので最も確実。
/// 2. **`/api/meta`**（POST）フォールバック: nodeinfo が取れないときに Misskey
///    固有エンドポイントの存在で判定（200 かつ `version` を持つ JSON）。
///
/// どちらも `User-Agent` を付ける。misskey.io 等は Cloudflare の bot 対策で
/// UA 無しリクエストを弾くことがあり、それが「判定できない」主因になりうる。
/// 非 200 / 例外 / タイムアウトは false（= Mastodon 系として扱う）。
Future<bool> isMisskeyInstance(String instanceUrl) async {
  final cached = _misskeyInstanceCache[instanceUrl];
  if (cached != null) return cached;
  final result = await _detectMisskey(instanceUrl);
  _misskeyInstanceCache[instanceUrl] = result;
  return result;
}

const Map<String, String> _detectUaHeader = {'User-Agent': 'Kurage'};
const List<String> _misskeyFamilyNames = [
  'misskey',
  'firefish',
  'sharkey',
  'cherrypick',
  'foundkey',
  'iceshrimp',
  'calckey',
];

Future<bool> _detectMisskey(String instanceUrl) async {
  // 1) nodeinfo
  try {
    final wk = await http
        .get(Uri.parse('$instanceUrl/.well-known/nodeinfo'),
            headers: _detectUaHeader)
        .timeout(const Duration(seconds: 5));
    if (wk.statusCode == 200) {
      final links = (jsonDecode(wk.body) as Map)['links'];
      String? href;
      if (links is List) {
        for (final l in links) {
          if (l is Map && l['href'] is String) href = l['href'] as String;
        }
      }
      if (href != null) {
        final ni = await http
            .get(Uri.parse(href), headers: _detectUaHeader)
            .timeout(const Duration(seconds: 5));
        if (ni.statusCode == 200) {
          final software = (jsonDecode(ni.body) as Map)['software'];
          final name = (software is Map ? software['name'] : null)
                  ?.toString()
                  .toLowerCase() ??
              '';
          if (name.isNotEmpty) {
            return _misskeyFamilyNames.any((m) => name.contains(m));
          }
        }
      }
    }
  } catch (_) {
    // nodeinfo が取れなければ /api/meta にフォールバック
  }

  // 2) /api/meta（Misskey 固有）
  try {
    final resp = await http
        .post(
          Uri.parse('$instanceUrl/api/meta'),
          headers: {'Content-Type': 'application/json', ..._detectUaHeader},
          body: '{}',
        )
        .timeout(const Duration(seconds: 5));
    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body);
      return data is Map && data.containsKey('version');
    }
  } catch (_) {
    // 非対応 / ネットワークエラーは Mastodon 系として扱う
  }
  return false;
}

/// サーバー情報を取得
Future<Map<String, dynamic>> fetchServerInfo({
  required String instanceUrl,
  String? accessToken,
}) async {
  try {
    // まず /api/v1/instance を試す
    final instanceUri = Uri.parse('$instanceUrl/api/v1/instance');
    final headers = <String, String>{};
    if (accessToken != null) {
      headers['Authorization'] = 'Bearer $accessToken';
    }
    
    final instanceResp = await httpClient.get(instanceUri, headers: headers);
    
    Map<String, dynamic> serverInfo = {};
    
    if (instanceResp.statusCode == 200) {
      final instanceData = jsonDecode(instanceResp.body) as Map<String, dynamic>;
      serverInfo = {
        'title': instanceData['title'] ?? 'Unknown',
        'description': instanceData['description'] ?? '',
        'short_description': instanceData['short_description'] ?? '',
        'version': instanceData['version'] ?? '',
        'uri': instanceData['uri'] ?? instanceUrl,
        'languages': instanceData['languages'] ?? [],
        'registrations': instanceData['registrations'] ?? false,
        'approval_required': instanceData['approval_required'] ?? false,
        'invites_enabled': instanceData['invites_enabled'] ?? false,
        'configuration': instanceData['configuration'] ?? {},
        'contact_account': instanceData['contact_account'],
        'rules': instanceData['rules'] ?? [],
        'stats': instanceData['stats'] ?? {},
      };
    }
    
    // ノードインフォも取得を試す（オプション）
    try {
      final nodeInfoUri = Uri.parse('$instanceUrl/nodeinfo/2.0');
      final nodeInfoResp = await httpClient.get(nodeInfoUri);
      if (nodeInfoResp.statusCode == 200) {
        final nodeInfoData = jsonDecode(nodeInfoResp.body) as Map<String, dynamic>;
        serverInfo['nodeinfo'] = {
          'software': nodeInfoData['software'],
          'protocols': nodeInfoData['protocols'],
          'services': nodeInfoData['services'],
          'usage': nodeInfoData['usage'],
          'metadata': nodeInfoData['metadata'],
        };
      }
    } catch (e) {
      debugPrint('NodeInfo not available: $e');
    }
    
    return serverInfo;
  } catch (e) {
    debugPrint('Error fetching server info: $e');
    return {'error': e.toString()};
  }
}


/// ハッシュタグ候補を検索
Future<List<String>> searchHashtags({
  required String instanceUrl,
  required String accessToken,
  required String query,
  int limit = 10,
}) async {
  try {
    final uri = Uri.parse('$instanceUrl/api/v2/search').replace(
      queryParameters: {
        'q': '#$query',
        'type': 'hashtags',
        'limit': limit.toString(),
        'resolve': 'false',
      },
    );
    
    final response = await httpClient.get(
      uri,
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    
    if (response.statusCode == 200) {
      final Map<String, dynamic> jsonData = jsonDecode(response.body);
      final List<dynamic> hashtags = jsonData['hashtags'] ?? [];
      return hashtags.map((tag) {
        // タグ名を抽出（オブジェクトまたは文字列の場合がある）
        if (tag is Map<String, dynamic>) {
          return tag['name']?.toString() ?? '';
        } else {
          return tag.toString();
        }
      }).where((tag) => tag.isNotEmpty).toList();
    } else {
      debugPrint('Hashtag search failed: ${response.statusCode}');
      return [];
    }
  } catch (e) {
    debugPrint('Error searching hashtags: $e');
    return [];
  }
}

/// 予約投稿一覧を取得
Future<List<Map<String, dynamic>>> fetchScheduledStatuses({
  required String instanceUrl,
  required String accessToken,
  int limit = 20,
  String? maxId,
  String? sinceId,
}) async {
  final params = <String>['limit=$limit'];
  if (maxId != null) params.add('max_id=$maxId');
  if (sinceId != null) params.add('since_id=$sinceId');
  
  final query = params.isNotEmpty ? '?${params.join('&')}' : '';
  final uri = Uri.parse('$instanceUrl/api/v1/scheduled_statuses$query');
  
  final resp = await httpClient.get(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  
  if (resp.statusCode == 200) {
    final List<dynamic> jsonList = jsonDecode(resp.body);
    return jsonList.cast<Map<String, dynamic>>();
  } else {
    throw Exception('予約投稿一覧取得失敗: ${resp.statusCode}');
  }
}

/// 予約投稿を削除
Future<void> deleteScheduledStatus({
  required String instanceUrl,
  required String accessToken,
  required String scheduledStatusId,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/scheduled_statuses/$scheduledStatusId');
  
  final resp = await httpClient.delete(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  
  if (resp.statusCode != 200) {
    throw Exception('予約投稿削除失敗: ${resp.statusCode}');
  }
}

/// 予約投稿を更新
Future<Map<String, dynamic>> updateScheduledStatus({
  required String instanceUrl,
  required String accessToken,
  required String scheduledStatusId,
  required DateTime scheduledAt,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/scheduled_statuses/$scheduledStatusId');
  
  final headers = {
    'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/x-www-form-urlencoded',
  };
  
  final body = 'scheduled_at=${Uri.encodeQueryComponent(scheduledAt.toUtc().toIso8601String())}';
  
  final resp = await httpClient.put(
    uri,
    headers: headers,
    body: body,
  );
  
  if (resp.statusCode == 200) {
    return jsonDecode(resp.body) as Map<String, dynamic>;
  } else {
    throw Exception('予約投稿更新失敗: ${resp.statusCode}');
  }
}

/// 投票する
Future<Poll> votePoll({
  required String instanceUrl,
  required String accessToken,
  required String pollId,
  required List<int> choices,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/polls/$pollId/votes');
  final headers = {
    'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/x-www-form-urlencoded',
  };

  final parts = <String>[];
  for (final choice in choices) {
    parts.add('choices[]=${Uri.encodeQueryComponent(choice.toString())}');
  }

  final req = http.Request('POST', uri)
    ..headers.addAll(headers)
    ..body = parts.join('&');

  final streamed = await httpClient.send(req);
  final resp = await http.Response.fromStream(streamed);

  if (resp.statusCode == 200) {
    return Poll.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  } else {
    throw Exception('投票失敗: ${resp.statusCode}\n${resp.body}');
  }
}

/// カスタム絵文字一覧を取得
Future<List<Emoji>> fetchCustomEmojis({
  required String instanceUrl,
  required String accessToken,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/custom_emojis');
  
  final resp = await httpClient.get(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  
  if (resp.statusCode == 200) {
    final List<dynamic> jsonList = jsonDecode(resp.body);
    return jsonList.map((json) => Emoji.fromJson(json as Map<String, dynamic>)).toList();
  } else {
    throw Exception('カスタム絵文字取得失敗: ${resp.statusCode}');
  }
}

/// 会話一覧を取得
Future<List<Conversation>> fetchConversations({
  required String instanceUrl,
  required String accessToken,
  String? maxId,
  String? sinceId,
  int limit = 20,
}) async {
  final params = <String>['limit=$limit'];
  if (maxId != null) params.add('max_id=$maxId');
  if (sinceId != null) params.add('since_id=$sinceId');
  
  final query = params.isNotEmpty ? '?${params.join('&')}' : '';
  final uri = Uri.parse('$instanceUrl/api/v1/conversations$query');
  
  try {
    final resp = await httpClient.get(
      uri,
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    
    if (resp.statusCode == 200) {
      final List<dynamic> jsonList = jsonDecode(resp.body);
      return jsonList.map((json) => Conversation.fromJson(json as Map<String, dynamic>)).toList();
    } else {
      throw Exception('会話一覧取得失敗: ${resp.statusCode}');
    }
  } catch (e) {
    rethrow;
  }
}

/// 会話を既読にする
Future<Conversation> markConversationRead({
  required String instanceUrl,
  required String accessToken,
  required String conversationId,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/conversations/$conversationId/read');
  
  final resp = await httpClient.post(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  
  if (resp.statusCode == 200) {
    return Conversation.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  } else {
    throw Exception('会話既読化失敗: ${resp.statusCode}');
  }
}

/// 会話を削除
Future<void> deleteConversation({
  required String instanceUrl,
  required String accessToken,
  required String conversationId,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/conversations/$conversationId');
  
  final resp = await httpClient.delete(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  
  if (resp.statusCode != 200) {
    throw Exception('会話削除失敗: ${resp.statusCode}');
  }
}

/// プロフィールを更新
Future<Account> updateProfile({
  required String instanceUrl,
  required String accessToken,
  String? displayName,
  String? note,
  bool? locked,
  bool? bot,
  List<Map<String, String>>? fields,
  XFile? avatarFile,
  XFile? headerFile,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/accounts/update_credentials');

  // マルチパートリクエストを作成
  final request = http.MultipartRequest('PATCH', uri);
  request.headers['Authorization'] = 'Bearer $accessToken';

  // テキストフィールドの追加
  if (displayName != null) {
    request.fields['display_name'] = displayName;
  }
  if (note != null) {
    request.fields['note'] = note;
  }
  if (locked != null) {
    request.fields['locked'] = locked.toString();
  }
  if (bot != null) {
    request.fields['bot'] = bot.toString();
  }

  // プロフィール補足フィールドの追加
  if (fields != null) {
    for (int i = 0; i < fields.length && i < 4; i++) {
      final field = fields[i];
      if (field['name'] != null) {
        request.fields['fields_attributes[$i][name]'] = field['name']!;
      }
      if (field['value'] != null) {
        request.fields['fields_attributes[$i][value]'] = field['value']!;
      }
    }
  }

  // アバター画像の追加
  if (avatarFile != null) {
    final avatarBytes = await avatarFile.readAsBytes();
    final avatarMime = avatarFile.mimeType ??
        lookupMimeType(avatarFile.name) ??
        'image/jpeg';
    request.files.add(
      http.MultipartFile.fromBytes(
        'avatar',
        avatarBytes,
        filename: 'avatar.jpg',
        contentType: MediaType.parse(avatarMime),
      ),
    );
  }

  // ヘッダー画像の追加
  if (headerFile != null) {
    final headerBytes = await headerFile.readAsBytes();
    final headerMime = headerFile.mimeType ??
        lookupMimeType(headerFile.name) ??
        'image/jpeg';
    request.files.add(
      http.MultipartFile.fromBytes(
        'header',
        headerBytes,
        filename: 'header.jpg',
        contentType: MediaType.parse(headerMime),
      ),
    );
  }
  
  // リクエストを送信
  final streamedResponse = await httpClient.send(request);
  final resp = await http.Response.fromStream(streamedResponse);
  
  if (resp.statusCode == 200) {
    return Account.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  } else {
    throw Exception('プロフィール更新失敗: ${resp.statusCode} - ${resp.body}');
  }
}

/// `/api/v1/profile` (Mastodon 4.6+) に未対応のサーバ (404) を表す。
/// 呼び出し側はこれを握って従来の `update_credentials` 経路へフォールバックする。
class ProfileApiNotSupportedException implements Exception {
  final int statusCode;
  ProfileApiNotSupportedException([this.statusCode = 404]);
  @override
  String toString() => 'ProfileApiNotSupportedException($statusCode): '
      'このサーバは /api/v1/profile (4.6+) に未対応です';
}

/// Mastodon 4.6+ の `GET /api/v1/profile`。自分のプロフィールを *raw text*
/// (note / fields が編集用の生テキスト) で取得する。`update_credentials` と
/// 違い、avatar_description / show_media / attribution_domains 等も返る。
/// 未対応サーバ (404) は [ProfileApiNotSupportedException] を投げる。
Future<Profile> fetchProfile({
  required String instanceUrl,
  required String accessToken,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/profile');
  final resp = await httpClient.get(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode == 404) {
    throw ProfileApiNotSupportedException(404);
  }
  if (resp.statusCode != 200) {
    throw Exception('プロフィール取得 (4.6) 失敗: ${resp.statusCode}');
  }
  return Profile.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
}

/// Mastodon 4.6+ の `PATCH /api/v1/profile`。画像本体ではなく、4.6 で追加された
/// メタ情報 (アバター/ヘッダーの代替テキスト、各タブ表示設定、attribution_domains
/// 等) を更新する。画像アップロードは従来どおり [updateProfile]
/// (`update_credentials`) を使う棲み分け。
///
/// 未対応サーバ (404) は [ProfileApiNotSupportedException] を投げる。
/// 422 はバリデーションエラー (代替テキストが長すぎる等) なので本文付きで
/// そのまま投げ、呼び出し側でユーザーに理由を見せられるようにする。
Future<Profile> updateProfileMeta({
  required String instanceUrl,
  required String accessToken,
  String? avatarDescription,
  String? headerDescription,
  bool? showMedia,
  bool? showMediaReplies,
  bool? showFeatured,
  bool? hideCollections,
  bool? discoverable,
  bool? indexable,
  List<String>? attributionDomains,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/profile');
  // 指定された項目だけ送る (null は据え置き)。
  final body = <String, dynamic>{
    if (avatarDescription != null) 'avatar_description': avatarDescription,
    if (headerDescription != null) 'header_description': headerDescription,
    if (showMedia != null) 'show_media': showMedia,
    if (showMediaReplies != null) 'show_media_replies': showMediaReplies,
    if (showFeatured != null) 'show_featured': showFeatured,
    if (hideCollections != null) 'hide_collections': hideCollections,
    if (discoverable != null) 'discoverable': discoverable,
    if (indexable != null) 'indexable': indexable,
    if (attributionDomains != null) 'attribution_domains': attributionDomains,
  };
  final resp = await httpClient.patch(
    uri,
    headers: {
      'Authorization': 'Bearer $accessToken',
      'Content-Type': 'application/json',
    },
    body: jsonEncode(body),
  );
  if (resp.statusCode == 404) {
    throw ProfileApiNotSupportedException(404);
  }
  if (resp.statusCode != 200) {
    throw Exception(
        'プロフィール更新 (4.6) 失敗: ${resp.statusCode} - ${resp.body}');
  }
  return Profile.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
}

/// 投稿を削除
Future<void> deleteStatus({
  required String instanceUrl,
  required String accessToken,
  required String statusId,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/statuses/$statusId');
  final resp = await httpClient.delete(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  
  if (resp.statusCode != 200) {
    throw Exception('投稿削除失敗: ${resp.statusCode} - ${resp.body}');
  }
}

/// 投稿を編集用に取得
Future<Map<String, dynamic>> getStatusSource({
  required String instanceUrl,
  required String accessToken,
  required String statusId,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/statuses/$statusId/source');
  final resp = await httpClient.get(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  
  if (resp.statusCode == 200) {
    return jsonDecode(resp.body) as Map<String, dynamic>;
  } else {
    throw Exception('投稿ソース取得失敗: ${resp.statusCode} - ${resp.body}');
  }
}

/// 投稿の編集履歴 (`GET /api/v1/statuses/:id/history`) を取得する。
///
/// レスポンスは **古い順** で返ってくる (= 配列先頭が初版、末尾が最新版)。
/// 一度も編集されていない投稿でも初版 1 件だけが返る (空配列にはならない)。
///
/// 古い Mastodon (3.x 以前) や派生実装で 404 が返るケースは「履歴に対応して
/// いないサーバ」とみなして空リストを返す (呼び出し側のフォールバックを
/// 単純化するため)。
Future<List<StatusEdit>> fetchStatusHistory({
  required String instanceUrl,
  required String accessToken,
  required String statusId,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/statuses/$statusId/history');
  final resp = await httpClient.get(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );

  if (resp.statusCode == 200) {
    final list = jsonDecode(resp.body) as List<dynamic>;
    return list
        .map((e) => StatusEdit.fromJson(e as Map<String, dynamic>))
        .toList();
  }
  if (resp.statusCode == 404 || resp.statusCode == 405) {
    return <StatusEdit>[];
  }
  throw Exception('編集履歴の取得失敗: ${resp.statusCode}\n${resp.body}');
}

/// インスタンスのルール一覧を取得する。
///
/// `GET /api/v1/instance/rules` (Mastodon 4.0+) を試し、404/405 等で取れない
/// サーバでは `GET /api/v1/instance` の `rules` フィールド (3.4+) を見る。
/// それでも取れなければ空配列。通報フォームで「どのルールに違反したか」の
/// チェックボックス選択用。認証は不要だが、access_token があれば渡す
/// (instance によっては未認証要求を rate-limit する)。
Future<List<InstanceRule>> fetchInstanceRules({
  required String instanceUrl,
  String? accessToken,
}) async {
  final headers = <String, String>{
    if (accessToken != null && accessToken.isNotEmpty)
      'Authorization': 'Bearer $accessToken',
  };

  // 1) 専用 endpoint を試す
  try {
    final resp = await httpClient.get(
      Uri.parse('$instanceUrl/api/v1/instance/rules'),
      headers: headers,
    );
    if (resp.statusCode == 200) {
      final list = jsonDecode(resp.body) as List<dynamic>;
      return list
          .map((j) => InstanceRule.fromJson(j as Map<String, dynamic>))
          .toList();
    }
  } catch (_) {
    // ネットワーク例外はフォールバックに委ねる
  }

  // 2) /api/v1/instance に埋め込まれた rules を見る
  try {
    final resp = await httpClient.get(
      Uri.parse('$instanceUrl/api/v1/instance'),
      headers: headers,
    );
    if (resp.statusCode == 200) {
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final rules = body['rules'];
      if (rules is List) {
        return rules
            .whereType<Map<String, dynamic>>()
            .map((j) => InstanceRule.fromJson(j))
            .toList();
      }
    }
  } catch (_) {
    // 何も取れなければ空配列フォールバック
  }
  return <InstanceRule>[];
}

/// 通報を送信する (`POST /api/v1/reports`)。
///
/// パラメタは Mastodon 仕様に対応:
///  - [accountId]: 通報対象アカウント (必須)
///  - [statusIds]: 関連する投稿の id 一覧 (任意)
///  - [comment]: 自由記述コメント (1000 字以内、サーバ側で truncate される)
///  - [forward]: リモートアカウントの場合、相手サーバへ通報を転送するか
///  - [category]: `spam` / `violation` / `legal` / `other`
///  - [ruleIds]: `category=violation` のとき、違反したルール id 配列
///
/// Mastodon は配列パラメタを `status_ids[]=A&status_ids[]=B` の形で受け取る。
/// http パッケージは同じキーの複数値を直接渡せないため form 文字列を手で組む。
Future<void> submitReport({
  required String instanceUrl,
  required String accessToken,
  required String accountId,
  List<String> statusIds = const [],
  String comment = '',
  bool forward = false,
  String category = 'other',
  List<String> ruleIds = const [],
}) async {
  final parts = <String>[
    'account_id=${Uri.encodeQueryComponent(accountId)}',
    'category=${Uri.encodeQueryComponent(category)}',
    'forward=${forward ? 'true' : 'false'}',
    if (comment.isNotEmpty) 'comment=${Uri.encodeQueryComponent(comment)}',
    for (final id in statusIds)
      'status_ids[]=${Uri.encodeQueryComponent(id)}',
    for (final id in ruleIds) 'rule_ids[]=${Uri.encodeQueryComponent(id)}',
  ];
  final resp = await httpClient.post(
    Uri.parse('$instanceUrl/api/v1/reports'),
    headers: {
      'Authorization': 'Bearer $accessToken',
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: parts.join('&'),
  );
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw Exception('通報の送信失敗: ${resp.statusCode} ${resp.body}');
  }
}

/// 投稿をブーストしたアカウント一覧 (`GET /api/v1/statuses/:id/reblogged_by`)。
///
/// Mastodon の `limit` 既定は 40、最大 80。**ページネーションは Link ヘッダ方式**:
/// このエンドポイントの `max_id` カーソルはサーバ内部の Reblog レコード id で、
/// 返ってくる `Account.id` とは別物。フォロー/フォロワー等の「末尾 Account.id を
/// max_id に渡す」簡易方式はここでは正しく動かず、Account の snowflake id (巨大値)
/// を渡すと毎回同じ先頭 40 件が返って 40 件で止まる。続きを取るには返り値の
/// `nextMaxId` (Link ヘッダの rel="next" から抽出) を次回 [maxId] に渡すこと。
///
/// 鍵アカウントの投稿などサーバが「閲覧者にはこの一覧を見せない」と判断した
/// 場合は 401/403/404 が返る。古い派生実装で endpoint が無いケースも 404 で
/// 区別がつかないため、いずれも空ページとして扱い呼び出し側の UI 簡素化を優先。
Future<AccountPage> fetchRebloggedBy({
  required String instanceUrl,
  required String accessToken,
  required String statusId,
  String? maxId,
  int limit = 40,
}) =>
    _fetchAccountPageWithLinkPagination(
      instanceUrl: instanceUrl,
      accessToken: accessToken,
      path: '/api/v1/statuses/$statusId/reblogged_by',
      maxId: maxId,
      limit: limit,
      treat404AsEmpty: true,
    );

/// 投稿をお気に入りしたアカウント一覧 (`GET /api/v1/statuses/:id/favourited_by`)。
///
/// 仕様 / フォールバックの考え方は [fetchRebloggedBy] と同じ (Link ヘッダ方式)。
Future<AccountPage> fetchFavouritedBy({
  required String instanceUrl,
  required String accessToken,
  required String statusId,
  String? maxId,
  int limit = 40,
}) =>
    _fetchAccountPageWithLinkPagination(
      instanceUrl: instanceUrl,
      accessToken: accessToken,
      path: '/api/v1/statuses/$statusId/favourited_by',
      maxId: maxId,
      limit: limit,
      treat404AsEmpty: true,
    );

/// プッシュ購読を作成
Future<Map<String, dynamic>?> createPushSubscription({
  required String instanceUrl,
  required String accessToken,
  required String endpoint,
  required String p256dh,
  required String auth,
  required Map<String, bool> alerts,
}) async {
  final body = {
    'subscription': {
      'endpoint': endpoint,
      'keys': {
        'p256dh': p256dh,
        'auth': auth,
      },
    },
    'data': {
      'alerts': alerts,
    },
  };

  final response = await httpClient.post(
    Uri.parse('$instanceUrl/api/v1/push/subscription'),
    headers: {
      'Authorization': 'Bearer $accessToken',
      'Content-Type': 'application/json',
    },
    body: jsonEncode(body),
  );

  if (response.statusCode == 200) {
    return jsonDecode(response.body) as Map<String, dynamic>;
  }
  debugPrint(
      '[Push] createPushSubscription failed: ${response.statusCode} ${response.body}');
  return null;
}

/// プッシュ購読を削除
Future<void> deletePushSubscription({
  required String instanceUrl,
  required String accessToken,
}) async {
  await httpClient.delete(
    Uri.parse('$instanceUrl/api/v1/push/subscription'),
    headers: {
      'Authorization': 'Bearer $accessToken',
    },
  );
}

/// 投稿を翻訳
Future<Translation> translateStatus({
  required String instanceUrl,
  required String accessToken,
  required String statusId,
  String targetLanguage = 'ja', // デフォルトで日本語に翻訳
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/statuses/$statusId/translate');
  final headers = {
    'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/x-www-form-urlencoded',
  };
  
  // 目標言語を指定するパラメータを追加
  final body = 'lang=${Uri.encodeQueryComponent(targetLanguage)}';
  
  try {
    final resp = await httpClient.post(
      uri,
      headers: headers,
      body: body,
    );
    
    if (resp.statusCode == 200) {
      return Translation.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
    } else if (resp.statusCode == 403) {
      // 同じ言語の場合やその他の理由で翻訳が許可されない
      throw TranslationNotAllowedException('翻訳が許可されていません: ${resp.body}');
    } else if (resp.statusCode == 404) {
      // 翻訳機能が有効でない、または投稿が見つからない
      throw TranslationNotSupportedException('翻訳機能が利用できません');
    } else if (resp.statusCode == 503) {
      // 翻訳サービスが利用できない
      throw TranslationServiceUnavailableException('翻訳サービスが一時的に利用できません');
    } else {
      throw Exception('翻訳失敗: ${resp.statusCode} - ${resp.body}');
    }
  } catch (e) {
    if (e is TranslationException) {
      rethrow;
    }
    throw TranslationException('翻訳中にエラーが発生しました: $e');
  }
}

/// 翻訳結果クラス
class Translation {
  final String content;
  final String? spoilerText;
  final String detectedSourceLanguage;
  final String provider;
  final List<TranslationAttachment>? mediaAttachments;
  final TranslationPoll? poll;

  Translation({
    required this.content,
    this.spoilerText,
    required this.detectedSourceLanguage,
    required this.provider,
    this.mediaAttachments,
    this.poll,
  });

  factory Translation.fromJson(Map<String, dynamic> json) {
    return Translation(
      content: json['content'] as String,
      spoilerText: json['spoiler_text'] as String?,
      detectedSourceLanguage: json['detected_source_language'] as String,
      provider: json['provider'] as String,
      mediaAttachments: (json['media_attachments'] as List<dynamic>?)
          ?.map((attachment) => TranslationAttachment.fromJson(attachment as Map<String, dynamic>))
          .toList(),
      poll: json['poll'] != null 
          ? TranslationPoll.fromJson(json['poll'] as Map<String, dynamic>)
          : null,
    );
  }
}

/// 翻訳されたメディア添付ファイル
class TranslationAttachment {
  final String id;
  final String description;

  TranslationAttachment({
    required this.id,
    required this.description,
  });

  factory TranslationAttachment.fromJson(Map<String, dynamic> json) {
    return TranslationAttachment(
      id: json['id'] as String,
      description: json['description'] as String,
    );
  }
}

/// 翻訳されたアンケート
class TranslationPoll {
  final String id;
  final List<TranslationPollOption> options;

  TranslationPoll({
    required this.id,
    required this.options,
  });

  factory TranslationPoll.fromJson(Map<String, dynamic> json) {
    return TranslationPoll(
      id: json['id'] as String,
      options: (json['options'] as List<dynamic>)
          .map((option) => TranslationPollOption.fromJson(option as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// 翻訳されたアンケートオプション
class TranslationPollOption {
  final String title;

  TranslationPollOption({
    required this.title,
  });

  factory TranslationPollOption.fromJson(Map<String, dynamic> json) {
    return TranslationPollOption(
      title: json['title'] as String,
    );
  }
}

/// 翻訳例外の基底クラス
class TranslationException implements Exception {
  final String message;
  TranslationException(this.message);
  
  @override
  String toString() => message;
}

/// 翻訳が許可されていない場合の例外
class TranslationNotAllowedException extends TranslationException {
  TranslationNotAllowedException(super.message);
}

/// 翻訳機能がサポートされていない場合の例外
class TranslationNotSupportedException extends TranslationException {
  TranslationNotSupportedException(super.message);
}

/// 翻訳サービスが利用できない場合の例外
class TranslationServiceUnavailableException extends TranslationException {
  TranslationServiceUnavailableException(super.message);
}

// ---------------------------------------------------------------------------
// Filters v2 (Mastodon 4.0+)
//
// サーバ側のキーワードフィルタ機能。`/api/v2/filters` 一連の CRUD を提供し、
// マッチした投稿はサーバから `filtered` フィールド付きで返るので、クライアントは
// それを尊重して hide/warn する (Status.isFilterHidden / isFilterWarned)。
//
// 古い Mastodon (3.x 以前) や派生実装 (Misskey/Pleroma 等) で 404 が返るケースは、
// 「フィルタ機能はこのサーバでは未提供」とみなして上位で空配列を返す方針
// (一覧取得のみ)。作成/更新/削除側で 404 のときは
// `FiltersNotSupportedException` を投げて UI 側で案内できるようにする。
// ---------------------------------------------------------------------------

/// フィルタ機能未対応サーバを示す例外
class FiltersNotSupportedException implements Exception {
  final String message;
  FiltersNotSupportedException([this.message = 'このサーバはフィルタ機能 (v2) に未対応です']);
  @override
  String toString() => message;
}

/// `GET /api/v2/filters` — 自分のフィルタ一覧。
///
/// 未対応サーバでは空配列を返す (上位で「フィルタは利用できません」の案内に
/// 切り替えやすいよう)。
Future<List<MastodonFilter>> fetchFilters({
  required String instanceUrl,
  required String accessToken,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v2/filters');
  final resp = await httpClient.get(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode == 200) {
    final list = jsonDecode(resp.body) as List<dynamic>;
    return list
        .map((j) => MastodonFilter.fromJson(j as Map<String, dynamic>))
        .toList();
  }
  if (resp.statusCode == 404) return const [];
  throw Exception('フィルタ取得エラー: ${resp.statusCode}');
}

/// `GET /api/v2/filters/:id` — 単一フィルタの詳細
Future<MastodonFilter> fetchFilter({
  required String instanceUrl,
  required String accessToken,
  required String filterId,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v2/filters/$filterId');
  final resp = await httpClient.get(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode == 200) {
    return MastodonFilter.fromJson(
      jsonDecode(resp.body) as Map<String, dynamic>,
    );
  }
  if (resp.statusCode == 404) throw FiltersNotSupportedException();
  throw Exception('フィルタ取得エラー: ${resp.statusCode}');
}

/// `POST /api/v2/filters` — フィルタを新規作成。
///
/// [context] は 'home' / 'notifications' / 'public' / 'thread' / 'account'
/// から 1 つ以上。[filterAction] は 'warn' か 'hide'。[expiresIn] は失効までの
/// 秒数 (null で無期限)。[keywords] は同時にキーワードもまとめて登録する。
///
/// 配列パラメタが nested (`keywords_attributes[0][keyword]` 等) なので
/// http.body の Map ではなく URL エンコードした form 文字列を手書き。
Future<MastodonFilter> createFilter({
  required String instanceUrl,
  required String accessToken,
  required String title,
  required List<String> context,
  String filterAction = 'warn',
  int? expiresIn,
  List<({String keyword, bool wholeWord})> keywords = const [],
}) async {
  final parts = <String>[
    'title=${Uri.encodeQueryComponent(title)}',
    'filter_action=${Uri.encodeQueryComponent(filterAction)}',
    if (expiresIn != null) 'expires_in=$expiresIn',
    for (final c in context) 'context[]=${Uri.encodeQueryComponent(c)}',
    for (var i = 0; i < keywords.length; i++) ...[
      'keywords_attributes[$i][keyword]=${Uri.encodeQueryComponent(keywords[i].keyword)}',
      'keywords_attributes[$i][whole_word]=${keywords[i].wholeWord ? 'true' : 'false'}',
    ],
  ];
  final resp = await httpClient.post(
    Uri.parse('$instanceUrl/api/v2/filters'),
    headers: {
      'Authorization': 'Bearer $accessToken',
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: parts.join('&'),
  );
  if (resp.statusCode == 200 || resp.statusCode == 201) {
    return MastodonFilter.fromJson(
      jsonDecode(resp.body) as Map<String, dynamic>,
    );
  }
  if (resp.statusCode == 404) throw FiltersNotSupportedException();
  throw Exception('フィルタ作成エラー: ${resp.statusCode} ${resp.body}');
}

/// `PUT /api/v2/filters/:id` — フィルタ本体 (title / context / filter_action /
/// expires_in) を更新。キーワードの個別更新は別エンドポイント
/// (`/keywords` 配下) があるが、本体更新時に `keywords_attributes` を渡しても
/// 既存キーワードの id を含めれば編集/削除を反映できる (`_destroy=true`)。
///
/// [keywordOps] は省略可。指定した場合はサーバが受けた通りに既存キーワード集合を
/// 上書きする (id 付きで更新 / id 無しで新規 / `_destroy: true` で削除)。
Future<MastodonFilter> updateFilter({
  required String instanceUrl,
  required String accessToken,
  required String filterId,
  String? title,
  List<String>? context,
  String? filterAction,
  int? expiresIn,
  List<({String? id, String keyword, bool wholeWord, bool destroy})>?
      keywordOps,
}) async {
  final parts = <String>[
    if (title != null) 'title=${Uri.encodeQueryComponent(title)}',
    if (filterAction != null)
      'filter_action=${Uri.encodeQueryComponent(filterAction)}',
    if (expiresIn != null) 'expires_in=$expiresIn',
    if (context != null)
      for (final c in context) 'context[]=${Uri.encodeQueryComponent(c)}',
    if (keywordOps != null)
      for (var i = 0; i < keywordOps.length; i++) ...[
        if (keywordOps[i].id != null)
          'keywords_attributes[$i][id]=${Uri.encodeQueryComponent(keywordOps[i].id!)}',
        'keywords_attributes[$i][keyword]=${Uri.encodeQueryComponent(keywordOps[i].keyword)}',
        'keywords_attributes[$i][whole_word]=${keywordOps[i].wholeWord ? 'true' : 'false'}',
        if (keywordOps[i].destroy)
          'keywords_attributes[$i][_destroy]=true',
      ],
  ];
  final resp = await httpClient.put(
    Uri.parse('$instanceUrl/api/v2/filters/$filterId'),
    headers: {
      'Authorization': 'Bearer $accessToken',
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: parts.join('&'),
  );
  if (resp.statusCode == 200) {
    return MastodonFilter.fromJson(
      jsonDecode(resp.body) as Map<String, dynamic>,
    );
  }
  if (resp.statusCode == 404) throw FiltersNotSupportedException();
  throw Exception('フィルタ更新エラー: ${resp.statusCode} ${resp.body}');
}

/// `DELETE /api/v2/filters/:id` — フィルタを削除
Future<void> deleteFilter({
  required String instanceUrl,
  required String accessToken,
  required String filterId,
}) async {
  final resp = await httpClient.delete(
    Uri.parse('$instanceUrl/api/v2/filters/$filterId'),
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode == 200 || resp.statusCode == 204) return;
  if (resp.statusCode == 404) throw FiltersNotSupportedException();
  throw Exception('フィルタ削除エラー: ${resp.statusCode}');
}

/// `POST /api/v2/filters/:id/keywords` — 既存フィルタに新規キーワードを追加。
/// (フィルタ詳細編集画面の「+」ボタン用。更新側でまとめて送る場合は
/// `updateFilter` の `keywordOps` を使う)
Future<FilterKeyword> addFilterKeyword({
  required String instanceUrl,
  required String accessToken,
  required String filterId,
  required String keyword,
  bool wholeWord = false,
}) async {
  final resp = await httpClient.post(
    Uri.parse('$instanceUrl/api/v2/filters/$filterId/keywords'),
    headers: {'Authorization': 'Bearer $accessToken'},
    body: {
      'keyword': keyword,
      'whole_word': wholeWord ? 'true' : 'false',
    },
  );
  if (resp.statusCode == 200 || resp.statusCode == 201) {
    return FilterKeyword.fromJson(
      jsonDecode(resp.body) as Map<String, dynamic>,
    );
  }
  if (resp.statusCode == 404) throw FiltersNotSupportedException();
  throw Exception('キーワード追加エラー: ${resp.statusCode}');
}

// ---------------------------------------------------------------------------
// Grouped Notifications v2 (Mastodon 4.3+)
//
// `/api/v2/notifications` はサーバ側で集約済みのグループを返す。
// レスポンスは notification_groups + accounts + statuses の 3 配列で
// 参照が分離している (= group の sample_account_ids は accounts 配列内の
// id を指す)。client はマップ化して NotificationGroup.fromV2Json に渡して
// 参照解決する。
//
// 古い Mastodon (4.2 以前) や派生実装で 404 のときは
// NotificationsV2NotSupportedException で呼び出し側に通知し、
// 呼び出し側は v1 の fetchNotifications にフォールバックする想定。
// ---------------------------------------------------------------------------

/// `/api/v2/notifications` が 404 (= 未対応サーバ) のときに投げる例外。
/// notifications_provider 側で捕まえてアカウントごとに v1 にフォールバック
/// する。エラーメッセージは UI に出ない (黙ってフォールバック方針)。
class NotificationsV2NotSupportedException implements Exception {
  final String message;
  NotificationsV2NotSupportedException(
      [this.message = 'このサーバは /api/v2/notifications (4.3+) に未対応です']);
  @override
  String toString() => message;
}

/// 通知取得の認証エラー (401/403 — トークン失効・スコープ不足など)。
/// v1 にフォールバックしても同じ失敗をするだけなので、呼び出し側は
/// この例外ではフォールバックせず即座に失敗させる。
class NotificationsAuthException implements Exception {
  final int statusCode;
  NotificationsAuthException(this.statusCode);
  @override
  String toString() => '通知取得の認証エラー (HTTP $statusCode)';
}

/// `GET /api/v2/notifications` — サーバ側で集約済みの通知グループ一覧。
///
/// 返値は `List<NotificationGroup>`。各グループの `sample_account_ids` は
/// レスポンスの `accounts[]` の id を指すので、ここでマップ化してから
/// `NotificationGroup.fromV2Json` に渡して Account/Status を解決する。
///
/// 4.2 以前は 404 で `NotificationsV2NotSupportedException` を投げる。
/// (派生実装も 404 の場合は同じ扱い)
Future<List<NotificationGroup>> fetchNotificationGroups({
  required String instanceUrl,
  required String accessToken,
  int limit = 20,
  String? maxId,
  String? sinceId,
  String? minId,
  List<String>? types,
  List<String>? excludeTypes,
  List<String>? supportedTypes,
}) async {
  final query = <String, String>{
    'limit': limit.toString(),
    if (maxId != null) 'max_id': maxId,
    if (sinceId != null) 'since_id': sinceId,
    if (minId != null) 'min_id': minId,
  };
  // 配列パラメタは Uri.replace の queryParameters では複数値を扱いづらいので、
  // クエリ文字列に直接追加。
  final qs = StringBuffer();
  query.forEach((k, v) {
    if (qs.isNotEmpty) qs.write('&');
    qs.write('${Uri.encodeQueryComponent(k)}=${Uri.encodeQueryComponent(v)}');
  });
  if (types != null) {
    for (final t in types) {
      if (qs.isNotEmpty) qs.write('&');
      qs.write('types[]=${Uri.encodeQueryComponent(t)}');
    }
  }
  if (excludeTypes != null) {
    for (final t in excludeTypes) {
      if (qs.isNotEmpty) qs.write('&');
      qs.write('exclude_types[]=${Uri.encodeQueryComponent(t)}');
    }
  }
  // Mastodon 4.6+: supported_types 以外は fallback 表現に落とされる。
  // デフォルト null で従来挙動を維持。
  if (supportedTypes != null) {
    for (final t in supportedTypes) {
      if (qs.isNotEmpty) qs.write('&');
      qs.write('supported_types[]=${Uri.encodeQueryComponent(t)}');
    }
  }

  final uri = Uri.parse(
      '$instanceUrl/api/v2/notifications${qs.isEmpty ? '' : '?$qs'}');
  final resp = await httpClient.get(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode == 404) {
    throw NotificationsV2NotSupportedException();
  }
  if (resp.statusCode == 401 || resp.statusCode == 403) {
    throw NotificationsAuthException(resp.statusCode);
  }
  if (resp.statusCode != 200) {
    throw Exception('通知 (v2) 取得エラー: ${resp.statusCode}');
  }

  final decoded = jsonDecode(resp.body);
  final body = decoded is Map<String, dynamic>
      ? decoded
      : <String, dynamic>{'notification_groups': decoded as List<dynamic>};
  final accountsList = (body['accounts'] as List<dynamic>?) ?? const [];
  final statusesList = (body['statuses'] as List<dynamic>?) ?? const [];
  final groupsList =
      (body['notification_groups'] as List<dynamic>?) ?? const [];

  debugPrint(
      '[Notifs v2] response: ${groupsList.length} groups, '
      '${accountsList.length} accounts, ${statusesList.length} statuses '
      '(body keys: ${body.keys.toList()})');

  final accountsById = <String, Account>{
    for (final a in accountsList)
      (a as Map<String, dynamic>)['id'] as String: Account.fromJson(a),
  };
  final statusesById = <String, Status>{
    for (final s in statusesList)
      (s as Map<String, dynamic>)['id'] as String: Status.fromJson(s),
  };

  final result = <NotificationGroup>[];
  for (final g in groupsList) {
    try {
      result.add(NotificationGroup.fromV2Json(
        g as Map<String, dynamic>,
        accountsById,
        statusesById,
      ));
    } catch (e) {
      debugPrint('[Notifs v2] failed to parse group: $e');
    }
  }
  return result;
}

// ===========================================================================
// Collections (Mastodon 4.6+)
//
// 公開キュレーション・アカウントリスト。scope は read:collections /
// write:collections だが、ログイン時に要求している read / write の
// トップレベルスコープがこれらを包含するので追加の再認証は不要。
//
// 注: docs はアカウント別エンドポイントのパスを `/api/v1/:account_id/...` と
// `/api/v1/accounts/:account_id/...` で表記が揺れている。他の account
// サブリソース (statuses / lists / in_lists) が全て `accounts/:id/` 配下
// なのに倣い、ここでも accounts/ 配下を採用する (実機で 200 確認済み)。
//
// レスポンスはラッパーオブジェクト形式 (docs methods/collections):
//   - 一覧:  `{ "collections": [ {Collection}, ... ] }`
//   - 詳細:  `{ "collection": {Collection}, "accounts": [ {Account}, ... ] }`
// 単体の作成/更新は `{ "collection": {...} }` か bare {Collection} かが docs から
// 判然としないため、どちらでも読めるよう防御的にアンラップする。
// ===========================================================================

/// 一覧レスポンス (Map ラッパー or 素の配列) から Collection のリストを取り出す。
/// docs のタイポ (`collections:`) にも一応対応する。
List<Collection> _collectionsFromBody(String responseBody) {
  final decoded = jsonDecode(responseBody);
  if (decoded is List) {
    return Collection.listFromJson(decoded);
  }
  if (decoded is Map<String, dynamic>) {
    final list = decoded['collections'] ?? decoded['collections:'];
    if (list is List) return Collection.listFromJson(list);
  }
  return const [];
}

/// 単体レスポンス (Map ラッパー or bare Collection) から 1 件取り出す。
Collection _collectionFromBody(String responseBody) {
  final decoded = jsonDecode(responseBody);
  if (decoded is Map<String, dynamic>) {
    final inner = decoded['collection'];
    if (inner is Map<String, dynamic>) return Collection.fromJson(inner);
    return Collection.fromJson(decoded);
  }
  throw Exception('コレクション応答が不正です');
}

/// コレクションを作成 (`POST /api/v1/collections`)。
Future<Collection> createCollection({
  required String instanceUrl,
  required String accessToken,
  required String name,
  String? description,
  String? language,
  String? tagName,
  bool? sensitive,
  bool? discoverable,
  List<String>? accountIds,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/collections');
  final body = <String, dynamic>{
    'name': name,
    if (description != null) 'description': description,
    if (language != null) 'language': language,
    if (tagName != null) 'tag_name': tagName,
    if (sensitive != null) 'sensitive': sensitive,
    if (discoverable != null) 'discoverable': discoverable,
    if (accountIds != null) 'account_ids': accountIds,
  };
  final resp = await httpClient.post(
    uri,
    headers: {
      'Authorization': 'Bearer $accessToken',
      'Content-Type': 'application/json',
    },
    body: jsonEncode(body),
  );
  if (resp.statusCode != 200) {
    throw Exception('コレクション作成失敗: ${resp.statusCode} - ${resp.body}');
  }
  return _collectionFromBody(resp.body);
}

/// コレクション 1 件を取得 (`GET /api/v1/collections/:id`)。
/// レスポンスは `{ "collection": {...}, "accounts": [ {Account}, ... ] }` 形式で、
/// メンバーのアカウントが `accounts` に同梱される。Collection (items 含む) と
/// 解決済みメンバー Account のリストを併せて返す。公開取得可なので token は nullable。
Future<({Collection collection, List<Account> accounts})> fetchCollection({
  required String instanceUrl,
  required String? accessToken,
  required String collectionId,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/collections/$collectionId');
  final resp = await httpClient.get(
    uri,
    headers: {
      if (accessToken != null) 'Authorization': 'Bearer $accessToken',
    },
  );
  if (resp.statusCode != 200) {
    throw Exception('コレクション取得失敗: ${resp.statusCode}');
  }
  final decoded = jsonDecode(resp.body);
  if (decoded is Map<String, dynamic>) {
    final collJson = decoded['collection'];
    final accounts = ((decoded['accounts'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(Account.fromJson)
        .toList();
    if (collJson is Map<String, dynamic>) {
      return (collection: Collection.fromJson(collJson), accounts: accounts);
    }
    // bare Collection (ラッパー無し) のサーバにも一応対応。
    return (collection: Collection.fromJson(decoded), accounts: accounts);
  }
  throw Exception('コレクション応答が不正です');
}

/// コレクションのメタ情報を更新 (`PATCH /api/v1/collections/:id`)。全 opt。
Future<Collection> updateCollection({
  required String instanceUrl,
  required String accessToken,
  required String collectionId,
  String? name,
  String? description,
  String? language,
  String? tagName,
  bool? sensitive,
  bool? discoverable,
  List<String>? accountIds,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/collections/$collectionId');
  final body = <String, dynamic>{
    if (name != null) 'name': name,
    if (description != null) 'description': description,
    if (language != null) 'language': language,
    if (tagName != null) 'tag_name': tagName,
    if (sensitive != null) 'sensitive': sensitive,
    if (discoverable != null) 'discoverable': discoverable,
    if (accountIds != null) 'account_ids': accountIds,
  };
  final resp = await httpClient.patch(
    uri,
    headers: {
      'Authorization': 'Bearer $accessToken',
      'Content-Type': 'application/json',
    },
    body: jsonEncode(body),
  );
  if (resp.statusCode != 200) {
    throw Exception('コレクション更新失敗: ${resp.statusCode} - ${resp.body}');
  }
  return _collectionFromBody(resp.body);
}

/// コレクションを削除 (`DELETE /api/v1/collections/:id`)。
Future<void> deleteCollection({
  required String instanceUrl,
  required String accessToken,
  required String collectionId,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/collections/$collectionId');
  final resp = await httpClient.delete(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw Exception('コレクション削除失敗: ${resp.statusCode}');
  }
}

/// コレクションにアカウントを追加 (`POST /api/v1/collections/:id/items`)。
///
/// レスポンス本文の形 (素の item / collection ラッパー等) はサーバ差があり、
/// 呼び出し側も結果を使わない。本文をパースすると形違いで成功後に
/// FormatException を投げて「追加できたのにエラー表示」になるため、
/// **成否 (ステータスコード) だけ見る**。
Future<void> addCollectionItem({
  required String instanceUrl,
  required String accessToken,
  required String collectionId,
  required String accountId,
}) async {
  final uri =
      Uri.parse('$instanceUrl/api/v1/collections/$collectionId/items');
  final resp = await httpClient.post(
    uri,
    headers: {
      'Authorization': 'Bearer $accessToken',
      'Content-Type': 'application/json',
    },
    body: jsonEncode({'account_id': accountId}),
  );
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw Exception('コレクションへの追加失敗: ${resp.statusCode} - ${resp.body}');
  }
}

/// コレクションからメンバーを削除
/// (`DELETE /api/v1/collections/:id/items/:item_id`)。
Future<void> removeCollectionItem({
  required String instanceUrl,
  required String accessToken,
  required String collectionId,
  required String itemId,
}) async {
  final uri = Uri.parse(
      '$instanceUrl/api/v1/collections/$collectionId/items/$itemId');
  final resp = await httpClient.delete(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw Exception('コレクションからの削除失敗: ${resp.statusCode}');
  }
}

/// コレクションへの掲載を (掲載された本人が) 取り消す
/// (`POST /api/v1/collections/:id/items/:item_id/revoke`)。
Future<void> revokeCollectionItem({
  required String instanceUrl,
  required String accessToken,
  required String collectionId,
  required String itemId,
}) async {
  final uri = Uri.parse(
      '$instanceUrl/api/v1/collections/$collectionId/items/$itemId/revoke');
  final resp = await httpClient.post(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw Exception('コレクション掲載の取り消し失敗: ${resp.statusCode}');
  }
}

/// コレクションへの掲載を (掲載された本人が) 承認する。
///
/// **実機検証ゲート**: docs にエンドポイントの明記が無い。掲載拒否が
/// `.../items/:item_id/revoke` なので、対になる承認は
/// `POST /api/v1/collections/:id/items/:item_id/accept` と推定して実装する。
/// 実機で 404/405 が出たらパス (accept / approve 等) を調整すること。
Future<void> acceptCollectionItem({
  required String instanceUrl,
  required String accessToken,
  required String collectionId,
  required String itemId,
}) async {
  final uri = Uri.parse(
      '$instanceUrl/api/v1/collections/$collectionId/items/$itemId/accept');
  final resp = await httpClient.post(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw Exception('コレクション掲載の承認失敗: ${resp.statusCode}');
  }
}

/// あるアカウントが作成したコレクション一覧
/// (`GET /api/v1/accounts/:account_id/collections`)。公開取得可。
Future<List<Collection>> fetchAccountCollections({
  required String instanceUrl,
  required String? accessToken,
  required String accountId,
  int limit = 40,
  int offset = 0,
}) async {
  final uri = Uri.parse(
      '$instanceUrl/api/v1/accounts/$accountId/collections?limit=$limit&offset=$offset');
  final resp = await httpClient.get(
    uri,
    headers: {
      if (accessToken != null) 'Authorization': 'Bearer $accessToken',
    },
  );
  // 0 件 / 未対応サーバ / 旧パスは 404 になりうる。これは「コレクションが無い」
  // と同義に扱い、空状態として見せる (エラー画面にしない)。
  if (resp.statusCode == 404) return const [];
  if (resp.statusCode != 200) {
    throw Exception('アカウントのコレクション取得失敗: ${resp.statusCode}');
  }
  return _collectionsFromBody(resp.body);
}

/// あるアカウントが掲載されているコレクション一覧
/// (`GET /api/v1/accounts/:account_id/in_collections`)。要ユーザートークン。
Future<List<Collection>> fetchAccountInCollections({
  required String instanceUrl,
  required String accessToken,
  required String accountId,
  int limit = 40,
  int offset = 0,
}) async {
  final uri = Uri.parse(
      '$instanceUrl/api/v1/accounts/$accountId/in_collections?limit=$limit&offset=$offset');
  final resp = await httpClient.get(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  // 掲載 0 件 / 未対応サーバ / 旧パスは 404 になりうる → 空として扱う。
  if (resp.statusCode == 404) return const [];
  if (resp.statusCode != 200) {
    throw Exception('掲載コレクション取得失敗: ${resp.statusCode}');
  }
  return _collectionsFromBody(resp.body);
}

// ===========================================================================
// Annual Reports (Wrapstodon / 年間まとめ、Mastodon 4.6+)
//
// scope は read:accounts (GET) / write:accounts (POST) で、ログイン時の read /
// write トップレベルスコープに包含される。未対応サーバは 404 を返すので
// 一覧系は空配列で吸収する。
// ===========================================================================

/// 生成済みの年間まとめ一覧 (`GET /api/v1/annual_reports`)。
/// 未対応サーバ (404) は空配列で吸収する。
Future<List<AnnualReport>> fetchAnnualReports({
  required String instanceUrl,
  required String accessToken,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/annual_reports');
  final resp = await httpClient.get(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode == 404) return const [];
  if (resp.statusCode != 200) {
    throw Exception('年間まとめ一覧取得失敗: ${resp.statusCode}');
  }
  return AnnualReport.listFromResponse(jsonDecode(resp.body));
}

/// 指定年の年間まとめ (`GET /api/v1/annual_reports/:year`)。
/// 未生成 / 未対応 (404) は null。封筒形式のレスポンスから該当年を取り出す。
Future<AnnualReport?> fetchAnnualReport({
  required String instanceUrl,
  required String accessToken,
  required int year,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/annual_reports/$year');
  final resp = await httpClient.get(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode == 404) return null;
  if (resp.statusCode != 200) {
    throw Exception('年間まとめ取得失敗: ${resp.statusCode}');
  }
  final reports = AnnualReport.listFromResponse(jsonDecode(resp.body));
  if (reports.isEmpty) return null;
  // 該当年があればそれを、無ければ先頭を返す。
  return reports.firstWhere(
    (r) => r.year == year,
    orElse: () => reports.first,
  );
}

/// 指定年の年間まとめの状態 (`GET /api/v1/annual_reports/:year/state`)。
/// 戻り値は `available` / `generating` / `eligible` / `ineligible` のいずれか。
/// レスポンス構造が docs で薄いため、`state` キーを寛容に拾う。
/// 未対応 (404) は `ineligible` 扱い。
Future<String> fetchAnnualReportState({
  required String instanceUrl,
  required String accessToken,
  required int year,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/annual_reports/$year/state');
  final resp = await httpClient.get(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode == 404) return 'ineligible';
  if (resp.statusCode != 200) {
    throw Exception('年間まとめ状態取得失敗: ${resp.statusCode}');
  }
  final decoded = jsonDecode(resp.body);
  if (decoded is Map<String, dynamic>) {
    return (decoded['state'] as String?) ?? 'ineligible';
  }
  return 'ineligible';
}

/// 指定年の年間まとめ生成をトリガーする
/// (`POST /api/v1/annual_reports/:year/generate`)。
/// 生成は非同期 (サーバ側ジョブ + `Mastodon-Async-Refresh` ヘッダ) なので
/// 本文は当てにせず void。完了確認は [fetchAnnualReportState] をポーリングし、
/// `available` になったら [fetchAnnualReport] で取得する。
Future<void> generateAnnualReport({
  required String instanceUrl,
  required String accessToken,
  required int year,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/annual_reports/$year/generate');
  final resp = await httpClient.post(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw Exception('年間まとめ生成失敗: ${resp.statusCode}');
  }
}

/// 指定年の年間まとめを既読にする
/// (`POST /api/v1/annual_reports/:year/read`)。
Future<void> markAnnualReportRead({
  required String instanceUrl,
  required String accessToken,
  required int year,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/annual_reports/$year/read');
  final resp = await httpClient.post(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw Exception('年間まとめ既読化失敗: ${resp.statusCode}');
  }
}

/// ユーザー設定 (`GET /api/v1/preferences`) のうち Kurage が使う項目。
class UserPreferences {
  /// 投稿のデフォルト公開範囲 (public / unlisted / private / direct)。
  final String defaultVisibility;

  /// 投稿のデフォルト言語 (null = サーバ側未設定)。
  final String? defaultLanguage;

  /// 投稿のデフォルト sensitive フラグ。
  final bool defaultSensitive;

  const UserPreferences({
    this.defaultVisibility = 'public',
    this.defaultLanguage,
    this.defaultSensitive = false,
  });

  factory UserPreferences.fromJson(Map<String, dynamic> json) {
    return UserPreferences(
      defaultVisibility:
          (json['posting:default:visibility'] as String?) ?? 'public',
      defaultLanguage: json['posting:default:language'] as String?,
      defaultSensitive:
          (json['posting:default:sensitive'] as bool?) ?? false,
    );
  }
}

/// ユーザー設定の in-memory キャッシュ。preferences はアカウント (トークン)
/// 単位の設定なので、[_instanceConfigCache] と違いキーはアカウント単位。
/// 投稿画面を開くたびに毎回 HTTP を飛ばさないためのキャッシュで、
/// アプリ起動毎に再取得する。
final Map<String, UserPreferences> _userPreferencesCache = {};

String _preferencesCacheKey(String instanceUrl, String accessToken) =>
    '$instanceUrl|$accessToken';

/// キャッシュをクリアするテスト用フック。
@visibleForTesting
void clearUserPreferencesCache() => _userPreferencesCache.clear();

/// ユーザー設定を取得 (`GET /api/v1/preferences`、in-memory キャッシュ付き)。
Future<UserPreferences> fetchPreferences({
  required String instanceUrl,
  required String accessToken,
}) async {
  final cacheKey = _preferencesCacheKey(instanceUrl, accessToken);
  final cached = _userPreferencesCache[cacheKey];
  if (cached != null) return cached;

  final uri = Uri.parse('$instanceUrl/api/v1/preferences');
  final resp = await httpClient.get(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode != 200) {
    throw Exception('ユーザー設定取得失敗: ${resp.statusCode}');
  }
  final prefs = UserPreferences.fromJson(
    jsonDecode(resp.body) as Map<String, dynamic>,
  );
  _userPreferencesCache[cacheKey] = prefs;
  return prefs;
}

/// 投稿のデフォルト公開範囲 (サーバ側のグローバル設定) を変更する
/// (`PATCH /api/v1/accounts/update_credentials` の `source[privacy]`)。
/// 成功時は preferences キャッシュも更新するので、以降の
/// [fetchPreferences] は新しい値を返す。
Future<void> updateDefaultPostVisibility({
  required String instanceUrl,
  required String accessToken,
  required String visibility,
}) async {
  final uri = Uri.parse('$instanceUrl/api/v1/accounts/update_credentials');
  final resp = await httpClient.patch(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
    body: {'source[privacy]': visibility},
  );
  if (resp.statusCode != 200) {
    throw Exception('デフォルト公開範囲の変更失敗: ${resp.statusCode}');
  }

  final cacheKey = _preferencesCacheKey(instanceUrl, accessToken);
  final cached = _userPreferencesCache[cacheKey];
  _userPreferencesCache[cacheKey] = UserPreferences(
    defaultVisibility: visibility,
    defaultLanguage: cached?.defaultLanguage,
    defaultSensitive: cached?.defaultSensitive ?? false,
  );
}