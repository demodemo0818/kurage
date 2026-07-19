// lib/widgets/post_tile.dart

import 'dart:async';                         // TimeoutException のため
import 'dart:collection';                    // LinkedHashMap (static span LRU)
import 'dart:convert';                       // jsonDecode のため
import 'dart:ui';                            // ImageFilter.blur のため
import 'package:flutter/foundation.dart' show kIsWeb; // Web 判定のため
import 'package:flutter/material.dart';
// TapGestureRecognizer のため
import 'package:flutter/services.dart';     // Clipboard のため
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;     // 親投稿取得のため
import 'dart:io' show Platform;

import '../l10n/l10n.dart';
import '../models/status.dart';
import '../models/auth_account.dart';
import '../models/account.dart';
import '../models/emoji.dart';
import '../models/media_attachment.dart';
import '../models/quote.dart';
import '../pages/edit_history_page.dart';
import '../pages/reactors_page.dart';
import '../pages/report_page.dart';
import '../pages/full_screen_image_page.dart';
import '../pages/post_page.dart';
import '../utils/open_compose.dart';
import '../utils/open_profile.dart';
import '../pages/thread_page.dart';
import '../services/analytics_service.dart';
import '../services/mastodon_api.dart';
import '../services/local_status_event_bus.dart';
import '../utils/time_formatter.dart';
import '../utils/html_parser.dart'; // parseContentWithEmojis
import '../utils/instance_utils.dart';
import '../utils/snackbar_helpers.dart';
import '../utils/bounded_collections.dart';
import '../providers/settings_provider.dart';
import '../providers/auth_provider.dart';
import '../widgets/link_preview.dart';
import '../widgets/mute_dialog.dart';
import '../widgets/collapsible_text.dart'; // 追加
import '../widgets/poll_widget.dart';
import '../widgets/add_to_list_sheet.dart';
import '../widgets/user_avatar.dart';
import '../widgets/network_image_x.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart'; // Web の URL 共有 (navigator.share)

/// 投稿の visibility 文字列 → アイコンのマッピング。`build` のたびに Map
/// リテラルを new するのを避けるため top-level の const にしてある。
const Map<String, IconData> _kVisibilityIcons = {
  'public': Icons.public,
  'unlisted': Icons.lock_open,
  'private': Icons.lock,
  'direct': Icons.alternate_email,
};

/// テキストをアイソレートして制御文字の影響を局所化する関数
Widget isolateText({
  required Widget child,
  TextDirection? textDirection,
}) {
  return Directionality(
    textDirection: textDirection ?? TextDirection.ltr,
    child: Container(
      // アイソレーションのためのマーカー
      decoration: const BoxDecoration(),
      child: child,
    ),
  );
}

/// 投稿一覧で使うタイル表示用ウィジェット
class PostTile extends ConsumerStatefulWidget {
  final Status status;
  final String? accountId; // 複数アカウント対応用：どのアカウントでAPIを呼び出すか

  /// タイル本体のサイズが変わる操作 (アクションバー展開/縮小, CW 展開/縮小)
  /// を行う直前に親へ通知するフック。
  ///
  /// `scrollable_positioned_list` はアンカー (= 上から最初に画面内に入って
  /// いるアイテム) を保持して描画する都合上、アンカーより**上**にある
  /// アイテムが伸縮するとアンカー位置を維持したまま伸縮する = ユーザー
  /// 視点では「画面が下にずれる」ように見えてしまう。これを防ぐため、
  /// 親はこのコールバックでアンカーをタップ対象タイル自身に張り替える
  /// ことができ、伸縮が常に下方向に展開されるようになる。
  final VoidCallback? onBeforeSizeChange;

  /// 詳細ポップアップ ([_PostTileState._openDetailPopup]) 内で描画されているか。
  ///
  /// Web ではタイムラインの本文タップで詳細ポップアップを開く ([_openDetailPopup])
  /// が、その中に描画される PostTile 自身は「さらに詳細を開く」必要が無い
  /// (無限ネスト防止) ため `true` を渡す。`true` のときは:
  ///  - 本文タップで詳細ポップアップを開かない
  ///  - アクションバーを常に表示する (リッチな詳細として閲覧/操作できるように)
  /// ポップアップは Overlay 上 = ScrollablePositionedList の外なので、囲っている
  /// `SelectionArea` が干渉なく効き、本文テキストを選択・コピーできる。
  final bool isDetailView;

  /// この status がどのサーバーの API から取得されたか。
  ///
  /// null = 通常 (操作アカウントのホームサーバー由来)。
  /// non-null (例 `https://mstdn.example`) = プロフィールの「相手サーバー
  /// から読み込む」やスレッドの「投稿元サーバで開く」による**匿名リモート
  /// 取得**由来で、`status.id` (や account.id / poll.id) はそのサーバー上の
  /// ID。ホームサーバーの API にそのまま渡すと 404 になるため、リアクション
  /// 等の前に `resolveStatusOnInstanceCached` でホーム側 ID への解決が必要。
  /// `status.uri` の host からは導出できない (第三サーバー投稿のブースト等)
  /// ので、取得元を知っている呼び出し側が明示的に渡す。
  final String? statusSourceInstanceUrl;

  const PostTile({
    super.key,
    required this.status,
    this.accountId,
    this.onBeforeSizeChange,
    this.isDetailView = false,
    this.statusSourceInstanceUrl,
  });

  @override
  ConsumerState<PostTile> createState() => _PostTileState();
}

/// PostTile の static cache 群が無制限に膨らむのを防ぐ FIFO 上限。
///
/// 連合 TL で長時間スクロールするうちに「画面を一度通った status の id」が
/// 全部 static map に積もるのが問題だった。1500 件あれば「現在見ている領域
/// の周辺」をカバーするのに十分で、それを越えると古い順に evict される。
/// 影響は「めったに見ない古い投稿に戻ったとき、CW 展開状態などが初期値に
/// 戻る」程度。
const int _kMaxTileCache = 1500;

/// 投稿タイル全体の水平 padding。`headerSection` の `EdgeInsets.symmetric
/// (horizontal: 12)` と合わせる。本文配下の補助 widget (メディア / 投票) の
/// 右端揃えにも使う。
const double _kPostHorizPad = 12.0;

/// ヘッダー行で avatar と本文 Expanded の間に入っているスペーサー幅。
/// `headerSection` の `SizedBox(width: 12)` と合わせる。本文の左端 (= avatar
/// の右端 + spacer) を計算するのに使う。
const double _kAvatarBodySpacer = 12.0;

/// リモート由来 status をホームサーバー上の ID に解決できなかった時の
/// 共通メッセージ (`_boostAsAccount` 等の既存文言と揃える)。
String get _kStatusNotResolvedMsg => l10n.postNotFoundOnInstance;

class _PostTileState extends ConsumerState<PostTile> with AutomaticKeepAliveClientMixin {
  /// CW 展開状態。`ValueNotifier` 化することで、トグル時に PostTile 全体を
  /// rebuild せず、CW 表示領域を `ValueListenableBuilder` で囲んだ部分だけが
  /// 再描画される (avatar / boost / media gallery / action bar は無視できる)。
  final ValueNotifier<bool> _revealedVN = ValueNotifier<bool>(false);

  /// `_revealedVN.value` を statusId をキーにした static map にミラーする。
  /// `scrollable_positioned_list` の sliver 再構成 (新着 prepend / アンカー
  /// 張替えで起きる) で State が dispose → recreate されると、`_revealedVN`
  /// は新しい初期値で作り直されるため、ユーザーが展開した CW が SSE 受信の
  /// たびに勝手に折り畳まれたり、1 回目のタップが効かないように見えたり
  /// する。`_showActionsByStatusId` と同じ方式でユーザーの明示的トグルを
  /// 永続化する。`null` = 未トグル → 設定 (alwaysExpandCW) 由来の既定値
  /// を採用する。
  /// 1500 件で FIFO evict。連合 TL で大量スクロールすると tile 由来の
  /// status id が際限なく積もるため。1500 件あれば「直近に見た投稿の
  /// 展開状態を保持」という用途には十分。
  static final BoundedMap<String, bool> _revealedByStatusId =
      BoundedMap(_kMaxTileCache);

  /// `_showActions` は statusId をキーにした static map に保持する。
  /// `scrollable_positioned_list` がアンカー切替時に内部スリバーを再構成
  /// する都合で State が dispose → recreate されるケースがあり、ローカル
  /// フィールドだと「アクションバーを出した直後に State 再生成で値が
  /// false に戻り 1 フレームで閉じる」事象が起きるため。
  static final BoundedMap<String, bool> _showActionsByStatusId =
      BoundedMap(_kMaxTileCache);
  bool get _showActions => _showActionsByStatusId[widget.status.id] ?? false;

  /// 翻訳結果 (インスタンス翻訳) を status ID キーで保持する。
  /// ローカルフィールド (`_translationVN`) だけだと、SSE フラッシュや
  /// スクロール往復で `scrollable_positioned_list` が State を再生成した
  /// 瞬間に翻訳表示が消えてしまうため、`_showActionsByStatusId` と同じ
  /// 方式で永続化し initState で復元する。キーは翻訳対象 (= 表示中の
  /// 元投稿) の `_displayStatus.id`。
  static final BoundedMap<String, _TranslationData> _translationByStatusId =
      BoundedMap(_kMaxTileCache);

  /// インスタンスタイプのキャッシュ（パフォーマンス向上のため）。
  /// キーはインスタンス host。連合で多数のインスタンスに触れても
  /// 無制限に成長しないよう他のキャッシュと同じく FIFO evict にする。
  static final BoundedMap<String, bool> _instanceTypeCache =
      BoundedMap(_kMaxTileCache);

  /// 引用元 (Misskey/Fedibird 形式 `RE: URL` / `QT: URL`) の取得結果キャッシュ。
  /// キーは引用元の URL。`scrollable_positioned_list` が tile を再生成する
  /// たびに `_fetchQuotedStatus` が走るが、その都度 N アカウント順次 HTTP
  /// 試行 (最悪 6 RTT) を発生させていた。
  static final BoundedMap<String, Status> _quotedStatusCache =
      BoundedMap(_kMaxTileCache);

  /// 引用元 fetch が失敗した URL の negative cache。404 / 鍵投稿 / 認証
  /// 経路では取れない投稿などを覚えておき、同じ tile が再生成されるたびに
  /// 何度も同じ失敗を繰り返さないようにする。
  static final BoundedSet<String> _quotedStatusFailedIds =
      BoundedSet(_kMaxTileCache);

  /// 返信先 status ID → 返信先アカウントの displayName のキャッシュ。
  /// `scrollable_positioned_list` が tile を dispose / recreate するたびに
  /// ローカル State だとリセットされ、initState で再 fetch が走り
  /// 「返信先取得中…」が一瞬出てしまうため static で保持する。
  static final BoundedMap<String, String> _inReplyToDisplayNameCache =
      BoundedMap(_kMaxTileCache);

  /// 返信先 status ID のうち「取得を試みたが取得不可」だったもの。
  /// 404 (削除済み / 自インスタンスに連合していない / 閲覧権限なし) などは
  /// negative-cache しておかないと tile が再生成されるたびに何度も同じ
  /// fetch が走って毎回失敗し、UI が「返信先取得中…」のまま固まる。
  static final BoundedSet<String> _inReplyToFetchFailedIds =
      BoundedSet(_kMaxTileCache);

  /// フィルタ警告 (Filters v2 の `filter_action: warn`) を明示的に開示した
  /// status ID 集合。scrollable_positioned_list の State 再生成を跨いで
  /// 「一度開いたら開いたまま」にするため static で保持。
  static final BoundedSet<String> _filterRevealedStatusIds =
      BoundedSet(_kMaxTileCache);

  /// `_inReplyToDisplayNameVN` で「取得を試みた結果、取得不可だった」状態を
  /// 表すセンチネル。`null` は未取得 (= 取得中) と区別したい。
  /// displayName と衝突しないよう不可視文字を含める。
  static const String _kInReplyToFetchFailed = '\u0000__failed__';

  @override
  bool get wantKeepAlive => true;

  /// 返信先アカウントの displayName を保持（非同期取得）。
  /// 取得完了時に PostTile 全体を rebuild させたくないので `ValueNotifier`。
  final ValueNotifier<String?> _inReplyToDisplayNameVN =
      ValueNotifier<String?>(null);

  /// 引用元投稿（引用リノートの場合）。非同期取得完了で全体を rebuild
  /// させないため `ValueNotifier`。
  final ValueNotifier<Status?> _quotedStatusVN = ValueNotifier<Status?>(null);

  /// 翻訳結果。null = 未翻訳。`ValueNotifier` 化で翻訳トグル時に subtitle
  /// 領域だけが再描画される。
  final ValueNotifier<_TranslationData?> _translationVN =
      ValueNotifier<_TranslationData?>(null);

  /// 翻訳実行中フラグ (重複起動防止用)。UI には現状反映していないが
  /// 将来スピナ等を出す時のため `ValueNotifier`。
  final ValueNotifier<bool> _isTranslatingVN = ValueNotifier<bool>(false);

  /// 全 PostTile で共有するパース結果 LRU キャッシュ。
  ///
  /// `parseContentWithEmojis` は HTML パース + 複数の正規表現走査 + InlineSpan /
  /// TapGestureRecognizer / CachedNetworkImage 生成と高コストで、CLAUDE.md の
  /// 通り「秒間数百回の正規表現走査がスクロール詰まりの主因」になっていた。
  ///
  /// 旧実装は per-instance ([State] フィールド) だったため、`scrollable_
  /// positioned_list` が画面外でタイル State を破棄したタイミングでキャッシュも
  /// 消え、再表示で必ずフル再パースが走っていた (スクロール往復毎の重さ)。
  ///
  /// 静的化することで:
  /// - スクロール往復の再パースが消える (= 一度パースした投稿は LRU の中に
  ///   居る限り即返し)。
  /// - SSE フラッシュで同タイルが何度 rebuild されても 1 回目以降は即返し。
  ///
  /// キー = `${statusId}|${purposeKey}` で post 間 / 用途間の衝突を防ぐ。
  /// signature が変わったとき (フォントサイズや絵文字アニメ設定など、表示
  /// 結果に影響するパラメタの変化) は再パースして上書き。
  ///
  /// **recognizer の dispose はしない**: 共有キャッシュでは、ある tile が
  /// 表示中の spans を別 tile (再生成タイミングが異なる) が同時に保持しうる
  /// ため、即時 dispose は use-after-free のリスクを生む。参照を捨てるだけに
  /// 留め、widget tree から外れたら GC が回収する (recognizer は数百バイト、
  /// 上限 500 エントリ × 数十 recognizer/エントリでも数 MB に収まる)。
  ///
  /// LRU: hit 時にエントリを末尾へ移し (remove + put-back)、上限超過時は先頭
  /// (= 最も古いアクセス) を捨てる。
  static final LinkedHashMap<String, _ParsedSpansEntry> _spanCache =
      LinkedHashMap<String, _ParsedSpansEntry>();
  static const int _spanCacheMax = 500;

  @override
  void dispose() {
    _revealedVN.removeListener(_persistRevealed);
    _revealedVN.dispose();
    _inReplyToDisplayNameVN.dispose();
    _quotedStatusVN.dispose();
    _translationVN.dispose();
    _isTranslatingVN.dispose();
    super.dispose();
  }

  /// `_revealedVN` の変更を `_revealedByStatusId` に書き戻す。
  /// 「ユーザーがタップで明示的に展開/折り畳んだ」事象だけが該当する
  /// (初期値の代入時は addListener 前なので発火しない)。
  void _persistRevealed() {
    _revealedByStatusId[_cwStateKey] = _revealedVN.value;
  }

  /// CW 展開状態を引くキー。読み出し (initState) と書き込み
  /// (`_persistRevealed`) で必ず同じ id を使う。ブースト投稿の場合
  /// `widget.status.id` (ブースト自身の id) と元投稿の id が違うので、
  /// CW を持っているのは元投稿 (= `widget.status.reblog ?? widget.status`)
  /// の方なので、そちらの id を使う。両者で違うキーを使うと「読み out null
  /// → デフォルト false → タップして書き込み → 次に State 再生成された時
  /// にまた null read → 折り畳み」となり 1 回目のタップが効かない症状に
  /// なる。
  String get _cwStateKey {
    return _displayStatus.id;
  }

  /// ブースト (reblog) なら reblog 中の元投稿、そうでなければそのまま。
  /// 引用 / CW / 本文など「投稿の中身」に関するフィールドは常にこちらを
  /// 経由する。`widget.status` を直接読むと、ブースト wrapper には
  /// quote / content が無いため引用カードが消える等のバグになる。
  Status get _displayStatus => widget.status.reblog ?? widget.status;

  /// `parseContentWithEmojis` をメモ化付きで呼び出す。同じ入力 (= 同じ
  /// signature) なら前回の InlineSpan リストをそのまま返す。signature が
  /// 変われば旧 spans の recognizer を dispose してから再パース。
  List<InlineSpan> _cachedParseSpans({
    required String key,
    required String html,
    required List<Emoji> emojis,
    required TextStyle baseStyle,
    required Color linkColor,
    required double emojiSize,
    required bool disableEmojiAnimation,
    bool enableInlineLinks = true,
  }) {
    final sig = _spanSignature(
      html: html,
      style: baseStyle,
      linkColor: linkColor,
      emojiSize: emojiSize,
      disableEmojiAnimation: disableEmojiAnimation,
      enableInlineLinks: enableInlineLinks,
    );
    // post 間 / 用途間で衝突しないよう statusId と用途 key を結合。
    final cacheKey = '${_displayStatus.id}|$key';

    // hit 時は remove → 再 put で LRU の末尾に押し戻す。
    final existing = _spanCache.remove(cacheKey);
    if (existing != null && existing.signature == sig) {
      _spanCache[cacheKey] = existing;
      return existing.spans;
    }
    // signature 不一致なら旧 spans は捨てるだけ (dispose しない理由は
    // _spanCache の宣言コメント参照)。

    final spans = parseContentWithEmojis(
      contentHtml: html,
      emojis: emojis,
      baseStyle: baseStyle,
      linkColor: linkColor,
      emojiSize: emojiSize,
      context: context,
      disableEmojiAnimation: disableEmojiAnimation,
      enableInlineLinks: enableInlineLinks,
    );
    _spanCache[cacheKey] = _ParsedSpansEntry(sig, spans);

    // LRU eviction: 上限を超えた分だけ先頭 (= 最も古いアクセス) を捨てる。
    while (_spanCache.length > _spanCacheMax) {
      _spanCache.remove(_spanCache.keys.first);
    }
    return spans;
  }

  /// パース結果のキャッシュキー。spans の見た目に影響する全パラメタを含める。
  /// HTML は `hashCode` で要約 (同一 String インスタンスは O(1) でキャッシュ)。
  String _spanSignature({
    required String html,
    required TextStyle style,
    required Color linkColor,
    required double emojiSize,
    required bool disableEmojiAnimation,
    required bool enableInlineLinks,
  }) {
    return '${html.hashCode}|'
        '${style.fontSize}|${style.height}|${style.fontFamily}|'
        '${style.color?.toARGB32() ?? 0}|${style.fontWeight?.value ?? 0}|'
        '${linkColor.toARGB32()}|$emojiSize|$disableEmojiAnimation|'
        '$enableInlineLinks';
  }

  @override
  void initState() {
    super.initState();

    final d = widget.status.reblog ?? widget.status;
    // fav/reblog/bookmark の状態は _PostActionBar 初部内で管理する

    // CW 展開状態の初期化:
    //   1) ユーザーが過去に明示的にトグル済みなら static map の値を採用
    //      (= sliver 再構成や SSE 新着を跨いでも展開状態が消えない)
    //   2) 未トグルなら設定 `alwaysExpandCW` または spoiler 空判定で
    //      既定値を決める
    // 初期値の代入で `_persistRevealed` が走らないよう、addListener は
    // 初期値セット**後**に行う。
    final settings = ref.read(settingsProvider);
    final cachedReveal = _revealedByStatusId[_cwStateKey];
    _revealedVN.value =
        cachedReveal ?? (settings.alwaysExpandCW || d.spoilerText.isEmpty);
    _revealedVN.addListener(_persistRevealed);

    // 返信元が存在するなら、その投稿を取得して displayName をセットする。
    // 一度取得した displayName は static cache に残るので、tile が
    // 再生成されても再 fetch せず即座に表示できる。
    // 取得失敗 (404 等) は `_inReplyToFetchFailedIds` に積んでおき、再 fetch
    // をスキップする。これがないとスクロール往復のたびに「返信先取得中…」
    // が出続けて固まったように見える。
    if (d.inReplyToId != null) {
      final cached = _inReplyToDisplayNameCache[d.inReplyToId!];
      if (cached != null) {
        _inReplyToDisplayNameVN.value = cached;
      } else if (_inReplyToFetchFailedIds.contains(d.inReplyToId!)) {
        _inReplyToDisplayNameVN.value = _kInReplyToFetchFailed;
      } else {
        _fetchInReplyTo(d.inReplyToId!);
      }
    }

    // 公式引用 (Mastodon 4.4+) なら quoted_status が既に入っているのでそれを使う
    if (d.hasAcceptedQuote) {
      _quotedStatusVN.value = d.quote!.quotedStatus;
    } else if (d.isQuoteRenote) {
      // 旧来の Misskey/Fedibird 形式は別途 API で取得する必要がある
      _fetchQuotedStatus();
    }

    // 翻訳結果の復元。State 再生成 (SSE フラッシュ / スクロール往復) を
    // 跨いで翻訳表示を維持する。
    _translationVN.value = _translationByStatusId[d.id];
  }

  @override
  void didUpdateWidget(PostTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 別の status を表す widget に置き換わった場合は翻訳表示を引き直す
    // (旧投稿の翻訳が別の投稿に表示され続けるのを防ぐ)。
    final oldId = (oldWidget.status.reblog ?? oldWidget.status).id;
    if (oldId != _displayStatus.id) {
      _translationVN.value = _translationByStatusId[_displayStatus.id];
    }
  }

  /// 自分の投稿かどうかを判定
  bool _isOwnPost() {
    final auth = ref.read(authProvider);
    final display = widget.status.reblog ?? widget.status;
    final targetAccountId = widget.accountId;
    
    // 現在のアカウントを取得
    final currentAccount = targetAccountId != null 
        ? auth.accounts.firstWhere(
            (a) => a.id == targetAccountId,
            orElse: () => auth.accounts.first,
          )
        : auth.accounts.first;
    
    return display.account.id == currentAccount.id;
  }

  /// inReplyToId の投稿を取得して、返信先のアカウント displayName を setState する
  Future<void> _fetchInReplyTo(String inReplyToId) async {
    final auth = ref.read(authProvider);
    
    // この投稿のアカウントIDから適切なアカウントを取得
    final targetAccountId = widget.accountId;
    final acct = targetAccountId != null 
        ? auth.accounts.firstWhere(
            (a) => a.id == targetAccountId,
            orElse: () => auth.accounts.first,
          )
        : auth.accounts.first;
    
    final uri = Uri.parse('${acct.instanceUrl}/api/v1/statuses/$inReplyToId');
    try {
      final resp = await http.get(
        uri,
        headers: {'Authorization': 'Bearer ${acct.accessToken}'},
      ).timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) {
        final parentStatus =
            Status.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
        final displayName = parentStatus.account.displayName;
        _inReplyToDisplayNameCache[inReplyToId] = displayName;
        if (mounted) {
          // ValueNotifier 経由で書き込むので setState 不要 (この一行の差分で
          // PostTile 全体ではなく返信先表示の VLB だけが rebuild される)
          _inReplyToDisplayNameVN.value = displayName;
        }
      } else if (resp.statusCode >= 400 && resp.statusCode < 500) {
        // 4xx は恒久的に取得不可とみなして negative-cache する
        // (404: 削除済み / 連合未到達, 401/403: 閲覧権限なし)。
        // これがないと tile が再生成されるたびに同じ fetch が走り、
        // 毎回失敗して UI が「返信先取得中…」のまま固まる。
        debugPrint('inReplyTo fetch failed with status: ${resp.statusCode}');
        _inReplyToFetchFailedIds.add(inReplyToId);
        if (mounted) {
          _inReplyToDisplayNameVN.value = _kInReplyToFetchFailed;
        }
      } else {
        // 5xx は一時的な可能性があるので negative-cache はせず、UI だけ
        // 更新して「取得中…」から抜ける。次回 tile 生成時に再試行される。
        debugPrint('inReplyTo fetch failed with status: ${resp.statusCode}');
        if (mounted) {
          _inReplyToDisplayNameVN.value = _kInReplyToFetchFailed;
        }
      }
    } catch (e) {
      // ネットワークエラー / タイムアウト / JSON パース失敗等。一時的な
      // 可能性があるので negative-cache せず UI だけ更新する。
      debugPrint('inReplyTo fetch error: $e');
      if (mounted) {
        _inReplyToDisplayNameVN.value = _kInReplyToFetchFailed;
      }
    }
  }

  /// 引用元投稿を取得（Misskey/Fedibird 形式 `RE: URL` / `QT: URL` 用）
  ///
  /// 旧実装は tile の `initState` で発火し、`_isMisskeyInstance` (`/api/meta`
  /// で 1 RTT) + 全アカウント順次試行 (最悪アカウント数 × 1 RTT) を行ない、
  /// しかも negative cache が無いので scrollable_positioned_list の State
  /// 再生成で何度も同じ fetch を繰り返していた。
  ///
  /// 改善:
  /// - `_quotedStatusCache` (positive) / `_quotedStatusFailedIds` (negative)
  ///   を quotedUrl で引き、二度同じ HTTP を投げない。
  /// - 試行するアカウントは tile の owning account 1 つだけに絞る。
  ///   トレードオフ: 「アカウント B では見えるが A では見えない」鍵投稿の
  ///   引用は表示できなくなるが、その引き換えにスクロール詰まりと帯域
  ///   消費が大幅に減る。
  Future<void> _fetchQuotedStatus() async {
    final quotedUrl = _displayStatus.quotedUrl;
    if (quotedUrl == null) return;

    // Positive cache: 以前取得した結果を再利用
    final cached = _quotedStatusCache[quotedUrl];
    if (cached != null) {
      if (mounted) _quotedStatusVN.value = cached;
      return;
    }

    // Negative cache: 以前取得失敗していたら fetch を諦める
    if (_quotedStatusFailedIds.contains(quotedUrl)) return;

    // URLから投稿IDを抽出（Mastodon/Misskey URL形式を想定）
    // より具体的なパターンを先に配置
    final patterns = [
      RegExp(r'/notes/([a-zA-Z0-9]+)'),          // Misskeyパターン（優先）
      RegExp(r'/statuses/(\d+)'),                // Mastodonパターン（優先）
      RegExp(r'/@[^/]+/(\d+)'),                  // Mastodon/@username/id パターン（Fedibird含む）
      RegExp(r'/@[^/]+/([a-zA-Z0-9]+)'),         // 一般的な/@username/id パターン
      RegExp(r'/(?:notes|statuses)/([^/?#]+)'),  // 基本パターン（最後）
    ];

    String? statusId;
    for (final pattern in patterns) {
      final match = pattern.firstMatch(quotedUrl);
      if (match != null) {
        statusId = match.group(1)!;
        break;
      }
    }

    if (statusId == null) {
      _quotedStatusFailedIds.add(quotedUrl);
      return;
    }

    final uri = Uri.parse(quotedUrl);
    final instanceUrl = '${uri.scheme}://${uri.host}';

    final auth = ref.read(authProvider);
    if (auth.accounts.isEmpty) {
      _quotedStatusFailedIds.add(quotedUrl);
      return;
    }

    // tile の owning account を使う。指定なし or 見つからなければ accounts.first。
    final tileAccount = widget.accountId != null
        ? auth.accounts.firstWhere(
            (a) => a.id == widget.accountId,
            orElse: () => auth.accounts.first,
          )
        : auth.accounts.first;

    // インスタンスタイプ判定 (URL ベースを優先、最後だけ /api/meta)
    bool isMisskeyInstance;
    if (instanceUrl.contains('misskey')) {
      isMisskeyInstance = true;
    } else if (quotedUrl.contains('/notes/')) {
      isMisskeyInstance = true;
    } else if (quotedUrl.contains('/statuses/') || quotedUrl.contains('/@')) {
      isMisskeyInstance = false;
    } else {
      isMisskeyInstance = await _isMisskeyInstance(instanceUrl);
    }

    try {
      if (isMisskeyInstance) {
        await _tryFetchWithMisskeyAPI(instanceUrl, statusId, tileAccount);
      } else {
        await _tryFetchWithMastodonAPI(instanceUrl, statusId, tileAccount);
      }
    } catch (_) {
      // 例外も失敗扱い (下の判定で negative cache に入る)
    }

    final result = _quotedStatusVN.value;
    if (result != null) {
      _quotedStatusCache[quotedUrl] = result;
    } else {
      _quotedStatusFailedIds.add(quotedUrl);
    }
  }

  /// インスタンスがMisskeyかどうかを判定（キャッシュ付き）
  Future<bool> _isMisskeyInstance(String instanceUrl) async {
    // キャッシュから確認
    if (_instanceTypeCache.containsKey(instanceUrl)) {
      return _instanceTypeCache[instanceUrl]!;
    }
    
    try {
      // Misskeyの特徴的なエンドポイントで判定
      final metaUri = Uri.parse('$instanceUrl/api/meta');
      
      final resp = await http.post(
        metaUri,
        headers: {'Content-Type': 'application/json'},
        body: '{}',
      ).timeout(const Duration(seconds: 5));
      
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        // Misskeyのmetaにはversion情報があり、"misskey"という文字列が含まれる
        final version = data['version']?.toString().toLowerCase() ?? '';
        final isMisskey = version.contains('misskey');
        _instanceTypeCache[instanceUrl] = isMisskey;
        return isMisskey;
      }
    } catch (e) {
      // エラーの場合はMastodonとして扱う
    }
    
    // デフォルトはMastodon系として扱う
    _instanceTypeCache[instanceUrl] = false;
    return false;
  }

  /// Mastodon APIで投稿を取得
  Future<void> _tryFetchWithMastodonAPI(String instanceUrl, String statusId, dynamic account) async {
    try {
      final fetchUri = Uri.parse('$instanceUrl/api/v1/statuses/$statusId');
      
      final resp = await http.get(
        fetchUri,
        headers: {'Authorization': 'Bearer ${account.accessToken}'},
      );
      
      if (resp.statusCode == 200) {
        final quotedStatus = Status.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
        if (mounted) {
          _quotedStatusVN.value = quotedStatus;
        }
      } else {
        // 認証ありで失敗した場合、認証なしでも試してみる
        if (resp.statusCode == 401 || resp.statusCode == 403 || resp.statusCode == 404) {
          await _tryMastodonWithoutAuth(instanceUrl, statusId);
        }
      }
    } catch (e) {
      // エラーの場合は何もしない
    }
  }

  /// Misskey APIで投稿を取得
  Future<void> _tryFetchWithMisskeyAPI(String instanceUrl, String statusId, dynamic account) async {
    try {
      final fetchUri = Uri.parse('$instanceUrl/api/notes/show');
      // Misskeyでは認証トークンをリクエストボディに含める
      final requestBody = <String, dynamic>{
        'noteId': statusId,
      };
      
      // アクセストークンがある場合はボディに追加
      if (account.accessToken.isNotEmpty) {
        requestBody['i'] = account.accessToken;
      }
      
      final resp = await http.post(
        fetchUri,
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode(requestBody),
      );
      
      if (resp.statusCode == 200) {
        final responseData = jsonDecode(resp.body) as Map<String, dynamic>;
        // Misskeyのレスポンスをmastodon形式に変換
        final mastodonFormat = _convertMisskeyToMastodon(responseData);
        final quotedStatus = Status.fromJson(mastodonFormat);
        if (mounted) {
          _quotedStatusVN.value = quotedStatus;
        }
      } else {
        // 認証ありで失敗した場合、認証なしでも試してみる
        if (resp.statusCode == 401 || resp.statusCode == 403) {
          await _tryMisskeyWithoutAuth(instanceUrl, statusId);
        }
      }
    } catch (e) {
      // エラーの場合は何もしない
    }
  }

  /// 認証なしでMastodon APIを試行（公開投稿の場合）
  Future<void> _tryMastodonWithoutAuth(String instanceUrl, String statusId) async {
    try {
      final fetchUri = Uri.parse('$instanceUrl/api/v1/statuses/$statusId');
      
      final resp = await http.get(fetchUri);
      
      if (resp.statusCode == 200) {
        final quotedStatus = Status.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
        if (mounted) {
          _quotedStatusVN.value = quotedStatus;
        }
      }
    } catch (e) {
      // エラーが発生した場合は何もしない
    }
  }

  /// 認証なしでMisskey APIを試行（公開投稿の場合）
  Future<void> _tryMisskeyWithoutAuth(String instanceUrl, String statusId) async {
    try {
      final fetchUri = Uri.parse('$instanceUrl/api/notes/show');
      final resp = await http.post(
        fetchUri,
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'noteId': statusId,
        }),
      );
      
      if (resp.statusCode == 200) {
        final responseData = jsonDecode(resp.body) as Map<String, dynamic>;
        try {
          // Misskeyではrenote（リブログ）がある場合、その内容を使用する場合がある
          var actualNote = responseData;
          if (responseData['renote'] != null && 
              (responseData['text'] == null || responseData['text'].toString().isEmpty)) {
            actualNote = responseData['renote'] as Map<String, dynamic>;
          }
          
          final mastodonFormat = _convertMisskeyToMastodon(actualNote);
          final quotedStatus = Status.fromJson(mastodonFormat);
          if (mounted) {
            _quotedStatusVN.value = quotedStatus;
          }
        } catch (e) {
          // エラーが発生した場合は何もしない（引用元を表示せずにURL表示のままにする）
        }
      } else {
        // APIが失敗した場合は何もしない
      }
    } catch (e) {
      // エラーが発生した場合は何もしない
    }
  }

  /// MisskeyのレスポンスをMastodon形式に変換
  Map<String, dynamic> _convertMisskeyToMastodon(Map<String, dynamic> misskeyNote) {
    
    // ユーザー情報の安全な取得
    final user = misskeyNote['user'] as Map<String, dynamic>?;
    final userId = user?['id']?.toString() ?? 'unknown';
    final username = user?['username']?.toString() ?? 'unknown';
    final displayName = user?['name']?.toString() ?? username;
    final avatarUrl = user?['avatarUrl']?.toString() ?? '';
    
    // 日付の安全な処理
    final createdAt = misskeyNote['createdAt']?.toString() ?? DateTime.now().toIso8601String();
    
    // ファイル（メディア）の安全な処理
    //
    // Misskey の `properties.width` / `.height` を Mastodon の
    // `meta.original.width/height` に詰める。これを怠ると
    // `MediaAttachment.fromJson` が aspectRatio を 1.0 にフォールバック
    // してしまい、引用カード内のサムネ表示で `ResizeImage.exact` が
    // 正方形 decode して非正方形画像を歪める原因になる。
    final files = misskeyNote['files'] as List<dynamic>? ?? <dynamic>[];
    final mediaAttachments = files.map((file) {
      final fileMap = file as Map<String, dynamic>? ?? <String, dynamic>{};
      final props = fileMap['properties'] as Map<String, dynamic>?;
      final w = (props?['width'] as num?)?.toInt();
      final h = (props?['height'] as num?)?.toInt();
      return {
        'id': fileMap['id']?.toString() ?? '',
        'type': fileMap['type']?.toString().startsWith('image/') == true ? 'image' : 'unknown',
        'url': fileMap['url']?.toString() ?? '',
        'preview_url': fileMap['thumbnailUrl']?.toString() ?? fileMap['url']?.toString() ?? '',
        if (w != null && h != null && w > 0 && h > 0)
          'meta': {
            'original': {'width': w, 'height': h},
          },
      };
    }).toList();
    
    // 必須フィールドのバリデーション
    final noteId = misskeyNote['id']?.toString();
    if (noteId == null || noteId.isEmpty) {
      throw Exception('Missing required field: id');
    }
    
    // textがnullの場合、他のフィールドから内容を探す
    var noteContent = misskeyNote['text']?.toString() ?? '';
    
    // コンテンツが空の場合の処理
    
    if (noteContent.isEmpty) {
      // CW（Content Warning）がある場合
      if (misskeyNote['cw'] != null && misskeyNote['cw'].toString().isNotEmpty) {
        noteContent = '[CW: ${misskeyNote['cw']}]';
      }
      // ファイルがある場合
      else if (files.isNotEmpty) {
        noteContent = l10n.postNoteFiles(files.length);
      }
      // リノート（純粋なリブログ）の場合
      else if (misskeyNote['renoteId'] != null) {
        noteContent = l10n.postNoteRenote;
      }
      // 返信の場合
      else if (misskeyNote['replyId'] != null) {
        noteContent = l10n.postNoteReply;
      }
      // 公開範囲が限定的な場合（フォロワー限定など）
      else if (misskeyNote['visibility'] != null && misskeyNote['visibility'] != 'public') {
        final visibility = misskeyNote['visibility'].toString();
        switch (visibility) {
          case 'followers':
            noteContent = l10n.postNoteFollowersOnly;
            break;
          case 'specified':
            noteContent = l10n.postNoteDirect;
            break;
          case 'home':
            noteContent = l10n.postNoteHomeOnly;
            break;
          default:
            noteContent = l10n.postNoteLimited;
        }
      }
      // 本当に内容がない場合
      else {
        noteContent = l10n.postNoteEmpty;
      }
    }
    
    final result = {
      'id': noteId,
      'content': noteContent,
      'created_at': createdAt,
      'account': {
        'id': userId,
        'username': username,
        'display_name': displayName,
        'acct': username,
        'avatar': avatarUrl,
        'avatar_static': avatarUrl,
        'emojis': <dynamic>[],
        'fields': <dynamic>[],
        'followers_count': 0,
        'following_count': 0,
        'statuses_count': 0,
        'created_at': createdAt, // アカウント作成日時を投稿作成日時と同じにする
        'locked': false,
        'bot': user?['isBot'] as bool? ?? false,
        'note': '',
        'url': '',
        'header': '',
        'header_static': '',
      },
      'media_attachments': mediaAttachments,
      'emojis': <dynamic>[],
      'visibility': 'public',
      'favourited': false,
      'reblogged': false,
      'bookmarked': false,
      'sensitive': misskeyNote['cw'] != null,
      'spoiler_text': misskeyNote['cw']?.toString() ?? '',
      'in_reply_to_id': misskeyNote['replyId']?.toString(),
      'reblogs_count': misskeyNote['renoteCount'] as int? ?? 0,
      'favourites_count': 0,
      'url': misskeyNote['url']?.toString(),
      'uri': misskeyNote['uri']?.toString(),
    };
    
    return result;
  }

  /// 指定アカウントの API に渡せる display status の ID を返す。
  ///
  /// 通常はそのまま `display.id`。リモート由来
  /// ([PostTile.statusSourceInstanceUrl] non-null) なら、投稿 URL を
  /// `acct` のホームサーバーで解決したローカル ID を返す (結果はプロセス内
  /// キャッシュされる)。解決できなければ null (呼び元は
  /// [_kStatusNotResolvedMsg] を表示して中断する)。
  Future<String?> _resolveDisplayStatusIdFor(AuthAccount acct) async {
    final display = widget.status.reblog ?? widget.status;
    if (widget.statusSourceInstanceUrl == null) return display.id;
    final url = display.url ?? display.uri;
    if (url == null) return null;
    return resolveStatusOnInstanceCached(
      instanceUrl: acct.instanceUrl,
      accessToken: acct.accessToken,
      originalStatusUrl: url,
    );
  }

  /// 編集履歴ページに遷移する。
  ///
  /// `display.editedAt` が non-null の投稿でだけ呼ばれる。閲覧アカウントは
  /// 投稿主アカウントと別のこともある (連合 TL 等) ため、`auth` には現在
  /// 表示している tile の operating account を渡す。リモート由来の投稿では
  /// ホーム側 ID に解決してから遷移する。
  Future<void> _showEditHistory(AuthAccount auth, String statusId) async {
    if (widget.statusSourceInstanceUrl != null) {
      final resolved = await _resolveDisplayStatusIdFor(auth);
      if (resolved == null) {
        if (mounted) showErrorSnackBar(context, _kStatusNotResolvedMsg);
        return;
      }
      statusId = resolved;
    }
    if (!mounted) return;
    openDeckPage(
      context,
      (onDeckBack) => EditHistoryPage(
        statusId: statusId,
        account: auth,
        onDeckBack: onDeckBack,
      ),
    );
  }

  /// 引用元投稿をタップした際の処理
  void _handleQuotedPostTap(Status quotedStatus) {
    // 検索・ブラウザ表示に使う引用元 URL は、カードに表示している引用元 Status
    // 実体の url (無ければ uri) を最優先で使う。
    // _displayStatus.quotedUrl は (a) 公式引用 (Mastodon 4.4+) では常に null、
    // (b) Misskey/Fedibird 形式では本文を貪欲マッチして「最初の URL」を返すため、
    // 引用元と引用が同じインスタンスにある等で本文の URL 構造が変わると引用元
    // 以外の URL (プロフィールリンク等) を拾い「投稿が見つかりません」になる。
    // カードが既に保持している実体 url を使えばこの曖昧さを回避できる。
    final quotedUrl =
        quotedStatus.url ?? quotedStatus.uri ?? _displayStatus.quotedUrl;
    if (quotedUrl != null && quotedUrl.isNotEmpty) {
      // オプションダイアログを表示
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.l10n.postQuoteSourceTitle),
          content: Text(context.l10n.postQuoteSourceHow),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.cancel),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _openExternalUrl(quotedUrl);
              },
              child: Text(context.l10n.profOpenInBrowser),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _searchAndOpenPost(quotedUrl);
              },
              child: Text(context.l10n.postSearchFromCurrent),
            ),
            if (_canOpenInApp(quotedStatus))
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  _openInApp(quotedStatus);
                },
                child: Text(context.l10n.postShowOnThisInstance),
              )
            else if (_originStatusId(quotedUrl) != null)
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  _openOnOriginServer(quotedUrl);
                },
                child: Text(context.l10n.postOpenOnOriginServer),
              ),
          ],
        ),
      );
    } else {
      // URLがない場合は何もしない
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.postQuoteDetailUnavailable)),
      );
    }
  }

  /// URLを外部ブラウザで開く
  void _openExternalUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        throw Exception(l10n.postUrlOpenFailed);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.postBrowserOpenFailed('$e'))),
        );
      }
    }
  }

  /// 現在のアカウントから投稿を検索して開く
  Future<void> _searchAndOpenPost(String url) async {
    // ダイアログは root navigator に積まれるので、pop も同じ navigator で行う。
    // await 前に捕捉しておくことで、検索中に tile がスクロールで unmount
    // されてもローディングダイアログを確実に閉じられる。
    final rootNav = Navigator.of(context, rootNavigator: true);
    var dialogClosed = false;
    void closeLoadingDialog() {
      if (dialogClosed) return;
      dialogClosed = true;
      rootNav.pop();
    }

    // ローディングダイアログを表示
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => Center(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(context.l10n.postSearching),
              ],
            ),
          ),
        ),
      ),
    );

    // 現在のアカウントを取得
    final auth = ref.read(authProvider);
    final currentAccount = widget.accountId != null
        ? auth.accounts.firstWhere(
            (a) => a.id == widget.accountId,
            orElse: () => auth.accounts.first,
          )
        : auth.accounts.first;

    final Map<String, dynamic> searchResult;
    try {
      // URLから投稿を検索
      searchResult = await searchContent(
        instanceUrl: currentAccount.instanceUrl,
        accessToken: currentAccount.accessToken,
        query: url,
        type: 'statuses', // 投稿のみを検索
        resolve: true, // リモートインスタンスからも解決を試みる
        limit: 1,
      );
    } on TimeoutException {
      closeLoadingDialog();
      if (mounted) {
        showErrorSnackBar(context, l10n.postSearchTimeout);
      }
      return;
    } catch (e) {
      closeLoadingDialog();
      if (mounted) {
        showErrorSnackBar(context, l10n.searchError('$e'));
      }
      return;
    }

    // ローディングダイアログを閉じる
    closeLoadingDialog();

    // 検索結果から投稿を取得
    final statuses = searchResult['statuses'] as List<dynamic>? ?? [];
    if (statuses.isNotEmpty) {
      final foundStatus = statuses.first as Status;

      // ThreadPageで表示
      if (mounted) {
        openDeckPage(
          context,
          (onDeckBack) => ThreadPage(
            threadRootStatusId: foundStatus.id,
            sourceAccountId: widget.accountId,
            originalStatus: foundStatus,
            onDeckBack: onDeckBack,
          ),
        );
      }
    } else {
      // 投稿が見つからなかった場合
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(context.l10n.postNotFoundTitle),
            content: Text(context.l10n.postNotFoundBody),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  _openExternalUrl(url);
                },
                child: Text(context.l10n.profOpenInBrowser),
              ),
            ],
          ),
        );
      }
    }
  }

  /// アプリ内で表示可能かチェック
  bool _canOpenInApp(Status quotedStatus) {
    // この tile を表示しているアカウントと同じインスタンスの投稿かチェック
    final auth = ref.read(authProvider);
    final viewingAccount = widget.accountId != null
        ? auth.accounts.firstWhere(
            (a) => a.id == widget.accountId,
            orElse: () => auth.accounts.first,
          )
        : (auth.accounts.isNotEmpty ? auth.accounts.first : null);
    final viewingInstanceUrl = viewingAccount?.instanceUrl;
    final quotedUrl = _displayStatus.quotedUrl;

    if (viewingInstanceUrl != null && quotedUrl != null) {
      return quotedUrl.startsWith(viewingInstanceUrl);
    }
    return false;
  }

  /// アプリ内でThreadPageを開く
  void _openInApp(Status quotedStatus) {
    openDeckPage(
      context,
      (onDeckBack) => ThreadPage(
        threadRootStatusId: quotedStatus.id,
        sourceAccountId: widget.accountId,
        originalStatus: quotedStatus,
        onDeckBack: onDeckBack,
      ),
    );
  }

  /// Mastodon 形式の投稿 URL から末尾の数値 status ID を抽出する。
  /// `https://host/@user/12345` も `https://host/users/u/statuses/12345` も
  /// 末尾が数値なのでマッチする。Misskey の `/notes/xxxx` 等は null を返す。
  String? _originStatusId(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final m = RegExp(r'/(\d+)/?$').firstMatch(uri.path);
    return m?.group(1);
  }

  /// 引用元 URL のホスト（投稿元サーバ）に認証なしで直接アクセスし、
  /// ThreadPage でスレッドを表示する。現在のアカウントのインスタンスが
  /// その投稿を保持していなくても（連合していない等）閲覧できる。
  /// Mastodon 形式の URL のみ対応。それ以外はブラウザにフォールバックする。
  void _openOnOriginServer(String url) {
    final uri = Uri.tryParse(url);
    final statusId = _originStatusId(url);
    if (uri == null || statusId == null) {
      _openExternalUrl(url);
      return;
    }
    openDeckPage(
      context,
      (onDeckBack) => ThreadPage(
        threadRootStatusId: statusId,
        overrideInstanceUrl: '${uri.scheme}://${uri.host}',
        onDeckBack: onDeckBack,
      ),
    );
  }

  /// 確認ダイアログを表示。`onDontAskAgain` が指定されていれば「今後は表示しない」
  /// チェックボックスを出し、チェックされて OK されたタイミングでコールバックを呼ぶ。
  Future<bool> _confirmIfNeeded(
    bool need,
    String title,
    String msg, {
    VoidCallback? onDontAskAgain,
  }) async {
    if (!need) return true;
    bool dontAskAgain = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(msg),
              if (onDontAskAgain != null) ...[
                const SizedBox(height: 12),
                InkWell(
                  onTap: () =>
                      setDialog(() => dontAskAgain = !dontAskAgain),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Checkbox(
                          value: dontAskAgain,
                          onChanged: (v) =>
                              setDialog(() => dontAskAgain = v ?? false),
                        ),
                        Expanded(child: Text(ctx.l10n.postDontShowAgain)),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(ctx.l10n.cancel)),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true),  child: const Text('OK')),
          ],
        ),
      ),
    );
    // onDontAskAgain は ref.read を使うため、ダイアログ中にタイルが
    // unmount された場合は呼ばない (破棄後 ref アクセスで落ちるのを防ぐ)。
    if (ok == true && dontAskAgain && mounted) {
      onDontAskAgain?.call();
    }
    return ok == true;
  }

  /// Web: タイムラインの本文タップで開く詳細ポップアップ。
  ///
  /// タイムラインは `ScrollablePositionedList` × `SelectionArea` の非互換
  /// (flutter#111572) でスクロールが壊れるため本文選択を切ってある。その受け皿
  /// として、Overlay 上 (= SPL の外) のダイアログに同じ投稿を出し、`SelectionArea`
  /// で囲って本文テキストを選択・コピーできるようにする。中身は既存の `PostTile`
  /// を `isDetailView: true` で再利用し、メディア・アクション・引用・絵文字を
  /// そのまま見せる (リッチな詳細)。ダイアログ内は単純な `SingleChildScrollView`
  /// なので SPL 非互換は起きない。
  void _openDetailPopup() {
    final screen = MediaQuery.of(context).size;
    showDialog<void>(
      context: context,
      builder: (dialogCtx) {
        return Dialog(
          clipBehavior: Clip.antiAlias,
          insetPadding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 600,
              maxHeight: screen.height * 0.85,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ヘッダ (タイトル + 閉じる)。
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          context.l10n.postLabel,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: context.l10n.close,
                        onPressed: () => Navigator.of(dialogCtx).pop(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                // 本文。SelectionArea で囲ってドラッグ選択を有効化する。
                Flexible(
                  child: SelectionArea(
                    child: SingleChildScrollView(
                      child: PostTile(
                        status: widget.status,
                        accountId: widget.accountId,
                        isDetailView: true,
                        statusSourceInstanceUrl: widget.statusSourceInstanceUrl,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _toggleActions() {
    // 親 (タイムライン) にアンカー移動の機会を与えてから状態を変える
    widget.onBeforeSizeChange?.call();
    setState(() {
      _showActionsByStatusId[widget.status.id] = !_showActions;
    });
  }

  /// 指定アカウントのプロフィールページへ遷移する。アバタータップ
  /// (`_PostAvatar`) と同じ解決ロジックで、リモートユーザーは acct の
  /// `@instance` 部からインスタンス URL を補完する。表示名タップから使う。
  void _openProfile(Account target, AuthAccount viewingAccount) {
    String? userInstanceUrl;
    if (target.acct.contains('@')) {
      final parts = target.acct.split('@');
      if (parts.length >= 2) {
        userInstanceUrl = 'https://${parts.last}';
      }
    } else {
      userInstanceUrl = viewingAccount.instanceUrl;
    }
    openProfile(
      context,
      user: viewingAccount,
      targetAccountId: target.id,
      targetUsername: target.username,
      targetInstanceUrl: userInstanceUrl,
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin用
    final status   = widget.status;
    // 通常のリブログの場合はreblogを表示、引用リノートの場合は元のstatusを表示
    final display  = status.reblog != null && !status.isQuoteRenote ? status.reblog! : status;
    // build 内で実際に使うフィールドだけ record select する。
    // Settings 全 39 フィールドのうち 13 個 (appLock 系 / streamingEnabled /
    // themeColor / keepScreenOn / defaultPostLanguage / crashReportingEnabled /
    // timelineLayout / confirmAppExit 等) は PostTile では未使用なので、
    // それらの変更で画面内全タイルが rebuild するのを止める。record の
    // フィールド名は Settings と一致させているので呼び出し側 `settings.fontSize`
    // 等の記述はそのまま動く。
    final settings = ref.watch(settingsProvider.select((s) => (
      fontSize: s.fontSize,
      lineHeight: s.lineHeight,
      avatarSize: s.avatarSize,
      photoSize: s.photoSize,
      emojiScale: s.emojiScale,
      emojiScaleInDisplayName: s.emojiScaleInDisplayName,
      isAvatarSquare: s.isAvatarSquare,
      disableMediaBlur: s.disableMediaBlur,
      disableCustomEmojiAnimationInContent: s.disableCustomEmojiAnimationInContent,
      disableCustomEmojiAnimationInDisplayName:
          s.disableCustomEmojiAnimationInDisplayName,
      collapseAfterLines: s.collapseAfterLines,
      alwaysExpandCW: s.alwaysExpandCW,
      showUserId: s.showUserId,
      showPostActions: s.showPostActions,
      showReactionCounts: s.showReactionCounts,
      showVia: s.showVia,
      mediaLayout: s.mediaLayout,
      ogpLayout: s.ogpLayout,
      useRelativeTime: s.useRelativeTime,
      actionIconSize: s.actionIconSize,
      confirmReblog: s.confirmReblog,
      confirmUnreblog: s.confirmUnreblog,
      confirmFavourite: s.confirmFavourite,
      confirmUnfavourite: s.confirmUnfavourite,
      confirmBookmark: s.confirmBookmark,
      confirmUnbookmark: s.confirmUnbookmark,
    )));

    // サーバ側フィルタの `warn` アクションに該当する投稿は、ユーザーが明示的に
    // 開示するまで placeholder で出す。`hide` アクションは
    // timeline_view 側で _items から除外済みなのでここに来ない。
    // ブースト経由の場合は元投稿 (display) のフィルタを優先しつつ、
    // 念のため reblog ラッパー側 (status) もチェックする。
    final filterWarned = display.isFilterWarned || status.isFilterWarned;
    if (filterWarned &&
        !_filterRevealedStatusIds.contains(status.id)) {
      final title = display.filterDisplayTitle ?? status.filterDisplayTitle ?? '';
      return _buildFilteredPlaceholder(context, title, status.id);
    }

    // 性能最適化: Theme.of(context) は context を遡る lookup が走るため
    // build 冒頭で 1 回だけ取得しローカル変数で再利用する
    final theme = Theme.of(context);
    final isDarkMode = theme.brightness == Brightness.dark;
    final iconColor = theme.iconTheme.color;

    // 性能最適化: デコードサイズを画面サイズ相当 (logical px × DPR) に絞るため
    // CachedNetworkImage の `memCacheWidth` に渡す。これがないとサーバから
    // 来た 256〜1024px のアバターを丸ごとデコードして 48px に縮小描画する
    // ことになり、メモリと CPU が無駄になる。
    final dpr = MediaQuery.devicePixelRatioOf(context);
    
    // この投稿のアカウントIDから適切なアカウントを取得
    final auth = ref.read(authProvider);
    final targetAccountId = widget.accountId;
    final acct = targetAccountId != null 
        ? auth.accounts.firstWhere(
            (a) => a.id == targetAccountId,
            orElse: () => auth.accounts.first,
          )
        : auth.accounts.first;

    // 各種サイズ・色
    final fs      = settings.fontSize;
    final lh      = settings.lineHeight;
    final lc      = Colors.blue; // リンクやハッシュタグは青色固定
    final ms      = settings.photoSize;
    final avs     = settings.avatarSize;
    // 本文 (= avatar 右隣) の左端 X 座標。アバター下のメディアギャラリーや
    // 投票ウィジェットを本文と左揃えにするのに使う。`headerSection` の Row
    // 構造 (horizontal padding + avatar + spacer + Expanded) と一致させる。
    final bodyLeftPad = _kPostHorizPad + avs + _kAvatarBodySpacer;
    final showId  = settings.showUserId;
    // 詳細ポップアップ内ではアクションバーを常に表示する (リッチな詳細閲覧)。
    final showAct = settings.showPostActions || widget.isDetailView;
    final showReactionCounts = settings.showReactionCounts;

    // テキストスタイル
    final defaultStyle = DefaultTextStyle.of(context).style.copyWith(
      fontSize: fs,
      height: lh,
    );
    final headerStyle = defaultStyle.copyWith(
      fontSize: fs,
      fontWeight: FontWeight.bold,
    );

    // —— ヘッダー表示名＋@ID —— //
    final headerEmojiSize = fs * settings.emojiScaleInDisplayName;
    final nameSpans = _cachedParseSpans(
      key: 'displayName',
      html: display.account.displayName,
      emojis: display.account.emojis,
      baseStyle: headerStyle,
      linkColor: lc,
      emojiSize: headerEmojiSize,
      disableEmojiAnimation: settings.disableCustomEmojiAnimationInDisplayName,
      // 表示名は metadata なので `@user` / `#tag` / `https://...` を
      // 自動リンク化しない。Mastodon Web の挙動と揃える。
      enableInlineLinks: false,
    );
    // 表示名 (+ @ID) タップでプロフィールに遷移。ポインタのある環境では
    // クリック可能カーソル (手) にする。`HitTestBehavior.opaque` で行全体の
    // 余白もタップ範囲にする。
    //
    // 注: ここはリンク扱いなので `Text.rich` (選択可能) ではなく `RichText`
    // (非選択) を使う。`Text.rich` だと SelectionArea 下でテキストが
    // 選択可能になり I-beam カーソルが外側の MouseRegion(click) を上書きして
    // しまい、手カーソルにならない。Web のリンクは通常非選択 + 手カーソル
    // なのでこれで Mastodon Web と挙動が揃う。
    final headerName = MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _openProfile(display.account, acct),
        child: isolateText(
          textDirection: TextDirection.ltr,
          child: RichText(
            textDirection: TextDirection.ltr,
            text: TextSpan(
              children: [
                ...nameSpans,
                if (showId)
                  TextSpan(
                    text:
                        ' ${formatAcct(display.account.acct, acct.instanceUrl)}',
                    style: defaultStyle.copyWith(
                      fontSize: fs,
                      color: Colors.grey,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    // 時刻 (相対時刻は TimeText が Timer で自動更新するためここで文字列化しない)

    // —— 本文CW＋カスタム絵文字＋リンク＋ハッシュタグ —— //
    final contentEmojiSize = fs * settings.emojiScale;
    final contentSpans = _cachedParseSpans(
      key: 'content',
      html: display.content,
      emojis: display.emojis,
      baseStyle: defaultStyle,
      linkColor: lc,
      emojiSize: contentEmojiSize,
      disableEmojiAnimation: settings.disableCustomEmojiAnimationInContent,
    );

    // 本文テキストを CollapsibleText でラップ。stateKey で展開状態を
    // スクロール往復 / SSE prepend による State 破棄を跨いで保持する。
    final collapsibleContent = CollapsibleText(
      textSpans: contentSpans,
      defaultStyle: defaultStyle,
      maxLines: settings.collapseAfterLines,
      buttonColor: lc,
      textDirection: TextDirection.ltr,
      stateKey: 'content_${display.id}',
    );
    // 本文が空 (= 画像のみ投稿、CW のみ等) の場合はテキスト領域をそもそも
    // 出さない。`CollapsibleText` (= RichText) は子 span が空でも
    // `defaultStyle.height * fontSize` 分の行高さを確保してしまい、画像の
    // 上に余分な空行が出る。`<p></p>` 等の中身なし HTML も `parseContentWith
    // Emojis` 側で空 list に整理されるので、ここの判定だけで足りる。
    final hasContent = contentSpans.isNotEmpty;

    // subtitle: 投稿の主要部分 (CW / 引用 / 通常本文 + 翻訳)。
    //
    // 「変わりうる state」(`_revealedVN` / `_quotedStatusVN` / `_translationVN`)
    // ごとに `ValueListenableBuilder` で囲むことで、トグルや非同期取得完了で
    // PostTile 全体を rebuild させずに当該領域だけを再描画する。
    final Widget subtitle;
    // 引用カードは本文/メディアの「下」に出したいので、subtitle (= ヘッダー直下
    // の本文ブロック) には含めず、本体コンテンツ Column 側でメディアギャラリーの
    // 後ろに挿入する。画像付き引用で「画像 → 引用カード」の順になり自然に見える。
    // hasAnyQuote ブランチでのみ非 null になる。
    Widget? quoteCard;
    if (display.spoilerText.isNotEmpty) {
      // —— CW あり —— //
      final cwSpans = _cachedParseSpans(
        key: 'cw',
        html: display.spoilerText,
        emojis: display.emojis,
        baseStyle: defaultStyle,
        linkColor: lc,
        emojiSize: contentEmojiSize,
        disableEmojiAnimation: settings.disableCustomEmojiAnimationInContent,
      );
      subtitle = ValueListenableBuilder<bool>(
        valueListenable: _revealedVN,
        builder: (context, revealed, _) {
          // トグルボタンは CW 枠内 (右端) に置く。展開状態で alwaysExpandCW
          // が有効な場合のみ「畳む」を出さない (従来挙動)。
          // アクションバー展開と同様、サイズ変化前にアンカーを自タイルへ
          // 張り替えて「上方向に伸びる」のを防ぐ。親が `onBeforeSizeChange`
          // を渡していなければ no-op。
          final cwHeader = _CwBox(
            cwSpans: cwSpans,
            defaultStyle: defaultStyle,
            isDarkMode: isDarkMode,
            fontSize: fs,
            revealed: revealed,
            onToggle: (revealed && settings.alwaysExpandCW)
                ? null
                : () {
                    widget.onBeforeSizeChange?.call();
                    _revealedVN.value = !revealed;
                  },
          );
          if (!revealed) {
            // 折りたたみ状態
            return cwHeader;
          }
          // 展開状態：CW文を表示したまま本文も表示
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              cwHeader,
              if (hasContent) ...[
                const SizedBox(height: 8),
                collapsibleContent,
              ],
              if (display.card != null)
                LinkPreview(card: display.card!, layout: settings.ogpLayout),
            ],
          );
        },
      );
    } else if (display.hasAnyQuote) {
      // —— 引用あり (CW なし) —— //
      // 公式引用 (Mastodon 4.4+) と 旧来形式 (Misskey/Fedibird) の両対応

      // 1) 引用に添えるコメント部分を抽出
      //    - 公式引用 (Mastodon 4.4+): content の HTML 構造 (カスタム絵文字
      //      / メンション / ハッシュタグ等) を維持しつつ、サーバが backward-
      //      compat で埋め込んでいる RE: / QT: のリンクパターンのみ除去
      //    - 旧来形式 (Misskey / Fedibird): HTML を平文化してから RE:URL/
      //      QT:URL を除去
      final String quoteComment;
      if (display.hasOfficialQuote) {
        quoteComment = _stripQuoteMarkersFromHtml(display.content);
      } else {
        final plainText = display.content
            .replaceAll(RegExp(r'<[^>]*>'), '')
            .replaceAll('&lt;', '<')
            .replaceAll('&gt;', '>')
            .replaceAll('&amp;', '&')
            .replaceAll('&quot;', '"');

        final rePatterns = [
          RegExp(r'RE:\s*https?://[^\s<>]+\s*', caseSensitive: false),
          RegExp(r'QT:\s*https?://[^\s<>]+\s*', caseSensitive: false),
        ];
        var cleanedText = plainText;
        for (final pattern in rePatterns) {
          cleanedText = cleanedText.replaceAll(pattern, '');
        }
        cleanedText = cleanedText.trim();
        quoteComment = cleanedText.isNotEmpty ? '<p>$cleanedText</p>' : '';
      }

      // 2) 引用に添えるコメント部分のみを subtitle に置く。引用カード本体は
      //    quoteCard に分離し、メディアギャラリーの後ろに出す。
      subtitle = quoteComment.isNotEmpty
          ? CollapsibleText(
              textSpans: _cachedParseSpans(
                key: 'quoteComment',
                html: quoteComment,
                emojis: display.emojis,
                baseStyle: defaultStyle,
                linkColor: lc,
                emojiSize: contentEmojiSize,
                disableEmojiAnimation:
                    settings.disableCustomEmojiAnimationInContent,
              ),
              defaultStyle: defaultStyle,
              maxLines: settings.collapseAfterLines,
              buttonColor: lc,
              textDirection: TextDirection.ltr,
              stateKey: 'quote_${display.id}',
            )
          : const SizedBox.shrink();

      // 引用元表示は `_quotedStatusVN` の更新で再描画される。
      // 公式引用かつ accepted 以外なら state プレースホルダ固定なので
      // VLB の外で出して無駄な listener を張らない。
      quoteCard = (display.hasOfficialQuote && !display.hasAcceptedQuote)
          ? _buildQuoteStatePlaceholder(display.quote!.state, fs)
          : ValueListenableBuilder<Status?>(
              valueListenable: _quotedStatusVN,
              builder: (context, quoted, _) {
                if (quoted != null) {
                  return _buildQuotedPost(quoted, acct, fs);
                }
                // 読み込み中または取得失敗時は元のURL表示 (旧来形式のみ起こりうる)
                return Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.link, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          display.quotedUrl ?? context.l10n.postQuoteLoading,
                          style: TextStyle(
                            fontSize: fs * 0.9,
                            color: Colors.grey[600],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
    } else {
      // —— 通常投稿 (CW なし / 引用なし) —— //
      subtitle = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 翻訳結果の表示は `_translationVN` ticking でこの一帯だけ rebuild する
          ValueListenableBuilder<_TranslationData?>(
            valueListenable: _translationVN,
            builder: (context, translation, _) {
              if (translation == null) return const SizedBox.shrink();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildTranslationResult(
                    data: translation,
                    defaultStyle: defaultStyle,
                    contentEmojiSize: contentEmojiSize,
                    linkColor: lc,
                    disableEmojiAnimation:
                        settings.disableCustomEmojiAnimationInContent,
                    collapseAfterLines: settings.collapseAfterLines,
                  ),
                  const SizedBox(height: 8),
                  const Divider(height: 1),
                  const SizedBox(height: 8),
                ],
              );
            },
          ),
          if (hasContent) collapsibleContent,
          if (display.card != null)
                LinkPreview(card: display.card!, layout: settings.ogpLayout),
        ],
      );
    }

    // ── プレビュー用 URL リストとフル解像度用 URL リストを別々に作成 ──
    final previewUrls = display.mediaAttachments
        .map((m) => m.previewUrl.isNotEmpty ? m.previewUrl : m.url)
        .toList();

    final fullUrls = display.mediaAttachments
        .map((m) => m.url)
        .toList();
    // ───────────────────────────────────────────────────────────────────

    // アバター（タップでプロフィールへ）
    final avatar = _PostAvatar(
      status: widget.status,
      viewingAccount: acct,
      size: avs,
      isSquare: settings.isAvatarSquare,
      devicePixelRatio: dpr,
    );

    // ブースト情報（引用リノートの場合は表示しない）
    final Widget boostInfo;
    if (status.reblog != null && !status.isQuoteRenote) {
      // ブーストヘッダーの username 用 baseStyle。`defaultStyle` をそのまま
      // 使うと `height: lh` (= 設定の lineHeight、典型 1.4) が乗ってしまい、
      // username の文字が他要素 ("さんがブースト" / 時刻 = `height: 1.0` 相当)
      // より bounding box 内で下寄りに描画される。`Row` の center 揃えで
      // 「時刻が username より少し上に見える」原因。
      // boost ヘッダーは単一行なので line-height を上げる意味はなく、
      // 1.0 で揃えて視覚的なベースラインを一致させる。
      final boostAccountSpans = _cachedParseSpans(
        key: 'boostAccount',
        html: status.account.displayName,
        emojis: status.account.emojis,
        baseStyle: defaultStyle.copyWith(height: 1.0),
        linkColor: lc,
        emojiSize: headerEmojiSize,
        disableEmojiAnimation:
            settings.disableCustomEmojiAnimationInDisplayName,
        enableInlineLinks: false, // 表示名は metadata。`@`混在で誤リンク化しない。
      );
      boostInfo = _BoostInfoBar(
        boostAccount: status.account,
        boostAccountSpans: boostAccountSpans,
        viewingAccount: acct,
        createdAt: status.createdAt,
        fontSize: fs,
        avatarSize: avs,
        useRelativeTime: settings.useRelativeTime,
      );
    } else {
      boostInfo = const SizedBox.shrink();
    }

    // —— ヘッダー＋「（返信先の displayName）への返信」リンクの定義 —— //
    Widget headerSection = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: _kPostHorizPad,
        vertical: 6,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          avatar,
          const SizedBox(width: _kAvatarBodySpacer),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 名前＋時刻
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(child: headerName),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // 編集済みマーカー。タップで編集履歴ページに遷移する。
                        // GestureDetector の hit area を稼ぐため Padding 込み。
                        if (display.editedAt != null)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: GestureDetector(
                                onTap: () =>
                                    _showEditHistory(acct, display.id),
                                child: Tooltip(
                                  message: context.l10n.postEdited(
                                      formatRelative(display.editedAt!)),
                                  child: Icon(
                                    Icons.edit_note,
                                    size: fs * 1.1,
                                    color: Colors.grey,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        Icon(
                          _kVisibilityIcons[display.visibility] ?? Icons.public,
                          size: fs,
                          color: Colors.grey,
                        ),
                        const SizedBox(width: 4),
                        TimeText(
                          dt: display.createdAt,
                          useRelative: settings.useRelativeTime,
                          style: const TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                // 返信先の displayName をセット済みなら、それを表示する。
                // 非同期取得完了で PostTile 全体ではなくこの一行だけ rebuild
                // するため `ValueListenableBuilder` で囲む。
                if (display.inReplyToId != null) ...[
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                    onTap: () {
                      // リモート由来なら display.id は取得元サーバー上の ID
                      // なので、そのサーバーの匿名モードでスレッドを開く
                      // (ホームで解決するより速く、未連合の投稿も見られる)。
                      final source = widget.statusSourceInstanceUrl;
                      openDeckPage(
                        context,
                        (onDeckBack) => source != null
                            ? ThreadPage(
                                threadRootStatusId: display.id,
                                overrideInstanceUrl: source,
                                onDeckBack: onDeckBack,
                              )
                            : ThreadPage(
                                threadRootStatusId: display.id,
                                sourceAccountId: widget.accountId,
                                originalStatus: display,
                                onDeckBack: onDeckBack,
                              ),
                      );
                    },
                    // リンク扱いなので選択対象から外す。これをしないと
                    // SelectionArea 下でラベル Text が選択可能になり I-beam が
                    // MouseRegion(click) を上書きして手カーソルにならない
                    // (矢印 Icon は Text でないので手のまま出る)。
                    child: SelectionContainer.disabled(
                      child: Row(
                      children: [
                        Icon(Icons.reply, color: Colors.blue, size: fs),
                        const SizedBox(width: 4),
                        Expanded(
                          child: ValueListenableBuilder<String?>(
                            valueListenable: _inReplyToDisplayNameVN,
                            builder: (context, name, _) {
                              // 3 状態:
                              //  - null         : 取得中
                              //  - failed sentinel: 取得不可 (削除済み / 未連合 / 権限なし / 通信失敗)
                              //  - それ以外     : displayName 取得済み
                              final String label;
                              if (name == null) {
                                label = context.l10n.postReplyFetching;
                              } else if (name == _kInReplyToFetchFailed) {
                                label = context.l10n.postReplyLabel;
                              } else {
                                label = context.l10n.postReplyTo(name);
                              }
                              return Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.blue),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                    ),
                  ),
                  ),
                  const SizedBox(height: 2),
                ],
                subtitle,  // CW 部分（折りたたみ／展開できる）
              ],
            ),
          ),
        ],
      ),
    );

    // —— 本体コンテンツ —— //
    Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        boostInfo,
        headerSection,

        // メディアギャラリー (子ウィジェットに分離。ぼかし状態の setState で
        // PostTile 全体を rebuild させない)
        if (previewUrls.isNotEmpty)
          _PostMediaGallery(
            statusId: display.id,
            mediaAttachments: display.mediaAttachments,
            previewUrls: previewUrls,
            fullUrls: fullUrls,
            mediaSize: ms,
            fontSize: fs,
            sensitive:
                display.spoilerText.isNotEmpty || display.sensitive,
            disableBlur: settings.disableMediaBlur,
            layout: settings.mediaLayout,
            bodyLeftPadding: bodyLeftPad,
          ),

        // 引用カード。メディアギャラリーより後ろに置くことで「画像 → 引用カード」
        // の順になる。`_PostMediaGallery` / 投票と同じ左右 padding で本文左端に揃える。
        if (quoteCard != null) ...[
          const SizedBox(height: 8),
          Padding(
            padding: EdgeInsets.only(
              left: bodyLeftPad,
              right: _kPostHorizPad,
            ),
            child: quoteCard,
          ),
        ],

        // 投票ウィジェット。`_PostMediaGallery` と同じ左右 padding で本文
        // (アバター右隣) と左端を揃える。`bodyLeftPad` は avatarSize に追従。
        if (display.poll != null)
          Padding(
            padding: EdgeInsets.only(
              left: bodyLeftPad,
              right: _kPostHorizPad,
            ),
            child: PollWidget(
              poll: display.poll!,
              instanceUrl: acct.instanceUrl,
              accessToken: acct.accessToken,
              // リモート由来の poll.id はホームサーバーに渡せないため閲覧専用
              readOnly: widget.statusSourceInstanceUrl != null,
            ),
          ),

        // 投稿元アプリ (via) 表示。設定 ON & application 情報がある時のみ。
        // アクションバーと投稿本体の間に右寄せで小さく表示。
        //
        // `height: 1.0` でフォント本来の line-height (≈1.2) による上下の余分な
        // leading を排除する。これがないと小さいフォント (fs * 0.8) の上に
        // フォントサイズの 10〜20% 相当の余白が乗って「文字サイズのわりに
        // 上が空きすぎ」に見える。
        if (settings.showVia &&
            display.applicationName != null &&
            display.applicationName!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(right: 8, bottom: 2),
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                'via ${display.applicationName}',
                style: TextStyle(
                  fontSize: fs * 0.8,
                  color: Colors.grey,
                  height: 1.0,
                ),
              ),
            ),
          ),

        // アクションバー (子ウィジェットに分離。fav/RT/bookmark の setState で
        // PostTile 全体を rebuild させない)
        if (showAct || _showActions)
          _PostActionBar(
            status: widget.status,
            displayStatus: display,
            account: acct,
            accountId: widget.accountId,
            iconSize: settings.actionIconSize,
            showReactionCounts: showReactionCounts,
            confirmReblog: settings.confirmReblog,
            confirmUnreblog: settings.confirmUnreblog,
            confirmFavourite: settings.confirmFavourite,
            confirmUnfavourite: settings.confirmUnfavourite,
            confirmBookmark: settings.confirmBookmark,
            confirmUnbookmark: settings.confirmUnbookmark,
            iconColor: iconColor,
            isOwnPost: _isOwnPost(),
            domainBlockLabel: display.account.acct.contains('@')
                ? context.l10n
                    .profDomainBlockAction(display.account.acct.split('@').last)
                : null,
            onMenuAction: _handleMenuAction,
            statusSourceInstanceUrl: widget.statusSourceInstanceUrl,
          ),
      ],
    );

    // 本文タップの挙動。
    // - Web かつ詳細ポップアップ内でないとき: 本文タップで詳細ポップアップを
    //   開く ([_openDetailPopup])。アクションバー非表示時はそこからリアクション
    //   できるので、以前あった「ホバーでアクションバーを一時表示」は廃止
    //   (誤表示・レイアウト伸縮を避ける)。本文選択もポップアップ側で行う。
    // - それ以外 (モバイル / 詳細ポップアップ内): 従来通り、アクションバー非表示
    //   設定ならタップでトグル。
    final bool webDetailTap = kIsWeb && !widget.isDetailView;
    if (webDetailTap) {
      content = GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _openDetailPopup,
        child: content,
      );
    } else if (!showAct) {
      // モバイル / 詳細ポップアップ内: 非表示設定ならタップでアクションバー開閉。
      content = GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _toggleActions,
        child: content,
      );
    }

    // アカウントIDが指定されていれば、そのアカウントの色を取得
    Color? backgroundColor;
    if (widget.accountId != null) {
      final accounts = ref.read(authProvider).accounts;
      try {
        final account = accounts.firstWhere((a) => a.id == widget.accountId);
        backgroundColor = account.accountColor;
      } catch (e) {
        // アカウントが見つからない場合は無視
      }
    }
    
    final postContent = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        content,
      ],
    );
    
    // 背景色が設定されていれば、薄い色で背景を設定 (isDarkMode は build 冒頭で取得済)
    if (backgroundColor != null) {
      return Container(
        color: isDarkMode
            ? backgroundColor.withValues(alpha: 0.2)   // ダークモードではより明るく
            : backgroundColor.withValues(alpha: 0.1),   // ライトモードは従来通り
        child: postContent,
      );
    }
    
    return postContent;
  }

  Future<void> _handleMenuAction(String action) async {
    final auth = ref.read(authProvider);
    final targetAccountId = widget.accountId;
    final acct = targetAccountId != null 
        ? auth.accounts.firstWhere(
            (a) => a.id == targetAccountId,
            orElse: () => auth.accounts.first,
          )
        : auth.accounts.first;
    
    final display = widget.status.reblog ?? widget.status;
    
    switch (action) {
      case 'mute':
        await _muteAccount(acct, display.account);
        break;
      case 'block':
        await _blockAccount(acct, display.account);
        break;
      case 'domain_block':
        await _blockDomain(acct, display.account);
        break;
      case 'edit':
        await _editPost(acct, display);
        break;
      case 'delete':
        await _deletePost(acct, display);
        break;
      case 'delete_and_redraft':
        await _deleteAndRedraft(acct, display);
        break;
      case 'translate_instance':
        await _translateWithInstance(acct, display);
        break;
      case 'translate_google':
        await _openInGoogleTranslate(display);
        break;
      case 'copy_to_clipboard':
        await _copyToClipboardOnly(parseHtmlToPlainText(display.content));
        break;
      case 'copy_url':
        final url = display.url ?? display.uri;
        if (url == null || url.isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l10n.postUrlUnavailable)),
            );
          }
        } else {
          await _shareUrl(url);
        }
        break;
      case 'show_reblogged_by':
        // ブーストした人 / お気に入りした人の一覧画面 (TabBar 付き、reactors_page.dart)。
        // どちらのタブからでも切り替え可能だが、メニューから来た文脈に合わせて
        // 初期タブを変える。リモート由来ならホーム側 ID に解決してから遷移。
        final reblogStatusId = await _resolveDisplayStatusIdFor(acct);
        if (reblogStatusId == null) {
          if (mounted) showErrorSnackBar(context, _kStatusNotResolvedMsg);
          break;
        }
        if (!mounted) break;
        openDeckPage(
          context,
          (onDeckBack) => ReactorsPage.reblog(
            statusId: reblogStatusId,
            account: acct,
            onDeckBack: onDeckBack,
          ),
        );
        break;
      case 'show_favourited_by':
        final favStatusId = await _resolveDisplayStatusIdFor(acct);
        if (favStatusId == null) {
          if (mounted) showErrorSnackBar(context, _kStatusNotResolvedMsg);
          break;
        }
        if (!mounted) break;
        openDeckPage(
          context,
          (onDeckBack) => ReactorsPage.favourite(
            statusId: favStatusId,
            account: acct,
            onDeckBack: onDeckBack,
          ),
        );
        break;
      case 'report':
        // 通報。起点の投稿 (display) をプリセットしつつ ReportPage に遷移。
        // ブースト経由のときは display = reblog なので元投稿の id が使われる
        // (Mastodon は status_ids にローカル id を期待する)。
        openDeckPage(
          context,
          (onDeckBack) => ReportPage(
            authAccount: acct,
            targetAccount: display.account,
            sourceStatus: display,
            onDeckBack: onDeckBack,
          ),
        );
        break;
      case 'react_as_other_account':
        await _showReactAsOtherAccountDialog(display);
        break;
      // リモート由来 status の返信/引用。アクションバーから委譲される。
      // `_replyAsAccount` / `_quoteAsAccount` は URL ベースで対象アカウントの
      // サーバー上の ID に解決してから動くので、リモート ID をそのまま
      // compose に渡してしまう通常経路の代わりに使う。
      case 'reply_remote':
        await _replyAsAccount(acct, widget.status);
        break;
      case 'quote_remote':
        await _quoteAsAccount(acct, widget.status);
        break;
      case 'add_to_list':
        await showAddToListSheet(
          context: context,
          auth: acct,
          target: display.account,
        );
        break;
      case 'server_info':
        await _showServerInfoDialog(acct, display);
        break;
    }
  }

  Future<void> _muteAccount(AuthAccount auth, Account account) async {
    final choice = await showMuteDialog(context, acct: account.acct);
    if (choice == null) return;

    try {
      await muteAccount(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
        accountId: account.id,
        notifications: choice.hideNotifications,
        duration: choice.duration,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.profMuted)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.postMuteFailed('$e'))),
        );
      }
    }
  }

  Future<void> _blockAccount(AuthAccount auth, Account account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.profBlock),
        content: Text(ctx.l10n.profBlockConfirm(account.acct)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l10n.cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: Text(ctx.l10n.profBlock),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await blockAccount(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
        accountId: account.id,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.profBlocked)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.postBlockFailed('$e'))),
        );
      }
    }
  }

  Future<void> _blockDomain(AuthAccount auth, Account account) async {
    final domain = account.acct.split('@').last;
    
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.profDomainBlockTitle),
        content: Text(ctx.l10n.profDomainBlockConfirm(domain)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l10n.cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: Text(ctx.l10n.profBlock),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await blockDomain(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
        domain: domain,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.profDomainBlocked(domain))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.profDomainBlockFailed('$e'))),
        );
      }
    }
  }

  /// 引用された投稿を表示するウィジェット（Twitterライクな表示）
  /// 公式引用の content から、サーバが backward-compat で埋め込んでいる
  /// 引用元 URL のリンクを HTML 構造を保ったまま除去する。
  /// カスタム絵文字 (img) やメンション/ハッシュタグ (他の a タグ) は影響を受けない。
  String _stripQuoteMarkersFromHtml(String html) {
    var result = html;

    // 引用元の URL が判明しているならピンポイントで除去するのが最も確実
    final quote = _displayStatus.quote;
    final quotedUrl = quote?.quotedStatus?.url ?? quote?.quotedStatus?.uri;

    String escapeRegex(String s) =>
        s.replaceAllMapped(RegExp(r'[.*+?^${}()|[\]\\]'), (m) => '\\${m[0]}');

    if (quotedUrl != null && quotedUrl.isNotEmpty) {
      final esc = escapeRegex(quotedUrl);

      // (a) <a href="quotedUrl" ...>...</a> ごと除去 (中身に span 等を含んでも可)
      final aTag = RegExp(
        '<a[^>]*href="$esc"[^>]*>[\\s\\S]*?</a>',
        caseSensitive: false,
      );
      result = result.replaceAll(aTag, '');

      // (b) リンク化されていない素の URL も除去
      result = result.replaceAll(quotedUrl, '');
    }

    // 加えて RE: / QT: の prefix 文字 (URL は (a) で除去済みのことが多い) を掃除
    final marker = RegExp(
      r'(?:<br\s*/?>\s*)?(?:RE|QT):\s*',
      caseSensitive: false,
    );
    result = result.replaceAll(marker, '');

    // 万一 (a) で取り切れず素の "RE: https://..." が残っている場合の保険
    result = result.replaceAll(
      RegExp(r'\s*(?:RE|QT):\s*https?://[^\s<>]+', caseSensitive: false),
      '',
    );

    // 後始末: 空 <p></p>、末尾の <br>、孤立した連続スペース
    result = result
        .replaceAll(RegExp(r'<p>\s*</p>'), '')
        .replaceAll(RegExp(r'<br\s*/?>\s*</p>'), '</p>')
        .replaceAll(RegExp(r'<br\s*/?>\s*<br\s*/?>'), '<br />');

    return result.trim();
  }

  /// 公式引用 (Mastodon 4.4+) で state が accepted 以外の場合のプレースホルダ
  Widget _buildQuoteStatePlaceholder(QuoteState state, double fontSize) {
    final IconData icon = switch (state) {
      QuoteState.pending => Icons.hourglass_empty,
      QuoteState.deleted => Icons.delete_outline,
      QuoteState.unauthorized => Icons.lock_outline,
      _ => Icons.block,
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Colors.grey[600]),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              state.displayLabel,
              style: TextStyle(
                fontSize: fontSize * 0.9,
                color: Colors.grey[600],
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 引用元投稿カードを生成。表示は `_QuotedPostCard` に委譲し、ここでは
  /// `_cachedParseSpans` 経由で span をパースしてカードに渡すだけ。
  Widget _buildQuotedPost(Status quotedStatus, AuthAccount acct, double fontSize) {
    final settings = ref.watch(settingsProvider);
    final bodyColor =
        Theme.of(context).textTheme.bodyMedium?.color ?? Colors.black;

    final quotedAccountSpans = _cachedParseSpans(
      key: 'quotedAccount',
      html: quotedStatus.account.displayName,
      emojis: quotedStatus.account.emojis,
      baseStyle: TextStyle(
        fontSize: fontSize * 0.9,
        fontWeight: FontWeight.bold,
        color: bodyColor,
      ),
      linkColor: Colors.blue,
      emojiSize: fontSize * 0.9,
      disableEmojiAnimation: settings.disableCustomEmojiAnimationInDisplayName,
      enableInlineLinks: false, // 表示名は metadata。`@`混在で誤リンク化しない。
    );

    // 本文 spans は常にパースする。CW 付き投稿でも「表示」で
    // 展開したら本文を描画するため。
    final quotedContentSpans = _cachedParseSpans(
      key: 'quotedContent',
      html: quotedStatus.content,
      emojis: quotedStatus.emojis,
      baseStyle: TextStyle(
        fontSize: fontSize * 0.9,
        color: bodyColor,
      ),
      linkColor: Colors.blue,
      emojiSize: fontSize * 0.9,
      disableEmojiAnimation: settings.disableCustomEmojiAnimationInContent,
    );

    // CW 付きなら spoilerText を別 span として用意 (展開有無に関わらず
    // CW ラベル部分は常に出すので)。
    final hasCw = quotedStatus.spoilerText.isNotEmpty;
    final quotedCwSpans = hasCw
        ? _cachedParseSpans(
            key: 'quotedCw',
            html: quotedStatus.spoilerText,
            emojis: quotedStatus.emojis,
            baseStyle: TextStyle(
              fontSize: fontSize * 0.9,
              color: bodyColor,
            ),
            linkColor: Colors.blue,
            emojiSize: fontSize * 0.9,
            disableEmojiAnimation: settings.disableCustomEmojiAnimationInContent,
          )
        : null;

    return _QuotedPostCard(
      quotedStatus: quotedStatus,
      accountNameSpans: quotedAccountSpans,
      contentSpans: quotedContentSpans,
      cwSpans: quotedCwSpans,
      fontSize: fontSize,
      useRelativeTime: settings.useRelativeTime,
      onTap: () => _handleQuotedPostTap(quotedStatus),
      isCw: hasCw,
      // CW なしで sensitive のときだけメディアを隠す。
      // CW ありのときは card 側の reveal トグルで制御するため hideMedia は false。
      hideMedia: !hasCw && quotedStatus.sensitive,
    );
  }

  /// 投稿を編集 (Mastodon `PUT /api/v1/statuses/:id`)。
  ///
  /// `getStatusSource` で本文を取得 (HTML でない元のテキスト) してから
  /// PostPage を **編集モード** で開く。PostPage は保存成功時に
  /// `Navigator.pop(context, updatedStatus)` で更新後の Status を返してくる。
  /// 戻り値を `local_status_event_bus` に流すことで、タイムライン / プロ
  /// フィール / ハッシュタグ等の表示中リストを即座に最新版で差し替える。
  /// (since_id ベースの `_refresh` では既存 id の編集後本文を取り直せない
  /// ため、bus 経由でローカルキャッシュを直接更新する設計。)
  Future<void> _editPost(AuthAccount auth, Status status) async {
    try {
      // 編集用に投稿の元テキストを取得 (本文は HTML 化されていない source の
      // text、CW も source の方が正確)。
      final source = await getStatusSource(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
        statusId: status.id,
      );

      if (!mounted) return;

      // 編集コンポーズを開く。ワイド+ルートなら左の横ペイン、それ以外は
      // フルスクリーン (openCompose が振り分け)。編集結果の表示反映は PostPage
      // 側で publishLocalStatusEdited されるので、ここで戻り値は受け取らない。
      openCompose(
        context,
        ref,
        initialText: source['text'] as String? ?? '',
        initialVisibility: status.visibility,
        editStatusId: status.id,
        editTargetStatus: status,
        editAccountId: auth.id,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.composeEditFailed('$e'))),
        );
      }
    }
  }

  /// 投稿を削除
  Future<void> _deletePost(AuthAccount auth, Status status) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.postDeleteTitle),
        content: Text(ctx.l10n.postDeleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(ctx.l10n.delete),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await deleteStatus(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
        statusId: status.id,
      );

      // 各タイムラインのローカルキャッシュからこの status を取り除く
      // ように bus へ通知。
      publishLocalStatusDeleted(accountId: auth.id, statusId: status.id);

      if (mounted) {
        showCenteredToast(context, l10n.postDeleted);
      }
    } catch (e) {
      if (mounted) {
        showErrorSnackBar(context, l10n.postDeleteFailed('$e'));
      }
    }
  }

  /// 投稿を削除して下書きに戻す
  Future<void> _deleteAndRedraft(AuthAccount auth, Status status) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.postRedraftTitle),
        content: Text(ctx.l10n.postRedraftConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.orange),
            child: Text(ctx.l10n.postRedraftTitle),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      // まず投稿の元テキストを取得
      final source = await getStatusSource(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
        statusId: status.id,
      );
      
      // 投稿を削除
      await deleteStatus(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
        statusId: status.id,
      );

      // タイムライン側で当該 status を除去するよう bus へ通知。
      publishLocalStatusDeleted(accountId: auth.id, statusId: status.id);

      if (mounted) {
        showCenteredToast(context, l10n.postDeleted);

        // 投稿ページに遷移（下書きとして復元）。本文は source エンドポイントから
        // 取った plain text、その他のフィールドは Status 本体から復元する。
        // メディアは元投稿者アカウントに紐づけて新規投稿の添付として再利用
        // (Mastodon 仕様: 削除直後の attachment は unattached に戻り、同じ
        // アカウントから再利用可能)。
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => PostPage(
              initialText: source['text'] as String?,
              initialVisibility: status.visibility,
              initialSpoilerText: status.spoilerText,
              initialSensitive: status.sensitive,
              initialLanguage: status.language,
              initialPoll: status.poll,
              initialMediaAttachments: status.mediaAttachments,
              initialMediaAccountId: auth.id,
              // 元投稿者アカウントをデフォルト選択に
              initialAccountIds: [auth.id],
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.profActionFailed('$e'))),
        );
      }
    }
  }

  /// インスタンス機能で翻訳
  Future<void> _translateWithInstance(AuthAccount auth, Status status) async {
    if (_isTranslatingVN.value) return;

    _isTranslatingVN.value = true;

    try {
      // リモート由来なら status.id はホーム API に渡せないので先に解決する
      final statusId = await _resolveDisplayStatusIdFor(auth);
      if (statusId == null) {
        throw Exception(_kStatusNotResolvedMsg);
      }

      // インスタンスが翻訳機能をサポートしているかチェック
      final config = await fetchInstanceConfig(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
      );

      if (!config.translationEnabled) {
        throw Exception(l10n.postTranslateUnsupported);
      }

      final translation = await translateStatus(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
        statusId: statusId,
      );

      // 翻訳結果は ValueNotifier に流すので setState 不要 (subtitle 領域のみ rebuild)。
      // static map にも書いて State 再生成を跨いで表示を維持する。
      final data = _TranslationData(
        content: translation.content,
        spoilerText: translation.spoilerText,
        detectedLanguage: translation.detectedSourceLanguage,
        provider: translation.provider,
      );
      _translationByStatusId[status.id] = data;
      _translationVN.value = data;
      _isTranslatingVN.value = false;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.postTranslateDone(translation.provider)),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      _isTranslatingVN.value = false;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.postTranslateFailed('$e')),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// 投稿の本文を Google翻訳で開く。
  ///
  /// Android では `Intent.ACTION_PROCESS_TEXT` を Google翻訳パッケージに
  /// 直接送り、フローティングのポップアップで翻訳を表示する。
  /// 他プラットフォーム (iOS / デスクトップ / Web) では translate.google.com を
  /// 既定ブラウザで開く。
  Future<void> _openInGoogleTranslate(Status status) async {
    try {
      // HTMLタグを除去してプレーンテキストを取得
      String plainText = status.content;

      // HTMLタグを削除
      plainText = plainText.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), ' ');
      plainText = plainText.replaceAll(RegExp(r'<p\s*[^>]*>', caseSensitive: false), '');
      plainText = plainText.replaceAll(RegExp(r'</p>', caseSensitive: false), ' ');
      plainText = plainText.replaceAll(RegExp(r'<[^>]*>'), '');

      // HTMLエンティティをデコード
      plainText = plainText
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&amp;', '&')
          .replaceAll('&quot;', '"')
          .replaceAll('&#39;', "'")
          .replaceAll('&#x27;', "'")
          .replaceAll('&apos;', "'")
          .replaceAll('&#x2F;', '/')
          .replaceAll('&#47;', '/')
          .replaceAll('&nbsp;', ' ')
          .replaceAll('&#160;', ' ');

      // 複数のスペースや改行を整理
      plainText = plainText
          .replaceAll(RegExp(r'\s+'), ' ')  // 複数の空白を1つのスペースに
          .trim();

      if (plainText.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.postNoTextToTranslate)),
          );
        }
        return;
      }

      debugPrint('翻訳テキスト: "$plainText"');

      // Web では dart:io の Platform.isAndroid が UnsupportedError を throw する
      // ため、必ず kIsWeb で短絡してから Platform を参照する。
      if (!kIsWeb && Platform.isAndroid) {
        // Android はネイティブ翻訳アプリを直接起動 (失敗時は内部で
        // クリップボードにフォールバック)
        await _launchGoogleTranslateDirectly(plainText);
      } else {
        // iOS / デスクトップ / Web はブラウザで Google翻訳を開く
        await _launchTranslateInBrowser(plainText);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.postTranslateError('$e')),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Google翻訳を直接起動

  /// `Intent.ACTION_PROCESS_TEXT` を Google翻訳パッケージに直接送ることで
  /// テキスト選択メニューの「翻訳」と同じ経路を使う。Google翻訳側はこの
  /// インテントを受けるとフローティングのポップアップ Activity で起動する
  /// (タップ翻訳 / オーバーレイ権限の有効化は不要)。
  ///
  /// 失敗時 (Google翻訳未インストール等) はクリップボードにコピー +
  /// SnackBar 案内にフォールバック。
  Future<void> _launchGoogleTranslateDirectly(String text) async {
    // 呼び出し元 _openInGoogleTranslate が既に !kIsWeb && Platform.isAndroid で
    // ガードしているため Web では到達しないが、ファイル内の Platform.isAndroid
    // 参照は全て kIsWeb 短絡で統一しておく (将来の foot-gun 防止)。
    if (!kIsWeb && Platform.isAndroid) {
      try {
        const platform = MethodChannel('jp.demo2.kurage/share');
        final ok = await platform.invokeMethod<bool>('processText', {
          'text': text,
          'targetPackage': 'com.google.android.apps.translate',
        });
        if (ok == true) return;
      } catch (e) {
        debugPrint('processText failed, falling back to clipboard: $e');
      }
    }
    // フォールバック: クリップボードにコピー
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.postGoogleTranslateCopied),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  /// 投稿 URL をシステムの共有シートで共有する。
  ///
  /// Android はネイティブの `ACTION_SEND` チューザを起動するので、
  /// ユーザーは共有メニューから「コピー」「ブラウザで開く」「他アプリへ送る」
  /// 等を自由に選べる。Web は `share_plus` 経由で `navigator.share` を叩き、
  /// 対応ブラウザ (Windows Chrome/Edge・モバイル等) では OS の共有ダイアログ
  /// を出す。iOS / ネイティブデスクトップビルドと、Web でも `navigator.share`
  /// 非対応の環境 (Firefox / 非セキュアコンテキスト等) ではクリップボードへ
  /// フォールバックする。
  Future<void> _shareUrl(String url) async {
    // Web では dart:io の Platform.isAndroid が UnsupportedError を throw する
    // ため、必ず kIsWeb で短絡してから Platform を参照する。
    if (!kIsWeb && Platform.isAndroid) {
      try {
        const platform = MethodChannel('jp.demo2.kurage/share');
        await platform.invokeMethod('shareText', {
          'text': url,
          'title': l10n.postShareUrlTitle,
        });
        return;
      } catch (e) {
        debugPrint('URL 共有失敗、クリップボードへフォールバック: $e');
      }
    } else if (kIsWeb) {
      // Web は share_plus 経由で navigator.share({url}) を呼ぶ。text フィールド
      // だと Windows の共有ダイアログでリンクとして認識されず「リンクをコピー」
      // 等ができないため、ShareParams(uri:) で url フィールドに載せる
      // (share_plus_web は内部で ShareData(url: ...) を組む)。
      //
      // share_plus_web は「成功時も ShareResultStatus.unavailable を返す」(Web は
      // 共有先を判別できないため) 一方、navigator.share / canShare 非対応や失敗の
      // ときは例外を投げる。したがって status は見ず、「例外が出たときだけ」
      // クリップボードへフォールバックする。ユーザーがダイアログを閉じた
      // (dismissed) 場合も例外は出ないのでコピーしない。
      try {
        await SharePlus.instance.share(ShareParams(uri: Uri.parse(url)));
        return;
      } catch (e) {
        debugPrint('Web 共有不可、クリップボードへフォールバック: $e');
      }
    }
    // フォールバック: クリップボードにコピー (iOS / ネイティブデスクトップ /
    // Web の navigator.share 非対応ブラウザ)
    await _copyToClipboardOnly(url, label: l10n.postCopyLabelUrl);
  }

  /// クリップボードにコピーのみ
  Future<void> _copyToClipboardOnly(String text, {String? label}) async {
    await Clipboard.setData(ClipboardData(text: text));

    if (mounted) {
      // メッセンジャーを表示前に捕捉しておく。Deck モード (デスクトップ/Web) で
      // タブ切替により tile が unmount された後でも「確認」ボタンが動くようにする
      // (defunct な context で ScaffoldMessenger.of を呼ぶと throw して閉じられない)。
      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(
                child: Text(l10n.postCopiedToClipboard(
                    label ?? l10n.postCopyLabelText)),
              ),
            ],
          ),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 3),
          action: SnackBarAction(
            label: l10n.postCopyConfirmAction,
            textColor: Colors.white,
            onPressed: () {
              messenger.hideCurrentSnackBar();
            },
          ),
        ),
      );
    }
  }

  /// ブラウザで Google翻訳 を開く (iOS / デスクトップ / Web フォールバック用)。
  ///
  /// `translate.google.com` の URL クエリにテキストを載せて起動する。URL の
  /// 長さ制限と翻訳サービス側の負荷を考慮して 500 文字でカット。失敗した場合は
  /// クリップボードにコピーしてユーザーに案内する。
  Future<void> _launchTranslateInBrowser(String text) async {
    if (text.length > 500) {
      text = '${text.substring(0, 500)}...';
    }
    final url =
        'https://translate.google.com/?sl=auto&tl=ja&text=${Uri.encodeComponent(text)}';
    debugPrint('翻訳URL: $url');

    final uri = Uri.parse(url);
    try {
      if (kIsWeb) {
        // Web は canLaunchUrl の await による async ギャップでユーザー操作
        // コンテキストが切れ、ポップアップブロッカーに新規タブを弾かれる
        // ことがある。事前チェックを挟まず直接 _blank で開く (http(s) なら
        // launchUrl はほぼ成功する)。
        await launchUrl(uri, webOnlyWindowName: '_blank');
        return;
      }
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return;
      }
    } catch (e) {
      debugPrint('翻訳URLの起動に失敗: $e');
    }
    // フォールバック: クリップボードにコピー
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.postGoogleTranslateOpenFailedCopied),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  /// 翻訳結果の表示ウィジェット (与えられた `data` を描画。null や未翻訳ケースの
  /// 分岐は呼び出し側 `ValueListenableBuilder` で処理する)。
  ///
  /// 翻訳本文のパースは `_cachedParseSpans` を経由するため、tile スコープの
  /// recognizer 管理 / メモ化キャッシュにそのまま乗る。
  Widget _buildTranslationResult({
    required _TranslationData data,
    required TextStyle defaultStyle,
    required double contentEmojiSize,
    required Color linkColor,
    required bool disableEmojiAnimation,
    required int collapseAfterLines,
  }) {
    final translatedSpans = _cachedParseSpans(
      key: 'translatedContent',
      html: data.content,
      emojis: const [], // 翻訳結果にはカスタム絵文字が含まれていない場合が多い
      baseStyle: defaultStyle,
      linkColor: linkColor,
      emojiSize: contentEmojiSize,
      disableEmojiAnimation: disableEmojiAnimation,
    );

    return _TranslationResultBox(
      data: data,
      translatedSpans: translatedSpans,
      defaultStyle: defaultStyle,
      linkColor: linkColor,
      collapseAfterLines: collapseAfterLines,
      collapseStateKey: 'translation_${_displayStatus.id}',
      onClose: () {
        _translationByStatusId.remove(_displayStatus.id);
        _translationVN.value = null;
      },
    );
  }

  /// 別アカウントからリアクションダイアログを表示
  Future<void> _showReactAsOtherAccountDialog(Status status) async {
    final auth = ref.read(authProvider);
    
    // この tile を表示しているアカウント以外の選択可能なアカウントを取得
    final availableAccounts = auth.accounts.where((account) {
      final viewingAccountId = widget.accountId ??
          (auth.accounts.isNotEmpty ? auth.accounts.first.id : null);
      return account.id != viewingAccountId;
    }).toList();
    
    if (availableAccounts.isEmpty) {
      // 他にアカウントがない場合
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.l10n.postReactFromOtherTitle),
          content: Text(context.l10n.postNoOtherAccounts),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    
    // アカウント選択ダイアログを表示
    final selectedAccount = await showDialog<AuthAccount>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.postSelectReactionAccount),
        content: SizedBox(
          // 広い画面 (Deck) でダイアログが横に広がりすぎないよう最大幅を制限
          // (通知フィルター等と同じ方針)。狭い画面はフル幅。
          width: MediaQuery.of(context).size.width < 480
              ? double.maxFinite
              : 400.0,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: availableAccounts.length,
            itemBuilder: (context, index) {
              final account = availableAccounts[index];
              return ListTile(
                leading: KurageCircleAvatar(
                  imageUrl: account.avatarUrl,
                  backgroundColor: account.accountColor,
                ),
                title: Text(account.displayName.isNotEmpty 
                    ? account.displayName 
                    : account.username),
                subtitle: Text('@${account.username}@${Uri.parse(account.instanceUrl).host}'),
                onTap: () => Navigator.pop(context, account),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.cancel),
          ),
        ],
      ),
    );

    if (selectedAccount == null) return;
    
    // リアクション選択ダイアログを表示
    await _showReactionOptionsDialog(selectedAccount, status);
  }
  
  /// リアクション選択ダイアログを表示
  Future<void> _showReactionOptionsDialog(AuthAccount account, Status status) async {
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.postReactAs(account.displayName.isNotEmpty
            ? account.displayName
            : account.username)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.reply),
              title: Text(context.l10n.postReplyLabel),
              onTap: () {
                Navigator.pop(context);
                _replyAsAccount(account, status);
              },
            ),
            ListTile(
              leading: const Icon(Icons.repeat),
              title: Text(context.l10n.postBoostLabel),
              onTap: () {
                Navigator.pop(context);
                _boostAsAccount(account, status);
              },
            ),
            ListTile(
              leading: const Icon(Icons.format_quote),
              title: Text(context.l10n.postQuoteAction),
              onTap: () {
                Navigator.pop(context);
                _quoteAsAccount(account, status);
              },
            ),
            ListTile(
              leading: const Icon(Icons.star_border),
              title: Text(context.l10n.favourite),
              onTap: () {
                Navigator.pop(context);
                _favoriteAsAccount(account, status);
              },
            ),
            ListTile(
              leading: const Icon(Icons.bookmark_border),
              title: Text(context.l10n.postBookmarkLabel),
              onTap: () {
                Navigator.pop(context);
                _bookmarkAsAccount(account, status);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.cancel),
          ),
        ],
      ),
    );
  }
  
  /// 指定されたアカウントで返信
  Future<void> _replyAsAccount(AuthAccount account, Status status) async {
    final display = status.reblog ?? status;
    
    try {
      // ステータスのURLを取得
      final originalUrl = display.url ?? display.uri;
      if (originalUrl == null) {
        throw Exception(l10n.postUrlUnavailable);
      }

      // 対象インスタンスでステータスを解決
      final resolvedStatusId = await resolveStatusOnInstanceCached(
        instanceUrl: account.instanceUrl,
        accessToken: account.accessToken,
        originalStatusUrl: originalUrl,
      );

      if (!mounted) return;

      if (resolvedStatusId == null) {
        // 投稿が見つからない場合は、メンション付きの投稿で開く
        openCompose(
          context,
          ref,
          replyToUsername: display.account.acct,
          replyToVisibility: display.visibility,
          initialAccountIds: [account.id],
          initialText: '@${display.account.acct} ', // メンション付きで開始
        );

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.postCannotReplyMention)),
        );
        return;
      }

      openCompose(
        context,
        ref,
        replyToStatusId: resolvedStatusId,
        replyToUsername: display.account.acct,
        replyToVisibility: display.visibility,
        initialAccountIds: [account.id],
      );
    } catch (e) {
      if (!mounted) return;
      // エラーの場合はメンション付きの投稿で開く
      openCompose(
        context,
        ref,
        replyToUsername: display.account.acct,
        replyToVisibility: display.visibility,
        initialAccountIds: [account.id],
        initialText: '@${display.account.acct} ',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.postCannotReplyMention)),
        );
      }
    }
  }
  
  /// 指定されたアカウントでブースト
  Future<void> _boostAsAccount(AuthAccount account, Status status) async {
    final settings = ref.read(settingsProvider);
    
    if (!await _confirmIfNeeded(
      settings.confirmReblog,
      l10n.postBoostLabel,
      l10n.postBoostAsConfirm,
      onDontAskAgain: () =>
          ref.read(settingsProvider.notifier).setConfirmReblog(false),
    )) {
      return;
    }
    
    try {
      // ステータスのURLを取得 (ブースト経由ならラッパーでなく元投稿の URL)
      final display = status.reblog ?? status;
      final originalUrl = display.url ?? display.uri;
      if (originalUrl == null) {
        throw Exception(l10n.postUrlUnavailable);
      }
      
      // 対象インスタンスでステータスを解決
      final resolvedStatusId = await resolveStatusOnInstanceCached(
        instanceUrl: account.instanceUrl,
        accessToken: account.accessToken,
        originalStatusUrl: originalUrl,
      );
      
      if (resolvedStatusId == null) {
        throw Exception(l10n.postNotFoundOnInstance);
      }
      
      await toggleReblog(
        instanceUrl: account.instanceUrl,
        accessToken: account.accessToken,
        statusId: resolvedStatusId,
        currentlyReblogged: false,
      );
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(l10n.postBoostedAs(account.displayName.isNotEmpty
                  ? account.displayName
                  : account.username))),
        );
      }
    } catch (e) {
      String errorMessage;
      final errorString = e.toString();
      if (errorString.contains('404')) {
        errorMessage = l10n.postNotAccessibleOnInstance;
      } else if (errorString.contains('403')) {
        errorMessage = l10n.postNoPermission;
      } else if (errorString.contains(l10n.postNotFoundOnInstance)) {
        errorMessage = errorString;
      } else {
        errorMessage = l10n.postBoostFailed('$e');
      }
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errorMessage)),
        );
      }
    }
  }
  
  /// 指定されたアカウントで引用
  Future<void> _quoteAsAccount(AuthAccount account, Status status) async {
    final display = status.reblog ?? status;

    try {
      final originalUrl = display.url ?? display.uri;
      if (originalUrl == null) {
        throw Exception(l10n.postUrlUnavailable);
      }

      // 引用には対象インスタンス上の Status オブジェクトが必要
      // (PostPage の quotedStatusId はそのインスタンス上のローカル ID で投稿される)。
      // resolveStatusOnInstance は ID しか返さないので、searchContent を直接使って
      // Status オブジェクトを取得する。
      final searchResult = await searchContent(
        instanceUrl: account.instanceUrl,
        accessToken: account.accessToken,
        query: originalUrl,
        type: 'statuses',
        resolve: true,
        limit: 1,
      );

      final statuses = searchResult['statuses'] as List<dynamic>? ?? [];
      final resolvedStatus = statuses.isNotEmpty ? statuses.first as Status : null;

      if (!mounted) return;

      if (resolvedStatus == null) {
        throw Exception(l10n.postNotFoundOnInstance);
      }

      openCompose(
        context,
        ref,
        quotedStatus: resolvedStatus,
        initialVisibility: resolvedStatus.visibility,
        initialAccountIds: [account.id],
      );
    } catch (e) {
      String errorMessage;
      final errorString = e.toString();
      if (errorString.contains('404')) {
        errorMessage = l10n.postNotAccessibleOnInstance;
      } else if (errorString.contains('403')) {
        errorMessage = l10n.postNoPermission;
      } else if (errorString.contains(l10n.postNotFoundOnInstance)) {
        errorMessage = errorString;
      } else {
        errorMessage = l10n.postQuoteFailed('$e');
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errorMessage)),
        );
      }
    }
  }

  /// 指定されたアカウントでお気に入り
  Future<void> _favoriteAsAccount(AuthAccount account, Status status) async {
    final settings = ref.read(settingsProvider);
    
    if (!await _confirmIfNeeded(
      settings.confirmFavourite,
      l10n.favourite,
      l10n.postFavAsConfirm,
      onDontAskAgain: () =>
          ref.read(settingsProvider.notifier).setConfirmFavourite(false),
    )) {
      return;
    }
    
    try {
      // ステータスのURLを取得 (ブースト経由ならラッパーでなく元投稿の URL)
      final display = status.reblog ?? status;
      final originalUrl = display.url ?? display.uri;
      if (originalUrl == null) {
        throw Exception(l10n.postUrlUnavailable);
      }
      
      // 対象インスタンスでステータスを解決
      final resolvedStatusId = await resolveStatusOnInstanceCached(
        instanceUrl: account.instanceUrl,
        accessToken: account.accessToken,
        originalStatusUrl: originalUrl,
      );
      
      if (resolvedStatusId == null) {
        throw Exception(l10n.postNotFoundOnInstance);
      }
      
      await toggleFavourite(
        instanceUrl: account.instanceUrl,
        accessToken: account.accessToken,
        statusId: resolvedStatusId,
        currentlyFavourited: false,
      );
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(l10n.postFavedAs(account.displayName.isNotEmpty
                  ? account.displayName
                  : account.username))),
        );
      }
    } catch (e) {
      String errorMessage;
      final errorString = e.toString();
      if (errorString.contains('404')) {
        errorMessage = l10n.postNotAccessibleOnInstance;
      } else if (errorString.contains('403')) {
        errorMessage = l10n.postNoPermission;
      } else if (errorString.contains(l10n.postNotFoundOnInstance)) {
        errorMessage = errorString;
      } else {
        errorMessage = l10n.postFavFailed('$e');
      }
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errorMessage)),
        );
      }
    }
  }
  
  /// 指定されたアカウントでブックマーク
  Future<void> _bookmarkAsAccount(AuthAccount account, Status status) async {
    final settings = ref.read(settingsProvider);
    
    if (!await _confirmIfNeeded(
      settings.confirmBookmark,
      l10n.postBookmarkLabel,
      l10n.postBookmarkAsConfirm,
      onDontAskAgain: () =>
          ref.read(settingsProvider.notifier).setConfirmBookmark(false),
    )) {
      return;
    }
    
    try {
      // ステータスのURLを取得 (ブースト経由ならラッパーでなく元投稿の URL)
      final display = status.reblog ?? status;
      final originalUrl = display.url ?? display.uri;
      if (originalUrl == null) {
        throw Exception(l10n.postUrlUnavailable);
      }
      
      // 対象インスタンスでステータスを解決
      final resolvedStatusId = await resolveStatusOnInstanceCached(
        instanceUrl: account.instanceUrl,
        accessToken: account.accessToken,
        originalStatusUrl: originalUrl,
      );
      
      if (resolvedStatusId == null) {
        throw Exception(l10n.postNotFoundOnInstance);
      }
      
      await toggleBookmark(
        instanceUrl: account.instanceUrl,
        accessToken: account.accessToken,
        statusId: resolvedStatusId,
        currentlyBookmarked: false,
      );
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(l10n.postBookmarkedAs(
                  account.displayName.isNotEmpty
                      ? account.displayName
                      : account.username))),
        );
      }
    } catch (e) {
      String errorMessage;
      final errorString = e.toString();
      if (errorString.contains('404')) {
        errorMessage = l10n.postNotAccessibleOnInstance;
      } else if (errorString.contains('403')) {
        errorMessage = l10n.postNoPermission;
      } else if (errorString.contains(l10n.postNotFoundOnInstance)) {
        errorMessage = errorString;
      } else {
        errorMessage = l10n.postBookmarkFailed('$e');
      }
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errorMessage)),
        );
      }
    }
  }

  /// サーバー情報ダイアログを表示
  Future<void> _showServerInfoDialog(AuthAccount account, Status status) async {
    final display = status.reblog ?? status;
    
    // 投稿主のサーバーURLを取得。webfinger ドメイン (acct の @ 以降) と実
    // サーバーのホストが異なるインスタンスがある (例: @u@vivaldi.net でも
    // 実体は social.vivaldi.net) ため、acct ドメインでなく account.url
    // (正規プロフィール URL = origin) の host を優先する。
    String authorServerUrl;
    final accountUrl = display.account.url;
    final urlHost =
        accountUrl.isNotEmpty ? Uri.tryParse(accountUrl)?.host : null;
    if (urlHost != null && urlHost.isNotEmpty) {
      authorServerUrl = 'https://$urlHost';
    } else if (display.account.acct.contains('@')) {
      // url が無いリモート: acct ドメインにフォールバック。
      authorServerUrl = 'https://${display.account.acct.split('@').last}';
    } else if (display.url != null) {
      // ローカルユーザー: 投稿の URL から推測。
      final uri = Uri.parse(display.url!);
      authorServerUrl = '${uri.scheme}://${uri.host}';
    } else {
      // フォールバック: 現在のアカウントのサーバー。
      authorServerUrl = account.instanceUrl;
    }

    // ローディングダイアログ。Deck (ワイド) のポップアップ内ではこの tile が
    // nested Navigator 配下になり、`showDialog` (既定で root navigator) を
    // `Navigator.pop(context)` (= nearest = nested) で閉じようとするとズレて
    // 閉じない。ダイアログ自身の context を捕まえて確実に閉じる。
    BuildContext? loadingContext;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        loadingContext = ctx;
        return AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(ctx.l10n
                  .profFetchingServerInfo(Uri.parse(authorServerUrl).host)),
            ],
          ),
        );
      },
    );
    void closeLoading() {
      final lc = loadingContext;
      if (lc != null && lc.mounted) {
        Navigator.of(lc).pop();
      }
      loadingContext = null;
    }

    try {
      final serverInfo = await fetchServerInfo(
        instanceUrl: authorServerUrl,
        // 外部サーバーの場合は認証なしで取得
        accessToken: authorServerUrl == account.instanceUrl ? account.accessToken : null,
      );

      closeLoading();
      if (mounted) {
        // サーバー情報ダイアログを表示
        await showDialog(
          context: context,
          builder: (context) => _ServerInfoDialog(
            serverInfo: serverInfo,
            instanceUrl: authorServerUrl,
            authorAccount: display.account,
          ),
        );
      }
    } catch (e) {
      closeLoading();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.profServerInfoFailed('$e'))),
        );
      }
    }
  }

  /// サーバ側フィルタの `warn` プレースホルダ。タイトル + 開示ボタン。
  /// 「表示」を押すと `_filterRevealedStatusIds` に id を入れて setState し、
  /// 同じ tile を再 build → 通常の投稿描画にフォールバックする。
  Widget _buildFilteredPlaceholder(
    BuildContext context,
    String filterTitle,
    String statusId,
  ) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: Card(
        elevation: 0,
        color: isDark
            ? Colors.grey.shade800.withValues(alpha: 0.5)
            : Colors.grey.shade100,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: isDark ? Colors.grey.shade700 : Colors.grey.shade300,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(
                Icons.filter_alt_outlined,
                size: 18,
                color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  filterTitle.isEmpty
                      ? context.l10n.postFilterMatched
                      : context.l10n.postFilterLabel(filterTitle),
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark
                        ? Colors.grey.shade300
                        : Colors.grey.shade700,
                  ),
                ),
              ),
              TextButton(
                onPressed: () {
                  setState(() {
                    _filterRevealedStatusIds.add(statusId);
                  });
                },
                child: Text(context.l10n.postShowAction),
              ),
            ],
          ),
        ),
      ),
    );
  }

}

/// サーバー情報表示ダイアログ
class _ServerInfoDialog extends StatelessWidget {
  final Map<String, dynamic> serverInfo;
  final String instanceUrl;
  final Account? authorAccount;

  const _ServerInfoDialog({
    required this.serverInfo,
    required this.instanceUrl,
    this.authorAccount,
  });

  @override
  Widget build(BuildContext context) {
    if (serverInfo['error'] != null) {
      return AlertDialog(
        title: Text(context.l10n.profServerInfoTitle),
        content: Text(context.l10n.genericError('${serverInfo['error']}')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.close),
          ),
        ],
      );
    }

    final stats = serverInfo['stats'] as Map<String, dynamic>?;
    final config = serverInfo['configuration'] as Map<String, dynamic>?;
    final nodeInfo = serverInfo['nodeinfo'] as Map<String, dynamic>?;
    final software = nodeInfo?['software'] as Map<String, dynamic>?;

    final serverTitle = serverInfo['title'] ?? Uri.parse(instanceUrl).host;
    final dialogTitle = authorAccount != null
        ? context.l10n.profServerInfoDialogTitle(authorAccount!.username)
        : serverTitle;

    // 広い画面 (Deck) では double.maxFinite だとダイアログがウィンドウ幅
    // いっぱいに広がってしまうので最大幅を制限する (通知フィルターと同様)。
    // 狭い画面 (スマホ) では従来どおりフル幅にして情報行に余裕を持たせる。
    final dialogWidth =
        MediaQuery.of(context).size.width < 480 ? double.maxFinite : 400.0;

    return AlertDialog(
      title: Text(dialogTitle),
      content: SizedBox(
        width: dialogWidth,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 投稿主情報（該当する場合）
              if (authorAccount != null)
                _buildSection(context.l10n.postSectionAuthor, [
                  _buildInfoRow(context.l10n.profInfoUsername,
                      '@${authorAccount!.username}'),
                  _buildInfoRow(
                      context.l10n.displayNameLabel,
                      authorAccount!.displayName.isNotEmpty
                          ? authorAccount!.displayName
                          : null),
                  // 実際に情報を取得したサーバー (instanceUrl) の host を出す。
                  // acct ドメインだと WEB_DOMAIN ≠ LOCAL_DOMAIN 構成で取得元と
                  // ズレるため、取得元ホストを表示する。
                  _buildInfoRow(context.l10n.profInfoServer,
                      '@${Uri.parse(instanceUrl).host}'),
                ]),

              // 基本情報
              _buildSection(context.l10n.profSectionServerBasic, [
                _buildInfoRow(context.l10n.profInfoName, serverInfo['title']),
                _buildInfoRow('URL', serverInfo['uri'] ?? instanceUrl),
                _buildInfoRow(
                    context.l10n.profInfoVersion, serverInfo['version']),
                if (software != null)
                  _buildInfoRow(context.l10n.profInfoSoftware,
                      '${software['name']} ${software['version']}'),
              ]),

              // 説明
              if (serverInfo['short_description']?.toString().isNotEmpty == true)
                _buildSection(context.l10n.profSectionDescription, [
                  Text(
                    serverInfo['short_description'],
                    style: const TextStyle(fontSize: 14),
                  ),
                ]),

              // 統計情報
              if (stats != null)
                _buildSection(context.l10n.profSectionStats, [
                  _buildInfoRow(context.l10n.profInfoUserCount,
                      stats['user_count']?.toString()),
                  _buildInfoRow(context.l10n.profInfoStatusCount,
                      stats['status_count']?.toString()),
                  _buildInfoRow(context.l10n.profInfoDomainCount,
                      stats['domain_count']?.toString()),
                ]),

              // 登録情報
              _buildSection(context.l10n.profSectionRegistrations, [
                _buildInfoRow(
                    context.l10n.profInfoNewRegistrations,
                    serverInfo['registrations'] == true
                        ? context.l10n.profRegOpen
                        : context.l10n.profRegClosed),
                _buildInfoRow(
                    context.l10n.profInfoApprovalRequired,
                    serverInfo['approval_required'] == true
                        ? context.l10n.profYes
                        : context.l10n.profNo),
                _buildInfoRow(
                    context.l10n.profInfoInvitesEnabled,
                    serverInfo['invites_enabled'] == true
                        ? context.l10n.profYes
                        : context.l10n.profNo),
              ]),

              // 設定情報
              if (config != null) ...[
                if (config['statuses'] != null)
                  _buildSection(context.l10n.profSectionPostSettings, [
                    _buildInfoRow(context.l10n.profInfoMaxChars,
                        config['statuses']['max_characters']?.toString()),
                    _buildInfoRow(
                        context.l10n.profInfoMaxMedia,
                        config['statuses']['max_media_attachments']
                            ?.toString()),
                  ]),
                if (config['media_attachments'] != null)
                  _buildSection(context.l10n.profSectionMediaSettings, [
                    _buildInfoRow(
                        context.l10n.profInfoImageSizeLimit,
                        _formatBytes(
                            config['media_attachments']['image_size_limit'])),
                    _buildInfoRow(
                        context.l10n.profInfoVideoSizeLimit,
                        _formatBytes(
                            config['media_attachments']['video_size_limit'])),
                  ]),
              ],

              // 言語
              if (serverInfo['languages'] is List && (serverInfo['languages'] as List).isNotEmpty)
                _buildSection(context.l10n.profSectionLanguages, [
                  Text(
                    (serverInfo['languages'] as List).join(', '),
                    style: const TextStyle(fontSize: 14),
                  ),
                ]),

              // 連絡先
              if (serverInfo['contact_account'] != null)
                _buildSection(context.l10n.profSectionAdmin, [
                  _buildInfoRow(context.l10n.profInfoUsername,
                      '@${serverInfo['contact_account']['username']}'),
                  _buildInfoRow(context.l10n.displayNameLabel,
                      serverInfo['contact_account']['display_name']),
                ]),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.close),
        ),
      ],
    );
  }

  Widget _buildSection(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text(
          title,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        ...children,
      ],
    );
  }

  Widget _buildInfoRow(String label, String? value) {
    if (value == null || value.isEmpty) return const SizedBox.shrink();
    
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              '$label:',
              style: const TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: 14,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  String _formatBytes(dynamic bytes) {
    if (bytes == null) return '';
    final int value = int.tryParse(bytes.toString()) ?? 0;
    if (value == 0) return '';
    
    const suffixes = ['B', 'KB', 'MB', 'GB'];
    int i = 0;
    double size = value.toDouble();
    
    while (size >= 1024 && i < suffixes.length - 1) {
      size /= 1024;
      i++;
    }
    
    return '${size.toStringAsFixed(i == 0 ? 0 : 1)} ${suffixes[i]}';
  }
}

// ===========================================================================
// メディアギャラリー (PostTile から切り出した子ウィジェット)
// ===========================================================================
//
// _unblurredIndices をこのウィジェットの State 内に閉じ込めることで、
// 画像のタップ/長押しによるぼかし切替が PostTile 全体の rebuild を
// 引き起こさず、ギャラリーだけを再描画するようにする。
//
// RepaintBoundary でレイヤー境界を作り、近傍 (本文・アクションバー等)
// の repaint も切り離す。

/// gifv サムネイルに重ねる "GIF" 文字バッジ。再生中ではないことと
/// アニメーション付きであることを同時に伝える。
class _GifBadge extends StatelessWidget {
  const _GifBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        'GIF',
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 16,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

/// メディアタイル左下に重ねる「ALT」バッジ。タップでダイアログを開いて
/// description 全文を表示する。親 Stack の外側 GestureDetector より深い位置
/// なので、Flutter のヒットテストでこのバッジ側が先に勝ち、画像全体タップ
/// (フルスクリーン遷移) は発火しない。
class _AltBadge extends StatelessWidget {
  final String description;
  const _AltBadge({required this.description});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => showAltTextDialog(context, description),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(4),
          ),
          child: const Text(
            'ALT',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 12,
              letterSpacing: 1,
            ),
          ),
        ),
      ),
    );
  }
}

/// 表示中メディアタイルの右上に重ねる「手動で隠す」円形ボタン。タップでその投稿の
/// メディア全体を blur/hide する (公式 Web UI の hide ボタン相当)。_AltBadge 同様、
/// `HitTestBehavior.opaque` で外側タイルの onTap (フルスクリーン遷移) を奪い、
/// 画像全体タップに混ざらないようにする。
class _HideMediaButton extends StatelessWidget {
  final double size;
  final VoidCallback onTap;
  const _HideMediaButton({required this.size, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Tooltip(
          message: context.l10n.postHideMedia,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.visibility_off,
              color: Colors.white,
              size: size * 0.62,
            ),
          ),
        ),
      ),
    );
  }
}

/// 添付メディアの ALT 文 (description) を全文表示するダイアログ。
/// タイムラインの ALT バッジ / フルスクリーンビューア両方から呼ばれる。
void showAltTextDialog(BuildContext context, String description) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(ctx.l10n.composeAltLabel),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.6,
        ),
        child: SingleChildScrollView(
          child: SelectableText(description),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(ctx.l10n.close),
        ),
      ],
    ),
  );
}

class _PostMediaGallery extends StatefulWidget {
  /// 投稿 ID。`_unblurredIndices` を State 再生成を跨いで永続化するキー。
  final String statusId;
  final List<MediaAttachment> mediaAttachments;
  final List<String> previewUrls;
  final List<String> fullUrls;
  final double mediaSize;
  final double fontSize;

  /// 投稿が sensitive 扱い (sensitive フラグ または CW テキストあり) か
  final bool sensitive;

  /// グローバル設定でぼかしを無効化しているか
  final bool disableBlur;

  /// 表示スタイル (horizontal: 従来の横スクロール / grid: X 風グリッド)
  final MediaLayout layout;

  /// ヘッダーの本文 (アバター右隣) と左端を揃えるための左 padding。
  /// 呼び出し元 (`_PostTile`) が `_kPostHorizPad + avatarSize + _kAvatarSpacer`
  /// で計算した値を渡す。avatarSize 設定変更に追従できるよう動的に持つ。
  final double bodyLeftPadding;

  const _PostMediaGallery({
    required this.statusId,
    required this.mediaAttachments,
    required this.previewUrls,
    required this.fullUrls,
    required this.mediaSize,
    required this.fontSize,
    required this.sensitive,
    required this.disableBlur,
    required this.layout,
    required this.bodyLeftPadding,
  });

  @override
  State<_PostMediaGallery> createState() => _PostMediaGalleryState();
}

class _PostMediaGalleryState extends State<_PostMediaGallery> {
  /// `scrollable_positioned_list` のアンカー切替やストリーミング更新で State が
  /// dispose -> recreate されるケースがあり、ローカル Set だと「ぼかしを外した
  /// のに新着取得時にまた blur に戻る」事象が起きる。statusId をキーにした
  /// static Map で永続化することで State 再生成を跨いで値を保つ。
  static final BoundedMap<String, Set<int>> _unblurredByStatusId =
      BoundedMap(_kMaxTileCache);

  Set<int> get _unblurredIndices =>
      _unblurredByStatusId.putIfAbsent(widget.statusId, () => <int>{});

  /// 投稿単位の「手動で隠す」状態 (sensitive とは独立。公式 Web UI の hide ボタン
  /// 相当)。_unblurredByStatusId と同じく statusId キーの static Map に保持し、
  /// State 再生成 (scrollable_positioned_list のオフスクリーン破棄) を跨いで保つ。
  /// セッション限り (SharedPreferences には保存しない)。
  static final BoundedMap<String, bool> _manuallyHiddenByStatusId =
      BoundedMap(_kMaxTileCache);

  bool get _manuallyHidden => _manuallyHiddenByStatusId[widget.statusId] ?? false;
  set _manuallyHidden(bool v) {
    if (v) {
      _manuallyHiddenByStatusId[widget.statusId] = true;
    } else {
      // 不在 == false。false で埋めず FIFO 枠を節約する。
      _manuallyHiddenByStatusId.remove(widget.statusId);
    }
  }

  /// メディア領域に 1 つだけ重ねる「隠す」ボタンを出すか (公式 Web UI と同じく
  /// 1 か所のみ)。表示中のメディアがあるときだけ出す = 既に全部隠れている
  /// (手動隠し or sensitive で全ぼかし) ときは「隠す」対象が無いので出さない。
  bool get _showHideButton {
    if (_manuallyHidden) return false;
    if (widget.sensitive && !widget.disableBlur) {
      // sensitive: 1 枚でも個別表示しているときだけ出す。
      return _unblurredIndices.isNotEmpty;
    }
    return true; // 非 sensitive / ぼかし無効: 常に表示中
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Padding(
        // right はヘッダーの horizontal padding (12) と揃えて視覚的に整列。
        // left は親から渡される動的値 (avatarSize 設定に追従)。
        padding: EdgeInsets.only(
          left: widget.bodyLeftPadding,
          right: _kPostHorizPad,
          top: 4.0,
          bottom: 6.0,
        ),
        child: Stack(
          children: [
            widget.layout == MediaLayout.grid
                ? _buildGridLayout(context)
                : _buildHorizontalLayout(context),
            // 公式 Web UI と同じく「隠す」ボタンはメディア領域に 1 つだけ (右上)。
            // タップで投稿の全メディアを隠す。
            if (_showHideButton)
              Positioned(
                top: 6,
                right: 6,
                child: _HideMediaButton(
                  size: 30,
                  onTap: () => setState(() => _manuallyHidden = true),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 従来の横スクロール表示。1 投稿あたり高さ固定 (`mediaSize`)、横はアスペクト比
  /// に応じて伸縮 (横長は最大 2:1 でクランプ、縦長/正方形は正方形)。
  Widget _buildHorizontalLayout(BuildContext context) {
    final ms = widget.mediaSize;
    final dpr = MediaQuery.devicePixelRatioOf(context);

    return SizedBox(
      height: ms,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: widget.previewUrls.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final media = widget.mediaAttachments[i];
          // 横長は元のアスペクト比に合わせて幅を広げる (最大 2:1 でクランプ
          // して非常識な panorama に画面を専有させない)。縦長 / 正方形は
          // 縦に伸びすぎないよう正方形のまま (BoxFit.cover で中央トリミング)。
          final aspect = media.aspectRatio;
          final tw = aspect > 1.0
              ? (ms * aspect).clamp(ms, ms * 2.0).toDouble()
              : ms;
          return _buildMediaTile(
            index: i,
            width: tw,
            height: ms,
            dpr: dpr,
            borderRadius: 8,
            overlayBadge: null,
          );
        },
      ),
    );
  }

  /// 枚数別グリッド表示。
  /// - 1 枚: 元のアスペクトを保つ (0.8 (4:5 portrait) 〜 16:9 でクランプ)
  /// - 2 枚: 50/50 横分割、コンテナは 16:9
  /// - 3 枚: 左半分フル高 + 右半分上下分割、コンテナは 16:9
  /// - 4 枚: 2x2 グリッド、コンテナは 16:9
  /// - 5 枚以上: 4 枚目に +N オーバーレイ
  Widget _buildGridLayout(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final count = widget.previewUrls.length;
    const gap = 2.0;
    const radius = 12.0;

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;

          if (count == 1) {
            // 単独画像は元のアスペクト比を保つ (上限 16:9 横長 / 下限 4:5 縦長)。
            final aspect = widget.mediaAttachments[0].aspectRatio.clamp(0.8, 16 / 9);
            final height = width / aspect;
            return _buildMediaTile(
              index: 0,
              width: width,
              height: height,
              dpr: dpr,
              borderRadius: 0,
              overlayBadge: null,
            );
          }

          // 2+ 枚は 16:9 のコンテナに割り付け。
          final height = width * 9 / 16;
          final shown = count > 4 ? 4 : count;
          final extra = count - shown;

          Widget tileAt(int i, double w, double h) {
            final badge = (extra > 0 && i == shown - 1)
                ? _PlusNBadge(extra: extra)
                : null;
            return _buildMediaTile(
              index: i,
              width: w,
              height: h,
              dpr: dpr,
              borderRadius: 0,
              overlayBadge: badge,
            );
          }

          if (count == 2) {
            final tileW = (width - gap) / 2;
            return Row(children: [
              tileAt(0, tileW, height),
              const SizedBox(width: gap),
              tileAt(1, tileW, height),
            ]);
          }

          if (count == 3) {
            final tileW = (width - gap) / 2;
            final halfH = (height - gap) / 2;
            return Row(children: [
              tileAt(0, tileW, height),
              const SizedBox(width: gap),
              Column(children: [
                tileAt(1, tileW, halfH),
                const SizedBox(height: gap),
                tileAt(2, tileW, halfH),
              ]),
            ]);
          }

          // count >= 4 → 2x2
          final tileW = (width - gap) / 2;
          final tileH = (height - gap) / 2;
          return Column(children: [
            Row(children: [
              tileAt(0, tileW, tileH),
              const SizedBox(width: gap),
              tileAt(1, tileW, tileH),
            ]),
            const SizedBox(height: gap),
            Row(children: [
              tileAt(2, tileW, tileH),
              const SizedBox(width: gap),
              tileAt(3, tileW, tileH),
            ]),
          ]);
        },
      ),
    );
  }

  /// 単一メディアタイルを構築。ぼかし / 動画オーバーレイ / GIF バッジ / タップ
  /// 遷移を一括で処理。`overlayBadge` は +N 表示などの追加オーバーレイ用。
  Widget _buildMediaTile({
    required int index,
    required double width,
    required double height,
    required double dpr,
    required double borderRadius,
    required Widget? overlayBadge,
  }) {
    final media = widget.mediaAttachments[index];
    final fs = widget.fontSize;
    // 手動で隠す (投稿単位) が最優先。次に sensitive の個別ぼかし。手動隠しは
    // disableBlur / sensitive と独立に効く。
    final manuallyHidden = _manuallyHidden;
    final needsBlur = manuallyHidden ||
        (widget.sensitive &&
            !_unblurredIndices.contains(index) &&
            !widget.disableBlur);

    // memCacheWidth と memCacheHeight を両方指定すると Flutter の
    // ResizeImage は元画像のアスペクト比を「無視」して指定サイズに
    // squish した状態でデコードする。
    // 結果、box が正方形だと縦長画像も縦に潰れて BoxFit.cover が
    // 中央トリミングしてくれなくなる。
    // これを避けるため、デコード解像度は「元画像のアスペクト比を保ち、
    // BoxFit.cover で box を覆える最小のサイズ」を計算して渡す。
    final aspect = media.aspectRatio;
    final boxAspect = width / height;
    final int cacheW;
    final int cacheH;
    if (aspect >= boxAspect) {
      cacheH = (height * dpr).round();
      cacheW = (height * aspect * dpr).round();
    } else {
      cacheW = (width * dpr).round();
      cacheH = (width / aspect * dpr).round();
    }

    Widget thumbnail = SizedBox(
      width: width,
      height: height,
      child: KurageNetworkImage(
        imageUrl: widget.previewUrls[index],
        width: width,
        height: height,
        memCacheWidth: cacheW,
        memCacheHeight: cacheH,
        fit: BoxFit.cover,
        fadeInDuration: const Duration(milliseconds: 200),
        fadeOutDuration: const Duration(milliseconds: 200),
        placeholder: (_, _) => Container(
            color: Colors.grey.shade300, width: width, height: height),
        errorWidget: (_, _, _) => Container(
          width: width,
          height: height,
          color: Colors.grey.shade300,
          child: Icon(Icons.broken_image, size: height * 0.5),
        ),
      ),
    );

    if (media.isVideo) {
      // gifv (GIF→mp4) も通常の video もタイムラインでは静止プレビューに
      // 留める。タイムラインで多数の VideoPlayer を立ち上げると ExoPlayer
      // のデコーダー上限を超えて native クラッシュにつながるため。
      final overlayLabel = media.isGif
          ? const _GifBadge()
          : Icon(
              Icons.play_circle_fill,
              color: Colors.white,
              size: (height * 0.4).clamp(24.0, 48.0),
            );
      thumbnail = Stack(children: [
        thumbnail,
        Positioned.fill(
          child: Container(
            color: Colors.black26,
            child: Center(child: overlayLabel),
          ),
        ),
      ]);
    }

    if (needsBlur) {
      if (kIsWeb) {
        // Web は CORS 回避のため、CORS 不可の画像を HTML <img> 要素として描画
        // する (network_image_x.dart の WebHtmlElementStrategy.fallback)。<img>
        // は Flutter canvas の「上」に別 DOM レイヤーとして合成されるため、
        // canvas フィルタである ImageFiltered (ImageFilter.blur) ではぼかせない
        // (ぼかしが外れて素の画像が見えてしまう)。どの画像が canvas / <img> の
        // どちらになるかは読み込み時まで分からないので、Web では一律「ぼかし」
        // ではなく「画像を読み込まず不透明カバーで隠す」方式にする。タップで
        // _unblurredIndices に入れて表示。ぼかし透けより安全 & opt-in するまで
        // 画像 bytes を取得しない。
        thumbnail = SizedBox(
          width: width,
          height: height,
          child: Container(
            color: const Color(0xFF2A2A2A),
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.visibility_off,
                  color: Colors.white,
                  size: (height * 0.18).clamp(18.0, 40.0),
                ),
                const SizedBox(height: 6),
                Text(
                  context.l10n.postRevealAction,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: fs * 0.85,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        );
      } else {
        // sigma を固定値にするとグリッド表示の大きいタイル (1 枚モードで
        // 投稿幅いっぱい = 数百 px 級) ではぼかしが透けて見える。タイルの
        // 短辺に対して相対的に強さを決める。
        final smallerDim = width < height ? width : height;
        final blurSigma = (smallerDim / 10).clamp(10.0, 40.0);
        thumbnail = Stack(children: [
          ImageFiltered(
            imageFilter:
                ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
            child: thumbnail,
          ),
          Positioned.fill(
            child: Center(
              child: Container(
                color: Colors.black26,
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  context.l10n.postRevealAction,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: fs * 0.8,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ]);
      }
    }

    // +N 等の追加オーバーレイ (グリッド時のみ)
    if (overlayBadge != null) {
      thumbnail = Stack(children: [
        thumbnail,
        Positioned.fill(child: overlayBadge),
      ]);
    }

    // ALT バッジ。description が設定されているメディアにだけ左下に重ねる。
    // ぼかし中は「表示する」CTA とぶつかるのと、見えていない画像の説明文を
    // 出してもアクセシビリティ的に効かないので非表示にする。
    final altText = media.description?.trim() ?? '';
    if (altText.isNotEmpty && !needsBlur) {
      thumbnail = Stack(children: [
        thumbnail,
        Positioned(
          left: 6,
          bottom: 6,
          child: _AltBadge(description: altText),
        ),
      ]);
    }

    final tappable = MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () {
          if (manuallyHidden) {
            // 投稿全体を表示に戻す (sensitive は個別ぼかしに復帰し NSFW 保護を維持)。
            setState(() => _manuallyHidden = false);
          } else if (needsBlur) {
            // sensitive のみ: 従来どおり個別解除。
            setState(() => _unblurredIndices.add(index));
          } else {
            // Deck (ワイド) では画像アスペクト比に合わせた中央モーダル窓、
            // ナローではフルスクリーン push で開く ([showMediaGallery] が出し分け)。
            showMediaGallery(
              context,
              imageUrls: widget.fullUrls,
              mediaAttachments: widget.mediaAttachments,
              initialIndex: index,
            );
          }
        },
        // 長押しでも投稿全体を隠す (ボタンと同じ per-post セマンティクスに統一)。
        onLongPress:
            needsBlur ? null : () => setState(() => _manuallyHidden = true),
        child: thumbnail,
      ),
    );

    // 横スクロール時は個別タイルに角丸、グリッド時は外側の ClipRRect が掛かる。
    if (borderRadius > 0) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: tappable,
      );
    }
    return tappable;
  }
}

/// グリッド表示で 5 枚以上の場合、4 枚目のタイルに「+N」を重ねるバッジ。
class _PlusNBadge extends StatelessWidget {
  final int extra;
  const _PlusNBadge({required this.extra});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black54,
      alignment: Alignment.center,
      child: Text(
        '+$extra',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 28,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

// ===========================================================================
// アクションバー (PostTile から切り出した子ウィジェット)
// ===========================================================================
//
// _favourited / _reblogged / _bookmarked をこのウィジェットの State 内に
// 閉じ込めることで、各ボタンタップによる API 反映後の setState で
// PostTile 全体 (3000+行) の rebuild が走らず、アクションバーだけが
// 再描画される。
//
// メニュー項目のアクション (edit/delete/mute/translate 等) は親に固有な
// 副作用が多いため、PostTile 側に残し onMenuAction コールバックで委譲する。

class _PostActionBar extends ConsumerStatefulWidget {
  /// TL アイテムとしての Status (ブーストの場合はラッパー)。
  /// reply / quote の対象解決に使う。
  final Status status;

  /// 表示用の status (reblog の場合は reblog 自身、引用の場合は元 status)。
  /// reblogsCount / favouritesCount の表示に加え、リアクション
  /// (fav/RT/bookmark/pin) の状態参照・API 対象・キャッシュキーもこちらを使う。
  /// ブーストのラッパー status は Mastodon API 上 favourited / bookmarked
  /// 等のフラグを持たない (常に false) ため、ラッパー基準にすると
  /// 「ブックマーク済み投稿がブースト経由で流れてくると未ブックマーク表示に
  /// なり、再操作がサーバエラーになる」バグになる。
  final Status displayStatus;

  /// API を叩くアカウント
  final AuthAccount account;

  /// 親 PostTile が選択中のアカウントID (reply/quote の initial アカウント)
  final String? accountId;

  // settings 由来
  final double iconSize;
  final bool showReactionCounts;
  final bool confirmReblog;        // ブースト時
  final bool confirmUnreblog;      // ブースト解除時
  final bool confirmFavourite;     // お気に入り時
  final bool confirmUnfavourite;   // お気に入り解除時
  final bool confirmBookmark;      // ブックマーク時
  final bool confirmUnbookmark;    // ブックマーク解除時

  // theme 由来
  final Color? iconColor;

  // メニュー関連
  final bool isOwnPost;

  /// ドメインブロックを表示するか (リモートユーザーの時 true、その時のラベル文字列を渡す)
  final String? domainBlockLabel;

  /// メニュー選択時のコールバック (action 文字列を親に渡す)
  final void Function(String value) onMenuAction;

  /// status の取得元サーバー ([PostTile.statusSourceInstanceUrl] 参照)。
  /// non-null なら status.id はホームサーバー上の ID ではないため、
  /// リアクション実行前に [_actionStatusId] で解決する。
  final String? statusSourceInstanceUrl;

  const _PostActionBar({
    required this.status,
    required this.displayStatus,
    required this.account,
    required this.accountId,
    required this.iconSize,
    required this.showReactionCounts,
    required this.confirmReblog,
    required this.confirmUnreblog,
    required this.confirmFavourite,
    required this.confirmUnfavourite,
    required this.confirmBookmark,
    required this.confirmUnbookmark,
    required this.iconColor,
    required this.isOwnPost,
    required this.domainBlockLabel,
    required this.onMenuAction,
    this.statusSourceInstanceUrl,
  });

  @override
  ConsumerState<_PostActionBar> createState() => _PostActionBarState();
}

class _PostActionBarState extends ConsumerState<_PostActionBar> {
  /// status ID → ユーザー操作後の fav/RT/bookmark 状態キャッシュ。
  /// アクションバー非表示設定の場合、_PostActionBar は表示トグルで
  /// dispose / recreate されるため、ローカル State だけだと
  /// 「ブックマーク → 閉じる → 開く」で widget.displayStatus.bookmarked
  /// (= サーバから取得した時点での値) に戻ってしまう。
  /// PostTile の他の static map (showActions / unblurred 等) と同じく
  /// status ID をキーに保持する。
  static final BoundedMap<String, bool> _favouritedByStatusId =
      BoundedMap(_kMaxTileCache);
  static final BoundedMap<String, bool> _rebloggedByStatusId =
      BoundedMap(_kMaxTileCache);
  static final BoundedMap<String, bool> _bookmarkedByStatusId =
      BoundedMap(_kMaxTileCache);
  /// プロフィールへのピン留め状態。Mastodon は自分の投稿で自分視点のときだけ
  /// `pinned` を返すため、他人投稿や別アカウント視点では常に false 起点。
  static final BoundedMap<String, bool> _pinnedByStatusId =
      BoundedMap(_kMaxTileCache);

  // 状態・キャッシュキーとも displayStatus (ブーストなら元投稿) 基準。
  // ラッパー status のフラグは常に false なので使わない (widget.displayStatus
  // の doc コメント参照)。元投稿 id をキーにすることで、同じ投稿が
  // 「本人の投稿」と「他人のブースト」の両方で TL に居ても状態が揃う。
  late bool _favourited = _favouritedByStatusId[widget.displayStatus.id] ??
      widget.displayStatus.favourited;
  late bool _reblogged = _rebloggedByStatusId[widget.displayStatus.id] ??
      widget.displayStatus.reblogged;
  late bool _bookmarked = _bookmarkedByStatusId[widget.displayStatus.id] ??
      widget.displayStatus.bookmarked;
  late bool _pinned =
      _pinnedByStatusId[widget.displayStatus.id] ?? widget.displayStatus.pinned;

  @override
  void didUpdateWidget(_PostActionBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 別の status を表す widget に置き換わった場合はトグル状態を再初期化
    if (oldWidget.displayStatus.id != widget.displayStatus.id) {
      _favourited = _favouritedByStatusId[widget.displayStatus.id] ??
          widget.displayStatus.favourited;
      _reblogged = _rebloggedByStatusId[widget.displayStatus.id] ??
          widget.displayStatus.reblogged;
      _bookmarked = _bookmarkedByStatusId[widget.displayStatus.id] ??
          widget.displayStatus.bookmarked;
      _pinned = _pinnedByStatusId[widget.displayStatus.id] ??
          widget.displayStatus.pinned;
    }
  }

  /// リアクション実行中 (解決 + API 呼び出し) のダブルタップガード。
  /// リモート由来 status の解決は search (resolve=true) を伴い数秒かかり
  /// うるため、その間の連打で二重実行しないようにする。
  bool _actionInFlight = false;

  /// リアクション API に渡す status ID。
  ///
  /// 通常はそのまま `displayStatus.id`。リモート由来
  /// (`statusSourceInstanceUrl != null`) なら、投稿 URL を操作アカウントの
  /// ホームサーバーで解決したローカル ID を返す (結果は
  /// `resolveStatusOnInstanceCached` がプロセス内キャッシュする)。
  /// 解決できなければ null (呼び元はエラー表示して中断する)。
  Future<String?> _actionStatusId() async {
    if (widget.statusSourceInstanceUrl == null) {
      return widget.displayStatus.id;
    }
    final url = widget.displayStatus.url ?? widget.displayStatus.uri;
    if (url == null) return null;
    return resolveStatusOnInstanceCached(
      instanceUrl: widget.account.instanceUrl,
      accessToken: widget.account.accessToken,
      originalStatusUrl: url,
    );
  }

  /// 「プロフィールにピン留め / 解除」を実行する。
  ///
  /// メニュー選択経由で呼ばれる (アクションバーのアイコンとしては出していない)。
  /// 5 件上限超過などサーバ側エラーは [PinStatusLimitException] で受けて
  /// 適切な日本語メッセージを SnackBar に出す。
  Future<void> _togglePin() async {
    final wasPinned = _pinned;
    try {
      await togglePin(
        instanceUrl: widget.account.instanceUrl,
        accessToken: widget.account.accessToken,
        statusId: widget.displayStatus.id,
        currentlyPinned: wasPinned,
      );
    } on PinStatusLimitException catch (e) {
      if (mounted) {
        showErrorSnackBar(
          context,
          wasPinned
              ? l10n.postUnpinFailed('$e')
              : l10n.postPinNotAllowed,
        );
      }
      return;
    } catch (_) {
      if (mounted) {
        showErrorSnackBar(
          context,
          wasPinned ? l10n.postUnpinFailedPlain : l10n.postPinFailedPlain,
        );
      }
      return;
    }
    final newValue = !wasPinned;
    _pinnedByStatusId[widget.displayStatus.id] = newValue;
    if (mounted) {
      setState(() => _pinned = newValue);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            newValue ? l10n.postPinned : l10n.postUnpinned,
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  /// 確認ダイアログを表示。`onDontAskAgain` が指定されていれば「今後は表示しない」
  /// チェックボックスを出し、チェックされて OK されたタイミングでコールバックを呼ぶ。
  /// 呼び元は対応する設定を OFF にする責任を持つ。
  Future<bool> _confirm(
    bool need,
    String title,
    String msg, {
    VoidCallback? onDontAskAgain,
  }) async {
    if (!need) return true;
    bool dontAskAgain = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(msg),
              if (onDontAskAgain != null) ...[
                const SizedBox(height: 12),
                InkWell(
                  onTap: () =>
                      setDialog(() => dontAskAgain = !dontAskAgain),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Checkbox(
                          value: dontAskAgain,
                          onChanged: (v) =>
                              setDialog(() => dontAskAgain = v ?? false),
                        ),
                        Expanded(child: Text(ctx.l10n.postDontShowAgain)),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(ctx.l10n.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('OK'),
            ),
          ],
        ),
      ),
    );
    // onDontAskAgain は ref.read を使うため、ダイアログ中にタイルが
    // unmount された場合は呼ばない (破棄後 ref アクセスで落ちるのを防ぐ)。
    if (ok == true && dontAskAgain && mounted) {
      onDontAskAgain?.call();
    }
    return ok == true;
  }

  /// リアクションボタン (ブースト / お気に入り / ブックマーク) のアイコン部分。
  ///
  /// `AnimatedSwitcher` で active / inactive を切り替え、`ValueKey(active)` で
  /// 同一性を区別することで **トグル時だけ** transition を起動する
  /// (= 通常時はコスト 0、TL に並ぶ複数の action bar が常時 CPU を食わない)。
  ///
  /// 入場 (`switchInCurve: Curves.elasticOut`): scale 0.2 → bounce → 1.0 で
  /// 「ボンッ」と弾むように現れる。
  /// 退場 (`switchOutCurve: Curves.easeIn`): scale 1.0 → 0、fade out。スッと
  /// 引っ込んで入場側のアニメと衝突しないように。
  ///
  /// `rotateOnChange: true` (boost 用) のときは + RotationTransition で
  /// 1 周回転する。repeat (繰り返し) の意味的にも「ぐるっと回る」と相性が良い。
  Widget _animatedReactionIcon({
    required bool active,
    required IconData activeIcon,
    required IconData inactiveIcon,
    required Color activeColor,
    required Color? inactiveColor,
    bool rotateOnChange = false,
  }) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 450),
      switchInCurve: Curves.elasticOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) {
        final scaled = ScaleTransition(
          scale: Tween<double>(begin: 0.2, end: 1.0).animate(animation),
          child: FadeTransition(opacity: animation, child: child),
        );
        if (!rotateOnChange) return scaled;
        return RotationTransition(turns: animation, child: scaled);
      },
      child: Icon(
        active ? activeIcon : inactiveIcon,
        key: ValueKey(active),
        color: active ? activeColor : inactiveColor,
      ),
    );
  }

  Widget _replyButton() {
    return IconButton(
      icon: Icon(Icons.reply, color: widget.iconColor),
      tooltip: context.l10n.postReplyLabel,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      onPressed: () {
        // リモート由来なら d.id はホームサーバーに存在しないので、URL 解決
        // 付きの `_replyAsAccount` (親 PostTile 側) に委譲する。
        if (widget.statusSourceInstanceUrl != null) {
          widget.onMenuAction('reply_remote');
          return;
        }
        final d = widget.status.reblog ?? widget.status;
        // ワイドは横ペイン、ナローはフルスクリーンに振り分け。
        openCompose(
          context,
          ref,
          replyToStatusId: d.id,
          replyToUsername: d.account.acct,
          replyToVisibility: d.visibility,
          initialAccountIds:
              widget.accountId != null ? [widget.accountId!] : null,
        );
      },
    );
  }

  Widget _reblogButton() {
    final btn = IconButton(
      icon: _animatedReactionIcon(
        active: _reblogged,
        activeIcon: Icons.repeat,
        inactiveIcon: Icons.repeat_outlined,
        activeColor: Colors.green,
        inactiveColor: widget.iconColor,
        rotateOnChange: true,
      ),
      tooltip: context.l10n.postBoostLabel,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      onPressed: () async {
        if (_actionInFlight) return;
        // 解除と追加で別フラグを参照
        final needConfirm =
            _reblogged ? widget.confirmUnreblog : widget.confirmReblog;
        final wasReblogged = _reblogged;
        if (!await _confirm(
          needConfirm,
          context.l10n.postBoostLabel,
          _reblogged
              ? context.l10n.postUnboostConfirm
              : context.l10n.postBoostConfirm,
          onDontAskAgain: () {
            final n = ref.read(settingsProvider.notifier);
            if (wasReblogged) {
              n.setConfirmUnreblog(false);
            } else {
              n.setConfirmReblog(false);
            }
          },
        )) {
          return;
        }
        _actionInFlight = true;
        try {
          final sid = await _actionStatusId();
          if (sid == null) {
            if (mounted) showErrorSnackBar(context, _kStatusNotResolvedMsg);
            return;
          }
          try {
            await toggleReblog(
              instanceUrl: widget.account.instanceUrl,
              accessToken: widget.account.accessToken,
              statusId: sid,
              currentlyReblogged: _reblogged,
            );
          } catch (e) {
            if (mounted) {
              showErrorSnackBar(
                context,
                _reblogged
                    ? l10n.postUnboostFailed
                    : l10n.postBoostFailedPlain,
              );
            }
            return;
          }
          // await 中にアクションバーが閉じられて unmount された場合でも
          // 状態が失われないよう、setState の前にキャッシュを更新する。
          // キャッシュ/state のキーは表示中の id (リモート由来ならリモート ID)
          // のまま。解決後 ID は API 引数専用 (rebuild 時の参照キーと揃える)。
          final newValue = !_reblogged;
          _rebloggedByStatusId[widget.displayStatus.id] = newValue;
          if (mounted) setState(() => _reblogged = newValue);
          // 利用状況: リアクション (種別と add/remove のみ。投稿/アカウントは送らない)。
          AnalyticsService.instance.logEvent('reaction', parameters: {
            'type': 'boost',
            'action': newValue ? 'add' : 'remove',
          });
        } finally {
          _actionInFlight = false;
        }
      },
    );
    if (!widget.showReactionCounts) return btn;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        btn,
        if (widget.displayStatus.reblogsCount > 0)
          Text(
            '${widget.displayStatus.reblogsCount}',
            style:
                TextStyle(fontSize: widget.iconSize * 0.6, color: Colors.grey),
          ),
      ],
    );
  }

  Widget _quoteButton() {
    return IconButton(
      icon: Icon(Icons.format_quote, color: widget.iconColor),
      tooltip: context.l10n.postQuoteAction,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      onPressed: () {
        // リモート由来なら target.id はホームサーバーに存在しないので、
        // searchContent で実体ごと解決する `_quoteAsAccount` (親側) に委譲。
        if (widget.statusSourceInstanceUrl != null) {
          widget.onMenuAction('quote_remote');
          return;
        }
        // reblog の場合は元の投稿を引用対象とする
        final target = widget.status.reblog ?? widget.status;
        // ワイドは横ペイン、ナローはフルスクリーンに振り分け。
        openCompose(
          context,
          ref,
          quotedStatus: target,
          initialVisibility: target.visibility,
          initialAccountIds:
              widget.accountId != null ? [widget.accountId!] : null,
        );
      },
    );
  }

  Widget _favouriteButton() {
    final btn = IconButton(
      icon: _animatedReactionIcon(
        active: _favourited,
        activeIcon: Icons.star,
        inactiveIcon: Icons.star_border,
        activeColor: Colors.amber,
        inactiveColor: widget.iconColor,
      ),
      tooltip: context.l10n.favourite,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      onPressed: () async {
        if (_actionInFlight) return;
        final needConfirm =
            _favourited ? widget.confirmUnfavourite : widget.confirmFavourite;
        final wasFavourited = _favourited;
        if (!await _confirm(
          needConfirm,
          context.l10n.favourite,
          _favourited
              ? context.l10n.postUnfavConfirm
              : context.l10n.postFavConfirm,
          onDontAskAgain: () {
            final n = ref.read(settingsProvider.notifier);
            if (wasFavourited) {
              n.setConfirmUnfavourite(false);
            } else {
              n.setConfirmFavourite(false);
            }
          },
        )) {
          return;
        }
        _actionInFlight = true;
        try {
          final sid = await _actionStatusId();
          if (sid == null) {
            if (mounted) showErrorSnackBar(context, _kStatusNotResolvedMsg);
            return;
          }
          try {
            await toggleFavourite(
              instanceUrl: widget.account.instanceUrl,
              accessToken: widget.account.accessToken,
              statusId: sid,
              currentlyFavourited: _favourited,
            );
          } catch (e) {
            if (mounted) {
              showErrorSnackBar(
                context,
                _favourited ? l10n.postUnfavFailed : l10n.postFavFailedPlain,
              );
            }
            return;
          }
          final newValue = !_favourited;
          _favouritedByStatusId[widget.displayStatus.id] = newValue;
          if (mounted) setState(() => _favourited = newValue);
          AnalyticsService.instance.logEvent('reaction', parameters: {
            'type': 'favorite',
            'action': newValue ? 'add' : 'remove',
          });
        } finally {
          _actionInFlight = false;
        }
      },
    );
    if (!widget.showReactionCounts) return btn;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        btn,
        if (widget.displayStatus.favouritesCount > 0)
          Text(
            '${widget.displayStatus.favouritesCount}',
            style:
                TextStyle(fontSize: widget.iconSize * 0.6, color: Colors.grey),
          ),
      ],
    );
  }

  Widget _bookmarkButton() {
    return IconButton(
      icon: _animatedReactionIcon(
        active: _bookmarked,
        activeIcon: Icons.bookmark,
        inactiveIcon: Icons.bookmark_border,
        activeColor: Colors.blue,
        inactiveColor: widget.iconColor,
      ),
      tooltip: context.l10n.postBookmarkLabel,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      onPressed: () async {
        if (_actionInFlight) return;
        final needConfirm =
            _bookmarked ? widget.confirmUnbookmark : widget.confirmBookmark;
        final wasBookmarked = _bookmarked;
        if (!await _confirm(
          needConfirm,
          context.l10n.postBookmarkLabel,
          _bookmarked
              ? context.l10n.postUnbookmarkConfirm
              : context.l10n.postBookmarkConfirm,
          onDontAskAgain: () {
            final n = ref.read(settingsProvider.notifier);
            if (wasBookmarked) {
              n.setConfirmUnbookmark(false);
            } else {
              n.setConfirmBookmark(false);
            }
          },
        )) {
          return;
        }
        _actionInFlight = true;
        try {
          final sid = await _actionStatusId();
          if (sid == null) {
            if (mounted) showErrorSnackBar(context, _kStatusNotResolvedMsg);
            return;
          }
          try {
            await toggleBookmark(
              instanceUrl: widget.account.instanceUrl,
              accessToken: widget.account.accessToken,
              statusId: sid,
              currentlyBookmarked: _bookmarked,
            );
          } catch (e) {
            if (mounted) {
              showErrorSnackBar(
                context,
                _bookmarked
                    ? l10n.postUnbookmarkFailed
                    : l10n.postBookmarkFailedPlain,
              );
            }
            return;
          }
          final newValue = !_bookmarked;
          _bookmarkedByStatusId[widget.displayStatus.id] = newValue;
          if (mounted) setState(() => _bookmarked = newValue);
          AnalyticsService.instance.logEvent('reaction', parameters: {
            'type': 'bookmark',
            'action': newValue ? 'add' : 'remove',
          });
        } finally {
          _actionInFlight = false;
        }
      },
    );
  }

  Widget _menuButton() {
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_horiz, color: widget.iconColor),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      onSelected: (value) {
        // ピン留めは _PostActionBar 内部で完結させる (fav/RT/bookmark と同様)。
        // メニュー label が _pinned 状態に依存するので、トグル後すぐ
        // ラベルが切り替わるよう state を持つこちら側で処理する。
        if (value == 'toggle_pin') {
          _togglePin();
          return;
        }
        widget.onMenuAction(value);
      },
      itemBuilder: (context) {
        // 順番:
        //   1. 自分の投稿のみ: 編集 / 削除 / 削除して下書きに戻す
        //   2. 共通: 別アカウントからリアクション
        //   3. 共通: 翻訳 (インスタンス) / 翻訳アプリで開く
        //   4. 共通: クリップボードにコピー / サーバー情報
        //   5. 他人の投稿のみ (一番下): ミュート / ブロック / ドメインブロック
        final items = <PopupMenuEntry<String>>[
          if (widget.isOwnPost) ...[
            PopupMenuItem(
              value: 'edit',
              child: ListTile(
                leading: const Icon(Icons.edit),
                title: Text(context.l10n.postEditAction),
                dense: true,
              ),
            ),
            PopupMenuItem(
              value: 'delete',
              child: ListTile(
                leading: const Icon(Icons.delete, color: Colors.red),
                title: Text(context.l10n.delete,
                    style: const TextStyle(color: Colors.red)),
                dense: true,
              ),
            ),
            PopupMenuItem(
              value: 'delete_and_redraft',
              child: ListTile(
                leading: const Icon(Icons.edit_note, color: Colors.orange),
                title: Text(context.l10n.postRedraftTitle,
                    style: const TextStyle(color: Colors.orange)),
                dense: true,
              ),
            ),
            // プロフィール固定。Mastodon 仕様で「自分の public/unlisted な投稿
            // のみ」固定可、最大 5 件。投稿時点では空気を読まずに常に項目を出し、
            // サーバが弾けば SnackBar で案内する (公開範囲チェック等を
            // クライアントで先回りすると、派生実装で上限/条件が違う場合に齟齬る)。
            PopupMenuItem(
              value: 'toggle_pin',
              child: ListTile(
                leading: Icon(_pinned
                    ? Icons.push_pin
                    : Icons.push_pin_outlined),
                title: Text(
                  _pinned
                      ? context.l10n.postUnpinAction
                      : context.l10n.postPinAction,
                ),
                dense: true,
              ),
            ),
            const PopupMenuDivider(),
          ],
          PopupMenuItem(
            value: 'react_as_other_account',
            child: ListTile(
              leading: const Icon(Icons.switch_account),
              title: Text(context.l10n.postReactFromOtherTitle),
              dense: true,
            ),
          ),
          const PopupMenuDivider(),
          // ブーストした人 / お気に入りした人。鍵アカウント等で一覧を見せない
          // 仕様のサーバもあるが、その場合は遷移先で「まだ誰も〜」表示になる
          // (`fetchRebloggedBy` / `fetchFavouritedBy` が 401/403/404 を空配列扱い)。
          PopupMenuItem(
            value: 'show_reblogged_by',
            child: ListTile(
              leading: const Icon(Icons.repeat),
              title: Text(
                widget.displayStatus.reblogsCount > 0
                    ? context.l10n.postRebloggedByCount(
                        widget.displayStatus.reblogsCount)
                    : context.l10n.postRebloggedBy,
              ),
              dense: true,
            ),
          ),
          PopupMenuItem(
            value: 'show_favourited_by',
            child: ListTile(
              leading: const Icon(Icons.star_border),
              title: Text(
                widget.displayStatus.favouritesCount > 0
                    ? context.l10n.postFavouritedByCount(
                        widget.displayStatus.favouritesCount)
                    : context.l10n.postFavouritedBy,
              ),
              dense: true,
            ),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'translate_instance',
            child: ListTile(
              leading: const Icon(Icons.translate),
              title: Text(context.l10n.postTranslateInstance),
              dense: true,
            ),
          ),
          PopupMenuItem(
            value: 'translate_google',
            child: ListTile(
              leading: const Icon(Icons.g_translate),
              title: Text(context.l10n.postOpenGoogleTranslate),
              dense: true,
            ),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'copy_to_clipboard',
            child: ListTile(
              leading: const Icon(Icons.content_copy),
              title: Text(context.l10n.postCopyBody),
              dense: true,
            ),
          ),
          PopupMenuItem(
            value: 'copy_url',
            child: ListTile(
              leading: const Icon(Icons.share),
              title: Text(context.l10n.postShareUrlTitle),
              dense: true,
            ),
          ),
          PopupMenuItem(
            value: 'server_info',
            child: ListTile(
              leading: const Icon(Icons.dns),
              title: Text(context.l10n.profServerInfoTitle),
              dense: true,
            ),
          ),
          // アカウント系操作 (リスト追加 / ミュート / ブロック / 通報) は
          // リモート由来では出さない。display.account.id が取得元サーバー上の
          // ID のため、ホームサーバーの API に渡すと**別人に誤爆**しうる。
          // 同じ操作はプロフィールページ (home 解決済み) から行える。
          if (!widget.isOwnPost && widget.statusSourceInstanceUrl == null) ...[
            const PopupMenuDivider(),
            PopupMenuItem(
              value: 'add_to_list',
              child: ListTile(
                leading: const Icon(Icons.playlist_add),
                title: Text(context.l10n.listAddToList),
                dense: true,
              ),
            ),
            PopupMenuItem(
              value: 'mute',
              child: ListTile(
                leading: const Icon(Icons.volume_off),
                title: Text(context.l10n.muteTitle),
                dense: true,
              ),
            ),
            PopupMenuItem(
              value: 'block',
              child: ListTile(
                leading: const Icon(Icons.block, color: Colors.red),
                title: Text(context.l10n.profBlock,
                    style: const TextStyle(color: Colors.red)),
                dense: true,
              ),
            ),
            if (widget.domainBlockLabel != null)
              PopupMenuItem(
                value: 'domain_block',
                child: ListTile(
                  leading: const Icon(Icons.shield, color: Colors.red),
                  title: Text(
                    widget.domainBlockLabel!,
                    style: const TextStyle(color: Colors.red),
                  ),
                  dense: true,
                ),
              ),
            PopupMenuItem(
              value: 'report',
              child: ListTile(
                leading: const Icon(Icons.flag_outlined, color: Colors.red),
                title: Text(context.l10n.reportAction,
                    style: const TextStyle(color: Colors.red)),
                dense: true,
              ),
            ),
          ],
        ];
        return items;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: SizedBox(
          height: widget.iconSize + 16,
          child: IconTheme(
            data: IconThemeData(size: widget.iconSize),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _replyButton(),
                _reblogButton(),
                _quoteButton(),
                _favouriteButton(),
                _bookmarkButton(),
                _menuButton(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// PostTile から切り出したサブウィジェット群。
// ===========================================================================
//
// 切り出しの目的は (a) build 関数の見通しを良くする、(b) Element 等価判定で
// 「変わらなかった部分は子の build をスキップする」効果を狙うことの 2 点。
// すべて StatelessWidget で、必要な span は親側 (_PostTileState) で
// `_cachedParseSpans` 経由で生成して受け渡す。

/// ブースト情報バー (リブログの表示。引用リノートでは出さない)。
class _BoostInfoBar extends StatelessWidget {
  /// ブーストした人 (= 元 status.account)
  final Account boostAccount;

  /// 既にパース済みの表示名 spans (カスタム絵文字対応)
  final List<InlineSpan> boostAccountSpans;

  /// プロフィール遷移時に「操作するアカウント」として渡す
  final AuthAccount viewingAccount;

  /// ブースト時刻
  final DateTime createdAt;

  /// settings 派生
  final double fontSize;
  final double avatarSize;
  final bool useRelativeTime;

  const _BoostInfoBar({
    required this.boostAccount,
    required this.boostAccountSpans,
    required this.viewingAccount,
    required this.createdAt,
    required this.fontSize,
    required this.avatarSize,
    required this.useRelativeTime,
  });

  @override
  Widget build(BuildContext context) {
    // バー全体 (アイコン + 名前) タップでプロフィールに飛ぶので、ポインタの
    // ある環境ではクリック可能カーソルにする。
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
      onTap: () {
        // ブーストした人のインスタンスURLを取得
        String? boostUserInstanceUrl;
        if (boostAccount.acct.contains('@')) {
          // リモートユーザー: @username@instance.domain
          final parts = boostAccount.acct.split('@');
          if (parts.length >= 2) {
            boostUserInstanceUrl = 'https://${parts.last}';
          }
        } else {
          boostUserInstanceUrl = viewingAccount.instanceUrl;
        }

        openProfile(
          context,
          user: viewingAccount,
          targetAccountId: boostAccount.id,
          targetUsername: boostAccount.username,
          targetInstanceUrl: boostUserInstanceUrl,
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        child: Row(
          children: [
            Icon(
              Icons.repeat,
              size: fontSize * 2,
              color: Colors.green[600],
            ),
            const SizedBox(width: 6),
            // 設定で「アイコンを四角表示」が ON のときも合わせて
            // 四角にする (本文側のアバターと統一感を出すため)。
            UserAvatar(
              url: boostAccount.avatarUrl,
              radius: avatarSize * 0.25,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: isolateText(
                      textDirection: TextDirection.ltr,
                      // バー全体がプロフィールへのリンクなので、選択可能な
                      // Text.rich ではなく RichText を使う (Text.rich だと I-beam
                      // カーソルが MouseRegion(click) を上書きしてしまう)。
                      child: RichText(
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textDirection: TextDirection.ltr,
                        text: TextSpan(
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: fontSize,
                          ),
                          children: boostAccountSpans,
                        ),
                      ),
                    ),
                  ),
                  Text(
                    context.l10n.postBoostedBySuffix,
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: fontSize,
                      height: 1.0,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TimeText(
              dt: createdAt,
              useRelative: useRelativeTime,
              style: TextStyle(
                color: Colors.grey[600],
                fontSize: fontSize,
                height: 1.0,
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

/// 投稿アバター (タップでプロフィール遷移)。
class _PostAvatar extends StatelessWidget {
  final Status status;
  final AuthAccount viewingAccount;
  final double size;
  final bool isSquare;
  final double devicePixelRatio;

  const _PostAvatar({
    required this.status,
    required this.viewingAccount,
    required this.size,
    required this.isSquare,
    required this.devicePixelRatio,
  });

  @override
  Widget build(BuildContext context) {
    final d = status.reblog ?? status;
    final cacheSide = (size * devicePixelRatio).round();
    // タップでプロフィールに飛ぶので、ポインタがある環境 (Web/デスクトップ)
    // ではホバー時にクリック可能カーソル (手) にする。モバイルでは無害。
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
      onTap: () {
        // ユーザーのインスタンスURLを取得
        String? userInstanceUrl;
        if (d.account.acct.contains('@')) {
          final parts = d.account.acct.split('@');
          if (parts.length >= 2) {
            userInstanceUrl = 'https://${parts.last}';
          }
        } else {
          userInstanceUrl = viewingAccount.instanceUrl;
        }

        openProfile(
          context,
          user: viewingAccount,
          targetAccountId: d.account.id,
          targetUsername: d.account.username,
          targetInstanceUrl: userInstanceUrl,
        );
      },
      child: isSquare
          ? ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: KurageNetworkImage(
                imageUrl: d.account.avatarUrl,
                width: size,
                height: size,
                memCacheWidth: cacheSide,
                memCacheHeight: cacheSide,
                fit: BoxFit.cover,
                placeholder: (_, _) => Container(
                  color: Colors.grey.shade200,
                  width: size,
                  height: size,
                  child: const SizedBox.shrink(),
                ),
                errorWidget: (_, _, _) =>
                    Icon(Icons.error, size: size * 0.5),
              ),
            )
          : KurageCircleAvatar(
              imageUrl: d.account.avatarUrl,
              radius: size / 2,
            ),
      ),
    );
  }
}

/// CW 折りたたみ時 / 展開時に常に表示するグレーの CW ヘッダー枠。
/// 「表示 / 畳む」トグルは WidgetSpan で警告文の末尾にインライン配置する。
/// (Row + Expanded だと長い警告文が全行ボタン幅分狭く折り返されるため)
class _CwBox extends StatelessWidget {
  final List<InlineSpan> cwSpans;
  final TextStyle defaultStyle;
  final bool isDarkMode;
  final double fontSize;
  final bool revealed;

  /// null ならトグル非表示 (alwaysExpandCW 有効時の展開状態)。
  final VoidCallback? onToggle;

  const _CwBox({
    required this.cwSpans,
    required this.defaultStyle,
    required this.isDarkMode,
    required this.fontSize,
    required this.revealed,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: isDarkMode
            ? Colors.grey.shade800.withValues(alpha: 0.6)
            : Colors.grey.shade200,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDarkMode ? Colors.grey.shade700 : Colors.grey.shade300,
          width: 1,
        ),
      ),
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Text.rich(
        textScaler: TextScaler.noScaling,
        TextSpan(
          style: defaultStyle.copyWith(
            color: isDarkMode ? Colors.grey.shade300 : Colors.grey.shade700,
          ),
          children: [
            TextSpan(
              text: 'CW: ',
              style: defaultStyle.copyWith(
                fontWeight: FontWeight.w600,
                color: isDarkMode
                    ? Colors.orange.shade300
                    : Colors.orange.shade700,
              ),
            ),
            ...cwSpans,
            if (onToggle != null) ...[
              const WidgetSpan(child: SizedBox(width: 8)),
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: _CwToggleButton(
                  revealed: revealed,
                  fontSize: fontSize,
                  isDarkMode: isDarkMode,
                  onPressed: onToggle!,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 「表示」/「畳む」ボタン (CW のトグル用)。
class _CwToggleButton extends StatelessWidget {
  final bool revealed;
  final double fontSize;
  final bool isDarkMode;
  final VoidCallback onPressed;

  const _CwToggleButton({
    required this.revealed,
    required this.fontSize,
    required this.isDarkMode,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: Icon(
        revealed ? Icons.visibility_off : Icons.visibility,
        size: fontSize * 1.2,
        color: Colors.white,
      ),
      label: Text(
        revealed
            ? context.l10n.postCollapseAction
            : context.l10n.postShowAction,
        style: TextStyle(fontSize: fontSize, color: Colors.white),
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: revealed
            ? (isDarkMode ? Colors.grey.shade600 : Colors.grey.shade500)
            : (isDarkMode ? Colors.blue.shade600 : Colors.blue.shade500),
        foregroundColor: Colors.white,
        // ボタンサイズをフォントサイズ設定に追従させる。既定の
        // minimumSize (64x36) + タップターゲット 48px のままだと、
        // 小フォント設定時に本文よりボタンだけが大きく浮く。
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.symmetric(
          horizontal: fontSize * 0.8,
          vertical: fontSize * 0.4,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
    );
  }
}

/// 引用元投稿カード (Twitter ライクな枠付き表示)。
class _QuotedPostCard extends StatefulWidget {
  final Status quotedStatus;
  final List<InlineSpan> accountNameSpans;
  // 本文 (引用元の content) の spans。CW あり/なし問わず常に渡す。
  // CW ありのときは _revealed=true でこれを描画する。
  final List<InlineSpan> contentSpans;
  // CW 付き投稿のときに spoilerText を span 化したもの。なければ null。
  final List<InlineSpan>? cwSpans;
  final double fontSize;
  final bool useRelativeTime;
  final VoidCallback onTap;
  // CW 付き投稿の引用かどうか。true なら本文/メディアを「表示」
  // ボタンで開けるようにする。
  final bool isCw;
  // CW なしで sensitive: true のときに true。メディアプレビューを
  // 件数だけのプレースホルダに置き換える (こちらはインライントグル無し)。
  final bool hideMedia;

  const _QuotedPostCard({
    required this.quotedStatus,
    required this.accountNameSpans,
    required this.contentSpans,
    required this.cwSpans,
    required this.fontSize,
    required this.useRelativeTime,
    required this.onTap,
    required this.isCw,
    required this.hideMedia,
  });

  @override
  State<_QuotedPostCard> createState() => _QuotedPostCardState();
}

class _QuotedPostCardState extends State<_QuotedPostCard> {
  // CW を開いた状態を status ID で覚える。`scrollable_positioned_list`
  // が画面外でこの Widget の State を破棄しても、戻ってきたとき展開状態を
  // 維持できるようにするため。
  static final BoundedMap<String, bool> _revealedByQuotedStatusId =
      BoundedMap(_kMaxTileCache);

  bool get _revealed =>
      _revealedByQuotedStatusId[widget.quotedStatus.id] ?? false;

  void _toggleReveal() {
    setState(() {
      _revealedByQuotedStatusId[widget.quotedStatus.id] = !_revealed;
    });
  }

  /// 引用カード内のメディアグリッド。`_PostMediaGallery._buildGridLayout` の
  /// 縮小版で、画像数に応じて以下のレイアウトを取る:
  /// - 1 枚: 全幅 × 元画像のアスペクト比 (0.8〜16:9 でクランプ)
  /// - 2 枚: 16:9 コンテナを左右 2 分割
  /// - 3 枚: 16:9 コンテナで左半分フル高さ + 右半分上下分割
  /// - 4 枚: 16:9 コンテナで 2x2 グリッド
  /// - 5 枚以上: 4 枚目に +N オーバーレイ (現状未実装、4 枚で切るだけ)
  Widget _buildQuotedMediaGrid(Status quotedStatus) {
    final attachments = quotedStatus.mediaAttachments;
    final count = attachments.length;
    if (count == 0) return const SizedBox.shrink();

    const gap = 2.0;
    const radius = 8.0;

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final dpr = MediaQuery.devicePixelRatioOf(context);

          if (count == 1) {
            final aspect =
                attachments[0].aspectRatio.clamp(0.8, 16 / 9).toDouble();
            final height = width / aspect;
            return _buildQuotedMediaTile(
              media: attachments[0],
              width: width,
              height: height,
              dpr: dpr,
            );
          }

          // 2+ 枚は 16:9 のコンテナに割り付け
          final height = width * 9 / 16;
          final shown = count > 4 ? 4 : count;

          if (shown == 2) {
            final tileW = (width - gap) / 2;
            return Row(children: [
              _buildQuotedMediaTile(
                  media: attachments[0],
                  width: tileW,
                  height: height,
                  dpr: dpr),
              const SizedBox(width: gap),
              _buildQuotedMediaTile(
                  media: attachments[1],
                  width: tileW,
                  height: height,
                  dpr: dpr),
            ]);
          }

          if (shown == 3) {
            final tileW = (width - gap) / 2;
            final halfH = (height - gap) / 2;
            return Row(children: [
              _buildQuotedMediaTile(
                  media: attachments[0],
                  width: tileW,
                  height: height,
                  dpr: dpr),
              const SizedBox(width: gap),
              Column(children: [
                _buildQuotedMediaTile(
                    media: attachments[1],
                    width: tileW,
                    height: halfH,
                    dpr: dpr),
                const SizedBox(height: gap),
                _buildQuotedMediaTile(
                    media: attachments[2],
                    width: tileW,
                    height: halfH,
                    dpr: dpr),
              ]),
            ]);
          }

          // shown >= 4 → 2x2
          final tileW = (width - gap) / 2;
          final tileH = (height - gap) / 2;
          return Column(children: [
            Row(children: [
              _buildQuotedMediaTile(
                  media: attachments[0],
                  width: tileW,
                  height: tileH,
                  dpr: dpr),
              const SizedBox(width: gap),
              _buildQuotedMediaTile(
                  media: attachments[1],
                  width: tileW,
                  height: tileH,
                  dpr: dpr),
            ]),
            const SizedBox(height: gap),
            Row(children: [
              _buildQuotedMediaTile(
                  media: attachments[2],
                  width: tileW,
                  height: tileH,
                  dpr: dpr),
              const SizedBox(width: gap),
              _buildQuotedMediaTile(
                  media: attachments[3],
                  width: tileW,
                  height: tileH,
                  dpr: dpr),
            ]),
          ]);
        },
      ),
    );
  }

  /// 引用カード内の単一メディアタイルを構築。
  ///
  /// `_PostMediaGallery._buildMediaTile` のサムネ部分を引用カード用に縮小した
  /// もの。decode 解像度は元画像のアスペクト比を保ったまま、`BoxFit.cover` で
  /// box を覆える最小サイズで計算する。`memCacheWidth` と `memCacheHeight` を
  /// 両方指定したいが、両方をそのまま box サイズにすると Flutter の
  /// `ResizeImage` (デフォルト `policy: exact`) が元画像のアスペクト比を
  /// 無視して指定サイズに歪めて decode してしまうため、アスペクト比を
  /// 計算で保つ必要がある。
  Widget _buildQuotedMediaTile({
    required MediaAttachment media,
    required double width,
    required double height,
    required double dpr,
  }) {
    final aspect = media.aspectRatio;
    final boxAspect = width / height;
    final int cacheW;
    final int cacheH;
    if (aspect >= boxAspect) {
      // 画像が box より横長 → 高さで揃えて、幅は画像のアスペクト比から算出
      cacheH = (height * dpr).round();
      cacheW = (height * aspect * dpr).round();
    } else {
      // 画像が box より縦長 → 幅で揃えて、高さは画像のアスペクト比から算出
      cacheW = (width * dpr).round();
      cacheH = (width / aspect * dpr).round();
    }

    return SizedBox(
      width: width,
      height: height,
      child: KurageNetworkImage(
        imageUrl: media.previewUrl.isNotEmpty ? media.previewUrl : media.url,
        width: width,
        height: height,
        memCacheWidth: cacheW,
        memCacheHeight: cacheH,
        fit: BoxFit.cover,
        placeholder: (_, _) => Container(color: Colors.grey.shade200),
        errorWidget: (_, _, _) => Container(
          color: Colors.grey.shade200,
          child: Icon(
            Icons.broken_image,
            size: 20,
            color: Colors.grey.shade400,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final quotedStatus = widget.quotedStatus;
    final fontSize = widget.fontSize;
    final isCw = widget.isCw;
    final revealed = _revealed;
    // メディアを実寸で出すか:
    //   - CW あり: トグルで開いたときのみ
    //   - CW なし & sensitive (hideMedia=true): 出さない
    //   - それ以外: 普通に出す
    final showActualMedia = quotedStatus.mediaAttachments.isNotEmpty &&
        (isCw ? revealed : !widget.hideMedia);
    final showMediaPlaceholder = quotedStatus.mediaAttachments.isNotEmpty &&
        !showActualMedia;
    // 本文を出すか:
    //   - CW なし: 出す
    //   - CW あり & revealed: 出す
    //   - CW あり & 非 revealed: 出さない
    final showBody = quotedStatus.content.isNotEmpty &&
        (!isCw || revealed);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
      onTap: widget.onTap,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 引用ヘッダー
            Row(
              children: [
                KurageCircleAvatar(
                  imageUrl: quotedStatus.account.avatarUrl,
                  radius: fontSize * 0.8,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: isolateText(
                          textDirection: TextDirection.ltr,
                          // 引用カード全体がリンクなので RichText (非選択) を使う。
                          // Text.rich だと I-beam が MouseRegion(click) を上書きする。
                          child: RichText(
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textDirection: TextDirection.ltr,
                            text: TextSpan(children: widget.accountNameSpans),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          '@${quotedStatus.account.acct}',
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: fontSize * 0.8,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 4),
                      TimeText(
                        dt: quotedStatus.createdAt,
                        useRelative: widget.useRelativeTime,
                        style: TextStyle(
                          color: Colors.grey[600],
                          fontSize: fontSize * 0.7,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (isCw) ...[
              const SizedBox(height: 8),
              // CW ラベル
              isolateText(
                textDirection: TextDirection.ltr,
                child: Text.rich(
                  textDirection: TextDirection.ltr,
                  textScaler: TextScaler.noScaling,
                  TextSpan(
                    children: [
                      TextSpan(
                        text: 'CW: ',
                        style: TextStyle(
                          fontSize: fontSize * 0.9,
                          fontWeight: FontWeight.w600,
                          color: Colors.orange.shade700,
                        ),
                      ),
                      ...?widget.cwSpans,
                    ],
                  ),
                ),
              ),
              // 「表示」/「畳む」トグル。GestureDetector 子なので
              // 親カードの onTap には bubble しない (ジェスチャアリーナで
              // 内側勝ち)。
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _toggleReveal,
                  icon: Icon(
                    revealed ? Icons.visibility_off : Icons.visibility,
                    size: fontSize * 0.9,
                  ),
                  label: Text(
                    revealed
                        ? context.l10n.postCollapseAction
                        : context.l10n.postShowAction,
                    style: TextStyle(fontSize: fontSize * 0.8),
                  ),
                  style: TextButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
            ],
            if (showBody) ...[
              const SizedBox(height: 4),
              isolateText(
                textDirection: TextDirection.ltr,
                child: Text.rich(
                  TextSpan(children: widget.contentSpans),
                  textDirection: TextDirection.ltr,
                  textScaler: TextScaler.noScaling,
                ),
              ),
            ],
            if (showActualMedia) ...[
              const SizedBox(height: 8),
              // 引用カード内のサムネイル。メイン投稿の `_PostMediaGallery`
              // grid と同じレイアウト原則で、画像数に依らず常に 16:9 (1 枚は
              // 元画像のアスペクト比 0.8〜16:9 でクランプ) に揃える。旧実装の
              // 固定高さ 100px 方式は枚数が多いとタイル幅が小さくなって
              // 縦長帯になり、画像のほとんどがトリミングされて中身が読めない
              // 状態になっていた。
              _buildQuotedMediaGrid(quotedStatus),
            ] else if (showMediaPlaceholder) ...[
              // CW あり (非展開) または sensitive のときは件数だけ表示
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.image_outlined,
                      size: fontSize, color: Colors.grey[600]),
                  const SizedBox(width: 4),
                  Text(
                    context.l10n.postQuotedMediaCount(
                        quotedStatus.mediaAttachments.length),
                    style: TextStyle(
                      fontSize: fontSize * 0.8,
                      color: Colors.grey[600],
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      ),
    );
  }
}

/// 翻訳結果のカード。
class _TranslationResultBox extends StatelessWidget {
  final _TranslationData data;
  final List<InlineSpan> translatedSpans;
  final TextStyle defaultStyle;
  final Color linkColor;
  final int collapseAfterLines;

  /// CollapsibleText の展開状態を State 破棄を跨いで保持するキー。
  final String? collapseStateKey;
  final VoidCallback onClose;

  const _TranslationResultBox({
    required this.data,
    required this.translatedSpans,
    required this.defaultStyle,
    required this.linkColor,
    required this.collapseAfterLines,
    this.collapseStateKey,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ヘッダー
          Row(
            children: [
              Icon(
                Icons.translate,
                size: 16,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  context.l10n.postTranslationResult,
                  style: defaultStyle.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 16),
                onPressed: onClose,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                tooltip: context.l10n.postCloseTranslation,
              ),
            ],
          ),
          const SizedBox(height: 8),

          if (data.spoilerText != null && data.spoilerText!.isNotEmpty) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.orange.shade100,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                context.l10n.postCwTranslated(data.spoilerText!),
                style: defaultStyle.copyWith(
                  fontStyle: FontStyle.italic,
                  color: Colors.orange.shade800,
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],

          CollapsibleText(
            textSpans: translatedSpans,
            defaultStyle: defaultStyle,
            maxLines: collapseAfterLines,
            buttonColor: linkColor,
            textDirection: TextDirection.ltr,
            stateKey: collapseStateKey,
          ),

          const SizedBox(height: 8),

          Row(
            children: [
              if (data.detectedLanguage != null) ...[
                Text(
                  context.l10n.postDetectedLanguage(data.detectedLanguage!),
                  style: defaultStyle.copyWith(
                    fontSize: defaultStyle.fontSize! * 0.85,
                    color: Colors.grey[600],
                  ),
                ),
                const SizedBox(width: 12),
              ],
              if (data.provider != null)
                Text(
                  context.l10n.postTranslationProvider(data.provider!),
                  style: defaultStyle.copyWith(
                    fontSize: defaultStyle.fontSize! * 0.85,
                    color: Colors.grey[600],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 翻訳結果のスナップショット。`ValueNotifier<_TranslationData?>` に載せて
/// 翻訳完了 / 翻訳閉じるトグルを subtitle 領域だけの再描画に閉じ込める。
class _TranslationData {
  final String content;
  final String? spoilerText;
  final String? detectedLanguage;
  final String? provider;

  const _TranslationData({
    required this.content,
    required this.spoilerText,
    required this.detectedLanguage,
    required this.provider,
  });
}

/// `_PostTileState._spanCache` の値型。
///
/// 過去版では `dispose()` を持って recognizer を即時解放していたが、現行は
/// 静的 LRU キャッシュなので複数 tile が同一エントリの spans を共有しうる。
/// 即時 dispose は use-after-free のリスクがあるため、参照を捨てるだけにし
/// recognizer は widget tree から外れた時点で GC に任せる方針 (`_spanCache`
/// 宣言コメント参照)。`_disposeSpanRecursively` は現在未使用だが、将来的に
/// 明示 dispose が必要になった場合のため残置。
class _ParsedSpansEntry {
  final String signature;
  final List<InlineSpan> spans;

  _ParsedSpansEntry(this.signature, this.spans);
}