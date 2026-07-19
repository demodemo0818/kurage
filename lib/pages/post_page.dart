// lib/pages/post_page.dart

import 'dart:async';
import 'dart:io' show File;
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // LogicalKeyboardKey (Ctrl+Enter 投稿)
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_selector/file_selector.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';

import '../l10n/l10n.dart';
import '../models/draft.dart';
import '../models/poll.dart';
import '../models/live_mode.dart';
import '../models/account.dart';
import '../models/media_attachment.dart';
import '../models/status.dart';
import '../services/analytics_service.dart';
import '../services/mastodon_api.dart';
import '../services/sound_service.dart';
import '../services/local_post_bus.dart';
import '../services/local_status_event_bus.dart';
import '../services/clipboard_image.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/snackbar_helpers.dart';
import '../utils/open_profile.dart'; // openDeckPage (Deck ではポップアップ表示)
import '../widgets/emoji_picker.dart';
import '../widgets/live_mode_settings_dialog.dart';
import '../widgets/user_avatar.dart';
import 'drafts_page.dart';
import 'scheduled_posts_page.dart';

/// メディアアイテム。
///
/// `file` がある = ローカルから新規にアップロードしたメディア。
/// `file` が null かつ `remotePreviewUrl` がある = 編集対象投稿が元から
/// 持っていたサーバ既存メディア (再アップロードはしない、そのまま
/// `mediaIdsByAccount` 内の id を `media_ids[]` に流して維持する用途)。
///
/// `mediaIdsByAccount` は「このメディアが投稿される可能性のあるアカウント
/// ごとに、そのインスタンスで割り当てられた media_id」のマップ。Mastodon
/// の `/api/v2/media` で返ってくる id は **発行インスタンス固有** なので、
/// クロスポストで A・B 二つのアカウントに同じファイルを添付するなら、
/// それぞれのインスタンスに別々に upload してそれぞれの id を保持する必要が
/// ある。これを単一 `mediaId` で持っていた旧設計だと、別インスタンスでは
/// 「そんな id 知らない」と 422 で投稿失敗していた (= クロスポスト時画像
/// 添付で片方失敗バグの原因)。
class MediaItem {
  /// 新規アップロードしたメディアの参照 (XFile)。
  ///
  /// `dart:io File` ではなく `cross_file XFile` を使うのは、Web ビルドで
  /// `XFile.path` が `blob:` URL になり `dart:io File` の readAsBytes /
  /// fromPath が機能しないため。XFile は mobile/desktop/web 全てで
  /// readAsBytes が動く統一抽象。
  final XFile? file;

  /// アカウント id → そのインスタンスで発行された media_id のマップ。
  /// アップロード完了後に追加するだけで、ライフサイクル中に key の削除は
  /// しない (= アカウント選択を外しても他のメディアと整合性を取るため
  /// 残す)。`final Map` で参照は固定、`[]=` で要素は追加可能。
  final Map<String, String> mediaIdsByAccount;

  final String? remotePreviewUrl;

  /// メモリ上のバイト列から作ったメディア (クリップボード貼り付け等) のプレ
  /// ビュー用バイト列。`XFile.fromData` は io 実装だと `path` が実ファイルでは
  /// なく `data:` URI になるため `Image.file(File(path))` で読めず、プレビュー
  /// が壊れる。そこで元バイト列をここに保持して `Image.memory` で描画する。
  /// 通常のファイル選択 (実 path あり) では null。
  final Uint8List? localBytes;

  String altText;

  MediaItem({
    this.file,
    required this.mediaIdsByAccount,
    this.remotePreviewUrl,
    this.localBytes,
    this.altText = '',
  });

  /// UI の `ValueKey` 等に使う安定 ID。`mediaIdsByAccount` は最初の
  /// アップロード完了で 1 件目が決まったら以降は追加されるだけで、
  /// `values.first` は不変なのでこれを ValueKey に使っても rebuild で
  /// identity が動かない。
  String get keyId => mediaIdsByAccount.values.first;
}

/// 投稿画面（新規 or 返信）
/// PopScope の確認ダイアログでユーザーが選んだ離脱方針。
enum _LeaveAction {
  /// ダイアログを閉じてそのまま編集を続ける
  cancel,

  /// 画面を閉じる。本文は dispose 時に下書きとして自動保存される
  /// (添付メディアや予約日時は破棄される)。
  leaveKeepDraft,

  /// 編集中の内容を全て破棄してから画面を閉じる。
  discard,
}

class PostPage extends ConsumerStatefulWidget {
  final String? replyToStatusId;
  final String? replyToUsername;
  final String? replyToVisibility;
  final String? initialText; // ハッシュタグ投稿用の初期テキスト
  final String? initialVisibility; // 編集・下書き復元用の初期公開範囲
  final String? initialSpoilerText; // 「削除して下書きに戻す」用の CW 文字列
  final bool? initialSensitive; // 「削除して下書きに戻す」用の NSFW フラグ
  final String? initialLanguage; // 「削除して下書きに戻す」用の投稿言語
  final Poll? initialPoll; // 「削除して下書きに戻す」用の投票復元
  final List<MediaAttachment>? initialMediaAttachments; // 「削除して下書きに戻す」用の添付メディア
  final String? initialMediaAccountId; // initialMediaAttachments の元アカウント id (= 元投稿者)
  final List<String>? initialAccountIds; // カラムから渡されるアカウントID
  final Status? quotedStatus; // Mastodon 4.4+ 公式引用用 (引用元投稿)

  /// 投稿編集モードで使う対象 status の id。null なら新規投稿。
  ///
  /// non-null のときは [editTargetStatus] と [editAccountId] が共に必要。
  /// 編集モードでは visibility / 添付の差し替え以外の変更不可フィールド
  /// (返信先 / 引用先 / 予約日時) は編集 UI から操作不可になる。
  final String? editStatusId;

  /// 編集対象 status 本体。CW / sensitive / language / 投票 / メディア の
  /// 復元に使う。本文は別途 [getStatusSource] で取得して [initialText] に
  /// 渡してもらう (HTML ではなく source の text プロパティが要るため)。
  final Status? editTargetStatus;

  /// 編集を実行するアカウント id (= 投稿主のアカウント)。編集モードでは
  /// アカウント切り替えはできないのでこの 1 つに固定する。
  final String? editAccountId;

  /// TweetDeck 風の横ペインに埋め込まれて表示されているか。
  ///
  /// `true` のとき:
  ///  - ルートの `PopScope` (未保存確認) を張らない (ページ遷移ではないため)
  ///  - AppBar の戻る矢印の代わりにピン留め (固定表示) トグルを出す (開閉は
  ///    ホスト側のペン (投稿) ボタンで行うので閉じる × は出さない)
  ///  - 投稿成功時に `Navigator.pop` せず [onPosted] を呼ぶ (フォームはその場で
  ///    クリア済みなので、ピン留め中はそのまま次の投稿を書ける)
  /// 埋め込みは [embedded] 以外のフィールド (返信/引用/初期テキスト等) と
  /// 組み合わせて使える。編集 (`editStatusId`) との併用は想定しない。
  final bool embedded;

  /// 埋め込み時、投稿成功後に呼ばれる。ホストが「ピン留めなら維持 / 非ピンなら
  /// 閉じる」を決める。
  final VoidCallback? onPosted;

  /// 埋め込み時、現在ピン留め (固定表示) 中か。AppBar のピンアイコン表示用。
  final bool pinned;

  /// 埋め込み時、ピン留めトグルが押されたとき呼ばれる。
  final VoidCallback? onTogglePin;

  /// 埋め込みの編集モード時、「編集をやめて新規投稿に戻る」が押されたとき
  /// 呼ばれる。ホストがペインを新規コンポーズへ戻す。ピン固定中で編集モードから
  /// 抜ける唯一の導線なので、編集中 (embedded && isEditing) は必ず出す。
  final VoidCallback? onCancelEdit;

  /// true のとき退避下書き (`post_temp_draft`) を復元せず、既存の退避下書きも
  /// 削除して完全にまっさらな状態で開く。Deck ペインで「(返信等を) 破棄して
  /// 新規投稿」を選んだときに使う。破棄された旧 PostPage の dispose 保存が
  /// 書いた下書きを確実に無効化するため、削除は post-frame (旧 State の
  /// dispose = フレーム末の finalizeTree より後) に行う。
  final bool discardTempDraft;

  const PostPage({
    super.key,
    this.replyToStatusId,
    this.replyToUsername,
    this.replyToVisibility,
    this.initialText,
    this.initialVisibility,
    this.initialSpoilerText,
    this.initialSensitive,
    this.initialLanguage,
    this.initialPoll,
    this.initialMediaAttachments,
    this.initialMediaAccountId,
    this.initialAccountIds,
    this.quotedStatus,
    this.editStatusId,
    this.editTargetStatus,
    this.editAccountId,
    this.embedded = false,
    this.onPosted,
    this.pinned = false,
    this.onTogglePin,
    this.onCancelEdit,
    this.discardTempDraft = false,
  });

  /// 編集モードかどうか
  bool get isEditing => editStatusId != null;

  @override
  ConsumerState<PostPage> createState() => _PostPageState();
}

class _PostPageState extends ConsumerState<PostPage> {
  final TextEditingController _controller = TextEditingController();

  /// `_setInitialText()` が initState で自動挿入したプリフィル本文
  /// (返信の `@ユーザー名 ` / ハッシュタグ等。無ければ空文字)。
  /// dispose の `_saveTempDraft` が「手つかずのプリフィル」を退避下書きに
  /// 書かないための比較基準。
  String _initialPrefillBody = '';

  final FocusNode _textFocusNode = FocusNode();
  int _maxChars = 500;
  // 残り文字数は毎キーストロークで更新されるため、setState ではなく
  // ValueNotifier + ValueListenableBuilder で「カウンタ表示部分だけ」が
  // rebuild するようにする。これで本文編集中の post_page 全体 (2500+ 行) の
  // rebuild を防げる。
  final ValueNotifier<int> _remaining = ValueNotifier<int>(500);
  String _visibility = 'public';

  // ユーザーが公開範囲メニューで手動変更したか。true の間はサーバ側
  // デフォルト (posting:default:visibility) の自動適用をスキップする
  // (アカウント切替で選択が上書きされると迷惑なため)。
  bool _visibilityManuallySet = false;

  // CW。TextField に controller でバインドしているので、編集モードで既存の
  // 警告文を復元する際は `_spoilerController.text = ...` で書き戻すこと
  // (旧実装の `String _spoilerText` だと TextField 側に反映されなかった)。
  final TextEditingController _spoilerController = TextEditingController();
  bool _showSpoilerField = false;

  // メディア
  final List<MediaItem> _mediaItems = [];
  bool _isUploading = false;
  bool _isPosting = false;
  // Web / デスクトップでファイルをドラッグ中か (ドロップ受付ハイライト用)。
  bool _isDragging = false;
  // Web の paste イベント購読解除関数 (initState で登録、dispose で呼ぶ)。
  // Desktop/モバイルでは listenPasteImages が no-op を返すので null にはならない
  // が呼んでも無害。
  void Function()? _pasteListenerDispose;
  bool _isNSFW = false;

  // 選択中のアカウント（複数選択対応）
  Set<String> _selectedAccountIds = {};

  // 投票関連
  bool _showPollCreation = false;
  final List<TextEditingController> _pollOptionControllers = [];
  int _pollDuration = 86400; // 1日（秒）
  bool _pollMultiple = false;

  // 言語設定
  String? _language;

  // 予約投稿設定
  DateTime? _scheduledAt;
  bool _showScheduledPost = false;

  // 絵文字ピッカー設定
  bool _showEmojiPicker = false;

  // 実況モード設定
  LiveModeSettings _liveModeSettings = const LiveModeSettings();

  // 引用元投稿 (Mastodon 4.4+ 公式引用)。設定時に投稿時 quoted_status_id を送る
  Status? _quotedStatus;
  // 引用プレビューに表示するプレーン本文。HTML タグ除去や entity 置換は
  // 毎 build で行うと無駄なので _quotedStatus を設定したタイミングで一度だけ
  // 計算してキャッシュする。
  String _quotedStatusPlain = '';

  // 引用プレビュー用の HTML→プレーンテキスト変換正規表現。class field で
  // 一度だけコンパイルする (build / setter で毎回 RegExp() しない)。
  static final RegExp _htmlBrRe = RegExp(r'<br\s*/?>', caseSensitive: false);
  static final RegExp _htmlClosePRe = RegExp(r'</p>', caseSensitive: false);
  static final RegExp _htmlTagRe = RegExp(r'<[^>]*>');

  String _toPlainContent(String html) {
    return html
        .replaceAll(_htmlBrRe, '\n')
        .replaceAll(_htmlClosePRe, '\n')
        .replaceAll(_htmlTagRe, '')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .trim();
  }

  void _setQuotedStatus(Status? s) {
    _quotedStatus = s;
    _quotedStatusPlain = s == null ? '' : _toPlainContent(s.content);
  }

  // オートコンプリート関連
  List<Account> _userSuggestions = [];
  List<String> _hashtagSuggestions = [];
  bool _showSuggestions = false;
  String _currentSuggestionType = ''; // '@' or '#'

  @override
  void initState() {
    super.initState();
    _setQuotedStatus(widget.quotedStatus);
    // 返信元の公開範囲を初期公開範囲としてセット
    if (widget.replyToVisibility != null) {
      _visibility = widget.replyToVisibility!;
    }
    // 編集・下書き復元時の公開範囲をセット
    if (widget.initialVisibility != null) {
      _visibility = widget.initialVisibility!;
    }
    // 「削除して下書きに戻す」フローからの CW / NSFW 復元 (編集モード時は
    // _restoreFromEditTarget が後から上書きする想定なので問題なし)。言語は
    // 下の postFrameCallback で initialLanguage を吸い取って反映する。
    if (widget.initialSpoilerText != null &&
        widget.initialSpoilerText!.isNotEmpty) {
      _spoilerController.text = widget.initialSpoilerText!;
      _showSpoilerField = true;
    }
    if (widget.initialSensitive != null) {
      _isNSFW = widget.initialSensitive!;
    }

    _controller.addListener(_onTextChanged);
    _textFocusNode.addListener(_onFocusChanged);

    // 初期テキストの設定（ハッシュタグ投稿用、メンション返信用）
    _setInitialText();
    // プリフィル (返信の @メンション / ハッシュタグ) をこの時点で記録する。
    // dispose の _saveTempDraft が「ユーザーが手を付けていないプリフィル」を
    // 退避下書きへ書いてしまわないための比較基準 (該当ガードの doc 参照)。
    _initialPrefillBody = _controller.text;

    // 編集モードのときは下書きや予約日時を復元しない (元投稿の状態を尊重する)。
    // 投票選択肢の初期 2 つも追加しない (編集対象に poll があれば後で復元)。
    if (widget.isEditing) {
      _restoreFromEditTarget();
    } else if (widget.discardTempDraft) {
      // 「破棄して新規投稿」: 退避下書きを復元せず、破棄された旧 PostPage の
      // dispose 保存が書いた分ごと削除する。旧 State の dispose はフレーム末
      // (finalizeTree) に走るので、その後に消えるよう post-frame に遅らせる。
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final prefs = await SharedPreferences.getInstance();
        await _removeAllTempKeys(prefs);
      });
      _addPollOption();
      _addPollOption();
    } else {
      // _loadTempDraft が本文・CW・投票・予約日時をまとめて復元する
      // (予約日時も退避下書きの一部なので新規投稿のときだけ復元される)。
      _loadTempDraft();
      // redraft からの投票復元。あれば 2 つのデフォルト挿入をスキップして
      // 元の選択肢構成 / 複数選択 / 期限を引き継ぐ (期限切れなら 1 日に
      // フォールバック)。
      if (widget.initialPoll != null) {
        _restoreInitialPoll(widget.initialPoll!);
      } else {
        // 投票選択肢のデフォルト設定 (新規投稿のみ)
        _addPollOption();
        _addPollOption();
      }
      // redraft からの添付メディア復元。リモート参照モード (`file: null`) で
      // 元投稿者のアカウント id に紐づける。アカウントを切り替えると
      // _submit pre-flight で「未アップロード + file なし」例外になるが、
      // 同じ投稿の再下書きで投稿者を変えるのは通常想定外なので許容。
      if (widget.initialMediaAttachments != null &&
          widget.initialMediaAccountId != null) {
        for (final media in widget.initialMediaAttachments!) {
          _mediaItems.add(MediaItem(
            mediaIdsByAccount: {widget.initialMediaAccountId!: media.id},
            remotePreviewUrl: media.previewUrl.isNotEmpty
                ? media.previewUrl
                : media.url,
            altText: media.description ?? '',
          ));
        }
      }
    }
    _loadLiveModeSettings();
    _initInstanceConfig();

    // Web: ブラウザの paste イベントを購読して、本文フォーカス中の Ctrl/Cmd+V
    // (やコンテキストメニューの貼り付け) でクリップボードの画像を添付する。
    // Desktop は paste イベントが無いので listenPasteImages は no-op を返し、
    // 代わりに本文 TextField を包む Focus.onKeyEvent (Ctrl/Cmd+V) で pull する。
    if (kIsWeb) {
      _pasteListenerDispose = listenPasteImages(
        shouldAccept: _shouldAcceptPaste,
        onImages: _handleClipboardImages,
      );
    }

    // デフォルトの投稿アカウントを設定
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final auth = ref.read(authProvider);
      final settings = ref.read(settingsProvider);

      if (widget.isEditing) {
        // 編集モードでは投稿主アカウントに固定 + 言語は元投稿のものを尊重
        final id = widget.editAccountId;
        if (id != null && auth.accounts.any((a) => a.id == id)) {
          setState(() {
            _selectedAccountIds = {id};
            _language = widget.editTargetStatus?.language ??
                settings.defaultPostLanguage;
          });
        }
        _updateMaxCharsForSelectedAccount();
        return;
      }

      // 言語の初期値: redraft 復元 > グローバル設定の default
      setState(() {
        _language = widget.initialLanguage ?? settings.defaultPostLanguage;
      });

      // 優先順位: initialAccountIds (カラム由来) > 前回投稿アカウント
      // (SharedPreferences) > accounts.first
      Set<String>? resolved;
      if (widget.initialAccountIds != null &&
          widget.initialAccountIds!.isNotEmpty) {
        resolved = Set<String>.from(widget.initialAccountIds!);
      } else {
        final lastUsed = await _loadLastUsedAccountIds();
        // 削除済みアカウントを除外
        final validIds = lastUsed
            .where((id) => auth.accounts.any((a) => a.id == id))
            .toSet();
        if (validIds.isNotEmpty) {
          resolved = validIds;
        } else if (auth.accounts.isNotEmpty) {
          resolved = {auth.accounts.first.id};
        }
      }
      if (resolved != null && mounted) {
        setState(() {
          _selectedAccountIds = resolved!;
        });
      }

      // 選択されたアカウントの文字数制限を更新
      _updateMaxCharsForSelectedAccount();
      // サーバ側デフォルト公開範囲を適用 (返信・redraft 復元時は no-op)
      _applyDefaultVisibilityFromPreferences();
    });
  }

  /// 編集対象 status から CW / sensitive / メディア / 投票 を復元する。
  ///
  /// - 本文は `widget.initialText` 経由で渡してもらう想定 (HTML ではなく
  ///   `getStatusSource` で取得した text を使うため)。
  /// - 言語は postFrameCallback 内で `editTargetStatus.language` を反映。
  /// - メディアは `MediaItem` をリモート参照モードで作る (`file: null` +
  ///   `remotePreviewUrl`)。再アップロードはしない。
  /// - 投票は元の `expiresAt` から残り秒数を計算 (= 編集すると有効期限が
  ///   いったんリセットされる Mastodon 仕様に合わせる)。
  void _restoreFromEditTarget() {
    final s = widget.editTargetStatus;
    if (s == null) return;

    if (s.spoilerText.isNotEmpty) {
      _spoilerController.text = s.spoilerText;
      _showSpoilerField = true;
    }
    _isNSFW = s.sensitive;
    _visibility = s.visibility; // UI 上はロックする (Mastodon API で変更不可)

    // 編集モードは編集対象アカウント (= 1 つ) でしか操作できないので、
    // 既存メディアの id はそのアカウントの id に紐づけて記録する。
    final editAccountId = widget.editAccountId;
    for (final media in s.mediaAttachments) {
      _mediaItems.add(MediaItem(
        mediaIdsByAccount: editAccountId != null
            ? {editAccountId: media.id}
            // editAccountId が null は通常起きないが safety として
            // 「特定アカウントに紐づかない」プレースホルダ key を使う。
            // _submit には到達しない (= 編集モードのコードパスから外れる)
            // のでこの値は実質読まれない。
            : {'__edit_placeholder__': media.id},
        remotePreviewUrl:
            media.previewUrl.isNotEmpty ? media.previewUrl : media.url,
        altText: media.description ?? '',
      ));
    }

    final poll = s.poll;
    if (poll != null) {
      _restoreInitialPoll(poll);
    }
  }

  /// `Poll` から `_showPollCreation` / `_pollMultiple` / `_pollDuration` /
  /// `_pollOptionControllers` を埋める。編集モード ([_restoreFromEditTarget])
  /// と「削除して下書きに戻す」復元の両方から呼ばれる共通ロジック。
  /// 期限切れの poll は 1 日 (86400s) にフォールバック (= Mastodon の編集仕様に
  /// 合わせて新しい期限が必須)。
  void _restoreInitialPoll(Poll poll) {
    _showPollCreation = true;
    _pollMultiple = poll.multiple;
    // expiresAt は nullable (無期限投票)。null は期限切れ扱いで 1 日に倒す
    final remaining =
        poll.expiresAt?.difference(DateTime.now()).inSeconds ?? 0;
    _pollDuration = remaining > 60 ? remaining : 86400;
    for (final option in poll.options) {
      final c = TextEditingController(text: option.title);
      c.addListener(_onTextChanged);
      _pollOptionControllers.add(c);
    }
    // 既存選択肢が 2 未満なら 2 つになるよう補完 (UI で消せる)
    while (_pollOptionControllers.length < 2) {
      _addPollOption();
    }
  }

  void _setInitialText() {
    String initialText = '';

    // ハッシュタグ投稿の場合
    if (widget.initialText != null) {
      initialText = widget.initialText!;
    }
    // 返信の場合
    else if (widget.replyToUsername != null) {
      initialText = '@${widget.replyToUsername} ';
    }

    if (initialText.isNotEmpty) {
      _controller.text = initialText;
      _controller.selection = TextSelection.collapsed(
        offset: initialText.length,
      );
    }
  }

  void _onTextChanged() {
    int textLength = _controller.text.length;

    // 実況モードが有効な場合はハッシュタグの文字数も考慮
    if (_liveModeSettings.isEnabled &&
        _liveModeSettings.hashtags.isNotEmpty) {
      textLength += _liveModeSettings.hashtagString.length;
    }

    // ValueNotifier の更新は ListenableBuilder 側でだけ rebuild が走る。
    // setState を呼ばないことで post_page 全体の rebuild を回避する。
    _remaining.value = _maxChars - textLength;

    // オートコンプリート機能
    _checkForSuggestions();
  }

  // RegExp は build/listener で毎回生成すると無駄なので class field に。
  static final RegExp _suggestionAtRe = RegExp(r'@(\w*)$');
  static final RegExp _suggestionHashRe = RegExp(r'#(\w*)$');
  static final RegExp _replaceAtRe = RegExp(r'@\w*$');
  static final RegExp _replaceHashRe = RegExp(r'#\w*$');

  void _checkForSuggestions() {
    final text = _controller.text;
    final cursorPos = _controller.selection.baseOffset;

    if (cursorPos < 0 || cursorPos > text.length) return;

    // カーソル位置より前のテキストを解析
    final beforeCursor = text.substring(0, cursorPos);

    // @マーク検索
    final atMatch = _suggestionAtRe.firstMatch(beforeCursor);
    if (atMatch != null) {
      final query = atMatch.group(1) ?? '';
      if (query.isNotEmpty) {
        _scheduleSearch(query, '@');
        return;
      }
    }

    // #マーク検索
    final hashMatch = _suggestionHashRe.firstMatch(beforeCursor);
    if (hashMatch != null) {
      final query = hashMatch.group(1) ?? '';
      if (query.isNotEmpty) {
        _scheduleSearch(query, '#');
        return;
      }
    }

    // 候補を非表示。表示中だったときだけ rebuild する (毎キーストロークで
    // 不要な setState を回避)。
    _suggestionDebounce?.cancel();
    if (_showSuggestions) {
      setState(() {
        _showSuggestions = false;
      });
    }
  }

  /// オートコンプリート用 debounce タイマー。連続入力中に毎回 API を
  /// 叩かないよう、最後の入力から 350ms 待って実行する。
  Timer? _suggestionDebounce;
  static const _suggestionDebounceDuration = Duration(milliseconds: 350);

  void _scheduleSearch(String query, String type) {
    _suggestionDebounce?.cancel();
    _suggestionDebounce = Timer(_suggestionDebounceDuration, () {
      if (!mounted) return;
      if (type == '@') {
        _searchUsers(query);
      } else {
        _searchHashtags(query);
      }
    });
  }

  Future<void> _searchUsers(String query) async {
    if (_selectedAccountIds.isEmpty) return;
    
    final firstAccountId = _selectedAccountIds.first;
    final authState = ref.read(authProvider);
    final account = authState.accounts.firstWhere(
      (a) => a.id == firstAccountId,
      orElse: () => authState.accounts.first,
    );
    
    try {
      final results = await searchAccounts(
        instanceUrl: account.instanceUrl,
        accessToken: account.accessToken,
        query: query,
        limit: 5,
      );
      if (!mounted) return;

      setState(() {
        _userSuggestions = results;
        _hashtagSuggestions = [];
        _currentSuggestionType = '@';
        _showSuggestions = results.isNotEmpty;
      });
    } catch (e) {
      debugPrint('Error searching users: $e');
      // 失敗時は前回クエリの候補を出しっぱなしにしない
      if (mounted) {
        setState(() => _showSuggestions = false);
      }
    }
  }

  Future<void> _searchHashtags(String query) async {
    if (_selectedAccountIds.isEmpty) return;
    
    final firstAccountId = _selectedAccountIds.first;
    final authState = ref.read(authProvider);
    final account = authState.accounts.firstWhere(
      (a) => a.id == firstAccountId,
      orElse: () => authState.accounts.first,
    );
    
    try {
      final results = await searchHashtags(
        instanceUrl: account.instanceUrl,
        accessToken: account.accessToken,
        query: query,
        limit: 5,
      );
      if (!mounted) return;

      setState(() {
        _hashtagSuggestions = results;
        _userSuggestions = [];
        _currentSuggestionType = '#';
        _showSuggestions = results.isNotEmpty;
      });
    } catch (e) {
      debugPrint('Error searching hashtags: $e');
      // 失敗時は前回クエリの候補を出しっぱなしにしない
      if (mounted) {
        setState(() => _showSuggestions = false);
      }
    }
  }

  void _insertSuggestion(String suggestion) {
    final text = _controller.text;
    final cursorPos = _controller.selection.baseOffset;
    
    if (cursorPos < 0 || cursorPos > text.length) return;
    
    final beforeCursor = text.substring(0, cursorPos);
    final afterCursor = text.substring(cursorPos);
    
    String newBeforeCursor;
    if (_currentSuggestionType == '@') {
      newBeforeCursor = beforeCursor.replaceAll(_replaceAtRe, '@$suggestion ');
    } else {
      newBeforeCursor = beforeCursor.replaceAll(_replaceHashRe, '#$suggestion ');
    }
    
    final newText = newBeforeCursor + afterCursor;
    final newCursorPos = newBeforeCursor.length;
    
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursorPos),
    );
    
    setState(() {
      _showSuggestions = false;
    });
  }

  void _onFocusChanged() {
    // フォーカス変更時の処理（現在は特になし）
  }

  Future<void> _initInstanceConfig() async {
    // 初期化時は_selectedAccountIdsがまだ空の可能性があるため、
    // addPostFrameCallbackで処理する
  }

  /// _maxChars が「どのインスタンス」の制限から決まったか。複数アカウント
  /// 投稿時に、ユーザーがどのアカウントが文字数制限の根拠かを判別できるよう
  /// にする。null の場合は表示なし (デフォルト 500 を使っているとき等)。
  String? _maxCharsSourceInstanceHost;

  /// 選択されたアカウントの最大文字数を更新（最も厳しい制限を適用）
  Future<void> _updateMaxCharsForSelectedAccount() async {
    final authState = ref.read(authProvider);
    if (_selectedAccountIds.isEmpty) {
      // アカウントが選択されていない場合はデフォルト値を使用
      if (mounted) {
        setState(() {
          _maxChars = 500;
          _maxCharsSourceInstanceHost = null;
        });
        _remaining.value = _maxChars - _controller.text.length;
      }
      return;
    }

    int minMaxChars = 999999;
    String? sourceHost;

    // 各アカウントの instance config を並列に取得する。逐次 await だと
    // 未キャッシュのインスタンスが N 個あるとき N × RTT 待たされる
    // (fetchInstanceConfig は in-memory キャッシュ持ちなので 2 回目以降は即時)。
    final accounts = _selectedAccountIds
        .map((accountId) => authState.accounts.firstWhere(
              (a) => a.id == accountId,
              orElse: () => authState.accounts.first,
            ))
        .toList();
    final results = await Future.wait(accounts.map((acct) async {
      try {
        final cfg = await fetchInstanceConfig(
          instanceUrl: acct.instanceUrl,
          accessToken: acct.accessToken,
        );
        return (acct: acct, maxChars: cfg.maxTootChars);
      } catch (e) {
        debugPrint('Error fetching instance config: $e');
        // エラー時はデフォルト値を使用
        return (acct: acct, maxChars: 500);
      }
    }));

    for (final r in results) {
      if (r.maxChars < minMaxChars) {
        minMaxChars = r.maxChars;
        sourceHost = Uri.tryParse(r.acct.instanceUrl)?.host;
      }
    }

    if (mounted) {
      setState(() {
        _maxChars = minMaxChars == 999999 ? 500 : minMaxChars;
        // 単一アカウントの場合は host 表示しなくて良い (誰が制限してるかは自明)。
        _maxCharsSourceInstanceHost =
            _selectedAccountIds.length > 1 ? sourceHost : null;
      });
      // 文字数制限変更後に再計算
      _onTextChanged();
    }
  }

  /// visibility の「狭さ」。複数アカウント選択時に最も狭いものを採用する
  /// ための順序 (public < unlisted < private < direct)。
  static const _visibilityNarrowness = {
    'public': 0,
    'unlisted': 1,
    'private': 2,
    'direct': 3,
  };

  /// 選択アカウントのサーバ側デフォルト公開範囲 (`posting:default:visibility`)
  /// を `_visibility` に適用する。返信・編集・下書き/redraft 復元・ユーザー
  /// 手動変更のときは何もしない (それらの値を優先する)。複数アカウント選択時
  /// は各アカウントのデフォルトのうち最も狭い公開範囲を採用する (意図しない
  /// 過剰公開を防ぐ)。取得失敗したアカウントは無視し、全滅なら現状維持。
  Future<void> _applyDefaultVisibilityFromPreferences() async {
    if (widget.isEditing ||
        widget.replyToVisibility != null ||
        widget.initialVisibility != null ||
        _visibilityManuallySet) {
      return;
    }
    final authState = ref.read(authProvider);
    if (_selectedAccountIds.isEmpty || authState.accounts.isEmpty) return;

    // fetchPreferences は in-memory キャッシュ持ちなので 2 回目以降は即時。
    final accounts = _selectedAccountIds
        .map((accountId) => authState.accounts.firstWhere(
              (a) => a.id == accountId,
              orElse: () => authState.accounts.first,
            ))
        .toList();
    final results = await Future.wait(accounts.map((acct) async {
      try {
        final prefs = await fetchPreferences(
          instanceUrl: acct.instanceUrl,
          accessToken: acct.accessToken,
        );
        return prefs.defaultVisibility;
      } catch (e) {
        debugPrint('Error fetching preferences: $e');
        return null;
      }
    }));

    String? narrowest;
    for (final v in results) {
      if (v == null || !_visibilityNarrowness.containsKey(v)) continue;
      if (narrowest == null ||
          _visibilityNarrowness[v]! > _visibilityNarrowness[narrowest]!) {
        narrowest = v;
      }
    }
    if (narrowest == null) return;

    // await 中にユーザーが手動変更したら尊重する
    if (!mounted || _visibilityManuallySet) return;
    if (_visibility == narrowest) return;
    setState(() {
      _visibility = narrowest!;
    });
  }

  /// 自動退避した一時下書きの保存先。本文 / CW / 投票 / 予約日時を 1 つの JSON
  /// にまとめて持つ。**単一キー・単一 setString で all-or-nothing** にするのが
  /// 肝心: 旧実装は項目ごとに別キーへ `await` 直列で書いていたため、(1) 端末が
  /// アプリを kill した際に本文 (先に書く) だけ disk に flush され CW/投票/予約
  /// (後で書く) が失われる、(2) 閉じる→即再オープン (横ペインの ValueKey 再生成
  /// 含む) で旧の dispose 保存と新の init 読込が競合し「本文だけ書き終えた中間
  /// 状態」を読込が観測する、という不整合 (= 報告された「本文は残るが CW/投票/
  /// 予約が保持されたりされなかったり」) が起きていた。
  static const _kTempDraftKey = 'post_temp_draft';

  Future<void> _loadTempDraft() async {
    // 初期テキストや返信先が指定されている起動は別目的なので、退避下書き
    // (本文・CW・投票・予約日時) を一切読み込まない。
    if (widget.initialText != null || widget.replyToUsername != null) return;

    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    String body = '';
    String spoiler = '';
    List<String>? pollOptions;
    bool pollMultiple = false;
    int pollDuration = 86400;
    String? scheduledIso;

    final blob = prefs.getString(_kTempDraftKey);
    if (blob != null && blob.isNotEmpty) {
      try {
        final m = jsonDecode(blob) as Map<String, dynamic>;
        body = m['body'] as String? ?? '';
        spoiler = m['spoiler'] as String? ?? '';
        final poll = m['poll'] as Map<String, dynamic>?;
        if (poll != null) {
          pollOptions =
              (poll['options'] as List?)?.map((e) => e.toString()).toList() ??
                  const <String>[];
          pollMultiple = poll['multiple'] as bool? ?? false;
          pollDuration = poll['duration'] as int? ?? 86400;
        }
        scheduledIso = m['scheduledAt'] as String?;
      } catch (_) {
        await prefs.remove(_kTempDraftKey);
      }
    } else {
      // 旧形式 (キー分割) の後方互換読み込み。次の dispose 保存で新形式へ
      // 移行し、旧キーは _removeLegacyTempKeys で掃除される。
      body = prefs.getString('post_temp') ?? '';
      spoiler = prefs.getString('post_temp_spoiler') ?? '';
      final pollRaw = prefs.getString('post_temp_poll');
      if (pollRaw != null && pollRaw.isNotEmpty) {
        try {
          final m = jsonDecode(pollRaw) as Map<String, dynamic>;
          pollOptions =
              (m['options'] as List?)?.map((e) => e.toString()).toList() ??
                  const <String>[];
          pollMultiple = m['multiple'] as bool? ?? false;
          pollDuration = m['duration'] as int? ?? 86400;
        } catch (_) {
          await prefs.remove('post_temp_poll');
        }
      }
      scheduledIso = prefs.getString('post_temp_scheduled_at');
    }

    if (!mounted) return;

    if (body.isNotEmpty) {
      _controller.text = body;
      _controller.selection = TextSelection.collapsed(offset: body.length);
    }
    // CW のフィールド表示切替を伴うので setState (本文は controller のリスナ
    // 経由で反映されるが、_showSpoilerField は素の bool なので setState 必須)。
    if (spoiler.isNotEmpty) {
      setState(() {
        _spoilerController.text = spoiler;
        _showSpoilerField = true;
      });
    }
    // 投票も復元。initState は同期的にデフォルト選択肢を 2 つ追加してから
    // この非同期ロードが走るが、_applyPollData が既存コントローラを片付けて
    // から組み直すので問題ない。
    if (pollOptions != null) {
      _applyPollData(pollOptions, pollMultiple, pollDuration);
    }
    if (scheduledIso != null && scheduledIso.isNotEmpty) {
      _applyScheduledIso(scheduledIso);
    }
  }

  /// 保存済みの投票データ (選択肢 / 複数選択 / 期限) を現在のフォームへ適用する。
  /// temp 下書き復元と下書き一覧からの復元で共有。既存の選択肢コントローラは
  /// dispose してから組み直す (_clearPoll と同じく dispose で listener も外れる)。
  /// 選択肢が 2 未満なら 2 つになるよう補完 (UI で消せる)。
  void _applyPollData(List<String> options, bool multiple, int duration) {
    if (!mounted) return;
    setState(() {
      for (final c in _pollOptionControllers) {
        c.dispose();
      }
      _pollOptionControllers.clear();
      _showPollCreation = true;
      _pollMultiple = multiple;
      _pollDuration = duration;
      for (final opt in options) {
        _pollOptionControllers.add(TextEditingController(text: opt));
      }
      while (_pollOptionControllers.length < 2) {
        _pollOptionControllers.add(TextEditingController());
      }
    });
  }

  /// 投稿に使ったアカウント ID を永続化。次回 `initialAccountIds` 未指定で
  /// 投稿ページを開いたときに、ここから復元してデフォルト選択にする。
  static const _prefsKeyLastUsedAccounts = 'post_last_used_accounts';

  Future<List<String>> _loadLastUsedAccountIds() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_prefsKeyLastUsedAccounts) ?? const [];
  }

  Future<void> _saveLastUsedAccountIds(Iterable<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKeyLastUsedAccounts, ids.toList());
  }

  Future<void> _saveTempDraft() async {
    // dispose から呼ばれる。await を 1 つでも挟むと続きは controller dispose 後に
    // 走る (dispose は _saveTempDraft() を呼んだ後そのまま controller を破棄する)
    // ため、**値の読み取りは最初の await より前に同期で済ませてスナップショット**
    // を作る。本文・CW・投票・予約日時はいずれもプレーンデータでサーバ側の未確定
    // 状態を持たないため、添付メディアと違ってそのまま保持・復元できる。投票期限は
    // 相対秒数 (例: 86400 = 1日) なので再オープン後もそのまま有効。CW フィールドを
    // 閉じている / 投票・予約が OFF の項目は省く (= 復元しない)。
    final body = _controller.text;
    final spoiler = _showSpoilerField ? _spoilerController.text : '';
    final pollData = _showPollCreation
        ? {
            'options': _pollOptionControllers.map((c) => c.text).toList(),
            'multiple': _pollMultiple,
            'duration': _pollDuration,
          }
        : null;
    final scheduledIso = _scheduledAt?.toIso8601String();

    // 返信 / 初期テキスト起動 (_loadTempDraft が復元をスキップするのと対称)。
    // 本文が自動プリフィルのまま (または空) で他に入力も無ければ、退避も既存
    // 下書きの削除もせずに抜ける。これをしないと (1) Deck ペインで返信→
    // 新規投稿に切り替えたとき手つかずの `@ユーザー名 ` が退避下書き経由で
    // 新規投稿に漏れる、(2) 返信を開いて何もせず閉じただけで以前の新規投稿の
    // 退避下書きがプリフィルで上書き破壊される。ユーザーがプリフィル以外を
    // 入力した場合は従来通り保存する (離脱確認の「閉じる (下書き保存)」の
    // 約束を守る)。
    final isPrefilledLaunch =
        widget.initialText != null || widget.replyToUsername != null;
    if (isPrefilledLaunch) {
      final bodyAuthored = body.isNotEmpty && body != _initialPrefillBody;
      final anyExtra =
          spoiler.isNotEmpty || pollData != null || scheduledIso != null;
      if (!bodyAuthored && !anyExtra) return;
    }

    final prefs = await SharedPreferences.getInstance();
    // 全項目を 1 つの JSON にまとめ、単一の setString で書く ([_kTempDraftKey] の
    // doc 参照。これにより kill / 再オープン競合でも all-or-nothing になる)。
    final hasContent = body.isNotEmpty ||
        spoiler.isNotEmpty ||
        pollData != null ||
        scheduledIso != null;
    if (hasContent) {
      await prefs.setString(
        _kTempDraftKey,
        jsonEncode({
          'body': body,
          if (spoiler.isNotEmpty) 'spoiler': spoiler,
          if (pollData != null) 'poll': pollData,
          if (scheduledIso != null) 'scheduledAt': scheduledIso,
        }),
      );
    } else {
      await prefs.remove(_kTempDraftKey);
    }
    // 旧形式 (キー分割) のキーは読み出し後方互換のためだけに残しているので、
    // 新形式で上書きするこのタイミングで掃除して二重持ちを防ぐ。
    await _removeLegacyTempKeys(prefs);
  }

  /// ISO 文字列の予約日時を検証して現在のフォームへ適用する。過去日時
  /// (Mastodon は最低 5 分後を要求) や parse 失敗は無視する (次の dispose 保存で
  /// scheduledAt が落ちて掃除される)。
  void _applyScheduledIso(String iso) {
    try {
      final dt = DateTime.parse(iso);
      if (dt.isBefore(DateTime.now())) return;
      if (mounted) {
        setState(() {
          _scheduledAt = dt;
          _showScheduledPost = true;
        });
      }
    } catch (_) {
      // 不正な値は無視
    }
  }

  /// 旧形式 (キー分割) の一時下書きキーを削除する。新形式 [_kTempDraftKey] へ
  /// 移行済みのデータが旧キーにも残って二重復元されるのを防ぐ。
  Future<void> _removeLegacyTempKeys(SharedPreferences prefs) async {
    await prefs.remove('post_temp');
    await prefs.remove('post_temp_spoiler');
    await prefs.remove('post_temp_poll');
    await prefs.remove('post_temp_scheduled_at');
  }

  /// 一時下書きを新旧キーまとめて完全に削除する (投稿成功 / 明示破棄時)。
  Future<void> _removeAllTempKeys(SharedPreferences prefs) async {
    await prefs.remove(_kTempDraftKey);
    await _removeLegacyTempKeys(prefs);
  }

  /// 実況モード設定を読み込み
  Future<void> _loadLiveModeSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final settingsJson = prefs.getString('live_mode_settings');
    if (settingsJson != null) {
      setState(() {
        _liveModeSettings = LiveModeSettings.fromJsonString(settingsJson);
      });
      // 設定読み込み後に文字数を再計算
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _onTextChanged();
      });
    }
  }

  /// 実況モード設定を保存
  Future<void> _saveLiveModeSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'live_mode_settings',
      _liveModeSettings.toJsonString(),
    );
  }

  @override
  void dispose() {
    // 編集モードでは post_temp に書き出さない。書き出してしまうと、編集を
    // 保存して閉じた後に新規投稿画面を開いたとき、_loadTempDraft が
    // 「編集していた本文」を「新規投稿の下書き」として復元してしまう。
    // 新規モードでは従来通り保存する (= 投稿せず閉じても本文が次回まで残る)。
    if (!widget.isEditing) {
      _saveTempDraft();
    }
    _suggestionDebounce?.cancel();
    _pasteListenerDispose?.call();
    _controller.removeListener(_onTextChanged);
    _textFocusNode.removeListener(_onFocusChanged);
    _controller.dispose();
    _textFocusNode.dispose();
    _spoilerController.dispose();
    _remaining.dispose();
    for (final controller in _pollOptionControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  /// 投稿画面用のトースト。FAB と被らないよう、中央寄せ + 内容幅自動の
  /// 軽量トースト (Overlay ベース) を使う。アップロード完了通知などに。
  void _showPostPageSnackBar(String message) {
    if (!mounted) return;
    showCenteredToast(context, message);
  }

  /// カメラで写真撮影
  Future<void> _pickFromCamera() async {
    final ImagePicker picker = ImagePicker();

    setState(() => _isUploading = true);

    try {
      final XFile? image = await picker.pickImage(source: ImageSource.camera);

      if (image == null) return;

      await _uploadImageFile(image);
    } finally {
      setState(() => _isUploading = false);
    }
  }

  /// ギャラリーから画像選択
  Future<void> _pickFromGallery() async {
    // _isUploading をピッカーオープン**前**にセット。投稿ボタン側は
    // `(_isPosting || _isUploading) ? null : _submit` で無効化される。
    // 「ピッカーを開いている間〜選んだ直後」までずっと無効にしたいので
    // ここで true、`finally` で false に戻す。
    setState(() => _isUploading = true);
    try {
      final ImagePicker picker = ImagePicker();
      final List<XFile> images = await picker.pickMultiImage();
      if (images.isEmpty) return;
      for (final image in images) {
        await _uploadImageFile(image);
      }
    } finally {
      setState(() => _isUploading = false);
    }
  }

  /// 1 ファイルを **選択中の全アカウント** に対して並行アップロードして
  /// `(accountId -> mediaId)` のマップを返す。失敗したアカウントは
  /// `failures` に詰めて呼び出し側に通知してもらう。
  ///
  /// Mastodon の media_id は発行インスタンス固有なので、クロスポスト時は
  /// 必ず各インスタンスに別個にアップロードする必要がある。
  Future<Map<String, String>> _uploadOneFileToAllSelectedAccounts({
    required XFile file,
    required Map<String, Object> failures,
  }) async {
    final authState = ref.read(authProvider);
    final results = <MapEntry<String, String>>[];
    final futures = <Future<void>>[];
    for (final accountId in _selectedAccountIds) {
      final acct = authState.accounts.firstWhere(
        (a) => a.id == accountId,
        orElse: () => authState.accounts.first,
      );
      futures.add(() async {
        try {
          final id = await uploadMedia(
            instanceUrl: acct.instanceUrl,
            accessToken: acct.accessToken,
            file: file,
          );
          results.add(MapEntry(accountId, id));
        } catch (e) {
          failures[accountId] = e;
        }
      }());
    }
    await Future.wait(futures);
    return Map.fromEntries(results);
  }

  /// 画像ファイルをアップロード (image_picker 経由パス)。
  /// 選択中の全アカウントに対して並行アップロードして MediaItem を構築する。
  Future<void> _uploadImageFile(XFile file) async {
    if (_selectedAccountIds.isEmpty) return;

    final failures = <String, Object>{};
    final ids = await _uploadOneFileToAllSelectedAccounts(
      file: file,
      failures: failures,
    );

    if (ids.isEmpty) {
      // 全アカウント失敗時のみエラー表示。1 件でも成功していれば
      // MediaItem を作って先に進める (失敗アカウントは _submit の
      // pre-flight で再 upload するか、ユーザーがアカウントを外す)。
      _showPostPageSnackBar(
          l10n.composeUploadFailed('${failures.values.first}'));
      return;
    }

    setState(() {
      _mediaItems.add(MediaItem(file: file, mediaIdsByAccount: ids));
    });

    if (failures.isEmpty) {
      _showPostPageSnackBar(l10n.composeImageUploaded);
    } else {
      _showPostPageSnackBar(
        l10n.composeUploadPartialFail(failures.length),
      );
    }
  }

  Future<void> _pickMedia() async {
    if (_selectedAccountIds.isEmpty) return;
    // _pickFromGallery と同様にピッカーオープン前に _isUploading=true。
    setState(() => _isUploading = true);
    try {
      final mediaGroup = XTypeGroup(
        label: 'media',
        extensions: ['jpg', 'jpeg', 'png', 'gif', 'mp4', 'mov'],
      );
      final xfiles = await openFiles(acceptedTypeGroups: [mediaGroup]);
      if (xfiles.isEmpty) return;

      final newItems = <MediaItem>[];
      final perFileFailures = <String, Map<String, Object>>{}; // filename -> failures
      for (final x in xfiles) {
        final failures = <String, Object>{};
        final ids = await _uploadOneFileToAllSelectedAccounts(
          file: x,
          failures: failures,
        );
        if (ids.isEmpty) {
          // 全アカウント失敗 → このファイルは諦めて次へ
          perFileFailures[x.name] = failures;
          continue;
        }
        newItems.add(MediaItem(file: x, mediaIdsByAccount: ids));
        if (failures.isNotEmpty) perFileFailures[x.name] = failures;
      }
      setState(() {
        _mediaItems.addAll(newItems);
      });
      if (newItems.isNotEmpty) {
        final msg = perFileFailures.isEmpty
            ? l10n.composeMediaUploadedCount(newItems.length)
            : l10n.composeMediaUploadedPartial(
                newItems.length, perFileFailures.length);
        _showPostPageSnackBar(msg);
      } else {
        _showPostPageSnackBar(l10n.composeMediaUploadFailed);
      }
    } finally {
      setState(() => _isUploading = false);
    }
  }

  /// このプラットフォームでファイルのドラッグ&ドロップ添付を有効にするか。
  /// OS からファイルをドラッグできる Web / デスクトップのみ true。モバイルは
  /// 該当 UI が無いので無効。
  bool get _supportsFileDrop {
    if (kIsWeb) return true;
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
        return true;
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return false;
    }
  }

  /// 添付として受け付けるメディアの拡張子 (ドロップ時の軽いフィルタ)。
  static const Set<String> _droppableMediaExtensions = {
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'bmp', // 画像
    'mp4', 'mov', 'm4v', 'webm', // 動画
    'mp3', 'ogg', 'oga', 'wav', 'flac', 'm4a', // 音声
  };

  /// ドラッグ&ドロップされたファイルを添付する。`DropItem` は `XFile` を継承して
  /// いるので、ファイル選択 ([_pickMedia]) と同じアップロード経路に流せる。
  Future<void> _handleDroppedFiles(List<DropItem> files) async {
    if (files.isEmpty) return;
    if (_selectedAccountIds.isEmpty) {
      _showPostPageSnackBar(context.l10n.composeSelectAccountFirst);
      return;
    }

    // 画像 / 動画 / 音声のみ受け付ける (フォルダや非対応ファイルを除外)。
    final media = files.where((f) {
      final name = f.name.toLowerCase();
      final dot = name.lastIndexOf('.');
      if (dot < 0 || dot == name.length - 1) return false;
      return _droppableMediaExtensions.contains(name.substring(dot + 1));
    }).toList();

    if (media.isEmpty) {
      _showPostPageSnackBar(context.l10n.composeDropMediaOnly);
      return;
    }

    setState(() => _isUploading = true);
    try {
      final newItems = <MediaItem>[];
      final perFileFailures = <String, Map<String, Object>>{};
      for (final x in media) {
        final failures = <String, Object>{};
        final ids = await _uploadOneFileToAllSelectedAccounts(
          file: x,
          failures: failures,
        );
        if (ids.isEmpty) {
          perFileFailures[x.name] = failures;
          continue;
        }
        newItems.add(MediaItem(file: x, mediaIdsByAccount: ids));
        if (failures.isNotEmpty) perFileFailures[x.name] = failures;
      }
      if (mounted) {
        setState(() => _mediaItems.addAll(newItems));
      }
      if (newItems.isNotEmpty) {
        _showPostPageSnackBar(
          perFileFailures.isEmpty
              ? l10n.composeMediaAttachedCount(newItems.length)
              : l10n.composeMediaAttachedPartial(
                  newItems.length, perFileFailures.length),
        );
      } else {
        _showPostPageSnackBar(l10n.composeMediaAttachFailed);
      }
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  /// Web の paste イベントを受け取ってよいか (本文フォーカス中のみ)。
  ///
  /// document 全体の paste を購読しているため、本文未フォーカス時 (裏のタイム
  /// ラインや他の入力欄での貼り付け、TweetDeck 風横ペインで TL 側を操作中など)
  /// に画像を奪わないよう、本文 TextField がフォーカスを持つ時だけ true にする。
  bool _shouldAcceptPaste() => mounted && _textFocusNode.hasFocus;

  /// [ClipboardImage] を既存アップロード経路に流せる [XFile] に変換する。
  /// `XFile.fromData` は Web (blob) / native (メモリ保持) 両対応で、`mimeType`
  /// を渡しておけば `uploadMedia` がそのまま正しい Content-Type で送信する。
  XFile _clipboardImageToXFile(ClipboardImage img) => XFile.fromData(
        img.bytes,
        name: img.suggestedName,
        mimeType: img.mimeType,
        length: img.bytes.length,
      );

  /// Desktop: Ctrl/Cmd+V やメニュー契機でクリップボードの画像を pull して添付する。
  /// Web では readClipboardImages が空を返すので呼んでも無害。
  ///
  /// [notifyIfEmpty] が true のとき、画像が無ければトーストで知らせる。明示的に
  /// 「クリップボードから貼り付け」メニューを押した場合に使う。Ctrl/Cmd+V キー
  /// 経路では false (テキストのみの貼り付けのたびに毎回メッセージが出ると邪魔)。
  Future<void> _pullClipboardImages({bool notifyIfEmpty = false}) async {
    final images = await readClipboardImages();
    if (images.isNotEmpty) {
      await _handleClipboardImages(images);
    } else if (notifyIfEmpty) {
      _showPostPageSnackBar(l10n.composeClipboardNoImage);
    }
  }

  /// クリップボードから得た画像群を添付する。ドラッグ&ドロップ
  /// ([_handleDroppedFiles]) と同じく、各画像を選択中の全アカウントへ並行
  /// アップロードして `MediaItem` を積む (クロスポスト対応)。
  Future<void> _handleClipboardImages(List<ClipboardImage> images) async {
    if (images.isEmpty) return;
    if (_isUploading) return; // 連打 / オートリピートの二重添付ガード
    if (_selectedAccountIds.isEmpty) {
      _showPostPageSnackBar(context.l10n.composeSelectAccountFirst);
      return;
    }

    setState(() => _isUploading = true);
    try {
      final newItems = <MediaItem>[];
      final perFileFailures = <String, Map<String, Object>>{};
      for (final img in images) {
        final x = _clipboardImageToXFile(img);
        final failures = <String, Object>{};
        final ids = await _uploadOneFileToAllSelectedAccounts(
          file: x,
          failures: failures,
        );
        if (ids.isEmpty) {
          perFileFailures[x.name] = failures;
          continue;
        }
        // クリップボード画像は XFile.fromData 由来で実ファイル path を持たない
        // ため、プレビュー用に元バイト列を MediaItem に持たせる。
        newItems.add(MediaItem(
          file: x,
          mediaIdsByAccount: ids,
          localBytes: img.bytes,
        ));
        if (failures.isNotEmpty) perFileFailures[x.name] = failures;
      }
      if (mounted) {
        setState(() => _mediaItems.addAll(newItems));
      }
      if (newItems.isNotEmpty) {
        _showPostPageSnackBar(
          perFileFailures.isEmpty
              ? l10n.composeImagePastedCount(newItems.length)
              : l10n.composeImagePastedPartial(
                  newItems.length, perFileFailures.length),
        );
      } else {
        // 全アカウントで失敗。原因切り分けのため実際の例外を表示する。
        final firstError = perFileFailures.values
            .expand((m) => m.values)
            .cast<Object?>()
            .firstWhere((e) => e != null, orElse: () => null);
        _showPostPageSnackBar(
          firstError != null
              ? l10n.composePasteFailedWithError('$firstError')
              : l10n.composePasteFailed,
        );
      }
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  /// Desktop で [child] (本文 TextField) を Ctrl/Cmd+V 検知用の [Focus] で包む。
  ///
  /// `CallbackShortcuts` に Ctrl+V を bind すると TextField の通常テキスト
  /// ペーストをシャドウして壊すため、`onKeyEvent` で検知しつつ **常に
  /// `KeyEventResult.ignored` を返して** デフォルトのペースト動作を妨げない。
  /// クリップボードに画像があれば非同期に pull して添付し、テキストのみなら
  /// `readClipboardImages` が空を返すので TextField の通常ペーストだけが起きる。
  /// Web / モバイルでは pull 非対応なので [child] をそのまま返す (Web は paste
  /// イベント購読で別途処理)。
  Widget _wrapWithPasteKeyHandler(Widget child) {
    if (!clipboardPullSupported) return child;
    return Focus(
      canRequestFocus: false, // フォーカスは内側の TextField に渡す
      skipTraversal: true,
      onKeyEvent: (node, event) {
        // KeyDownEvent のみ (オートリピートの KeyRepeatEvent では発火させない)。
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey != LogicalKeyboardKey.keyV) {
          return KeyEventResult.ignored;
        }
        final hk = HardwareKeyboard.instance;
        if (hk.isControlPressed || hk.isMetaPressed) {
          unawaited(_pullClipboardImages());
        }
        return KeyEventResult.ignored; // 常に非消費 (テキストペーストを壊さない)
      },
      child: child,
    );
  }

  /// Web / デスクトップで [child] を [DropTarget] でラップし、ファイルの
  /// ドラッグ&ドロップ添付を受け付ける。ドラッグ中は半透明のオーバーレイで
  /// ドロップ可能を示す。モバイルでは [child] をそのまま返す。
  Widget _wrapWithDropTarget(BuildContext context, Widget child) {
    if (!_supportsFileDrop) return child;
    final primary = Theme.of(context).colorScheme.primary;
    return DropTarget(
      onDragEntered: (_) => setState(() => _isDragging = true),
      onDragExited: (_) => setState(() => _isDragging = false),
      onDragDone: (details) {
        setState(() => _isDragging = false);
        _handleDroppedFiles(details.files);
      },
      child: Stack(
        // child (SafeArea) を tight 制約で全面に広げ、元の body と同じ
        // レイアウトを保つ。オーバーレイは Positioned.fill なので影響なし。
        fit: StackFit.expand,
        children: [
          child,
          if (_isDragging)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: primary.withValues(alpha: 0.12),
                  alignment: Alignment.center,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 16),
                    decoration: BoxDecoration(
                      color: primary,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.file_download_outlined,
                            color: Colors.white),
                        const SizedBox(width: 8),
                        Text(
                          context.l10n.composeDropHere,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 下書き保存
  Future<void> _saveNewDraft() async {
    final originalText = _controller.text.trim();
    if (originalText.isEmpty && _mediaItems.isEmpty) return;

    // 実況モードが有効な場合はハッシュタグを含めて保存
    String textToSave = originalText;
    if (_liveModeSettings.isEnabled && _liveModeSettings.hashtags.isNotEmpty) {
      final hashtagString = _liveModeSettings.hashtagString;
      if (_liveModeSettings.insertAtEnd) {
        textToSave = '$originalText$hashtagString';
      } else {
        textToSave = '${hashtagString.trim()} $originalText';
      }
    }
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: Text(ctx.l10n.composeSaveDraftTitle),
            content: Text(ctx.l10n.composeSaveDraftConfirm),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(ctx.l10n.cancel),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(ctx.l10n.save),
              ),
            ],
          ),
    );
    if (ok != true) return;

    final prefs = await SharedPreferences.getInstance();
    final listJson = prefs.getString('post_drafts');
    final existing = <Draft>[];
    if (listJson != null) {
      final arr = (jsonDecode(listJson) as List).cast<Map<String, dynamic>>();
      existing.addAll(arr.map((m) => Draft.fromJson(m)));
    }
    final snippet =
        textToSave.isNotEmpty
            ? (textToSave.length > 20
                ? '${textToSave.substring(0, 20)}…'
                : textToSave)
            : l10n.composeMediaOnlyDraft;
    final draft = Draft(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: snippet,
      content: textToSave,
      createdAt: DateTime.now(),
      // CW / 投票も保持する (post_temp 自動下書きと同じ扱い)。
      spoilerText: _showSpoilerField && _spoilerController.text.isNotEmpty
          ? _spoilerController.text
          : null,
      pollOptions: _showPollCreation
          ? _pollOptionControllers.map((c) => c.text).toList()
          : null,
      pollMultiple: _showPollCreation ? _pollMultiple : null,
      pollDuration: _showPollCreation ? _pollDuration : null,
    );
    existing.insert(0, draft);
    await prefs.setString(
      'post_drafts',
      jsonEncode(existing.map((d) => d.toJson()).toList()),
    );
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.composeDraftSaved)));
    }
  }

  void _openDrafts() {
    // Deck (ワイド) の投稿ペインから開く時はフルスクリーン push ではなく
    // ホームに重ねるポップアップで出す ([openDeckPage] が幅/位置で振り分ける)。
    // ポップアップは Future を返さないので、選択された下書きは pop の戻り値では
    // なく onSelected コールバックで受け取る。
    openDeckPage(
      context,
      (onDeckBack) => DraftsPage(
        onDeckBack: onDeckBack,
        onSelected: (draft) {
          if (!mounted) return;
          final content = draft.content;
          setState(() {
            _controller.text = content;
            _controller.selection =
                TextSelection.collapsed(offset: content.length);
            // CW も復元 (保存されている場合のみ。現在の入力は壊さない)。
            final cw = draft.spoilerText ?? '';
            if (cw.isNotEmpty) {
              _spoilerController.text = cw;
              _showSpoilerField = true;
            }
          });
          // 投票も復元 (_applyPollData が自前で setState)。
          if (draft.hasPoll) {
            _applyPollData(
              draft.pollOptions!,
              draft.pollMultiple ?? false,
              draft.pollDuration ?? 86400,
            );
          }
        },
      ),
    );
  }

  void _openScheduledPosts() {
    openDeckPage(
      context,
      (onDeckBack) => ScheduledPostsPage(onDeckBack: onDeckBack),
    );
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (_) => AlertDialog(
            title: Text(context.l10n.composeDiscardTitle),
            content: Text(context.l10n.composeDiscardConfirm),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(context.l10n.cancel),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(context.l10n.composeDiscard),
              ),
            ],
          ),
    );
    if (ok == true) {
      _remaining.value = _maxChars;
      setState(() {
        _controller.clear();
        _mediaItems.clear();
        _showSpoilerField = false;
        _spoilerController.clear();
        _isNSFW = false;
        _language = ref.read(settingsProvider).defaultPostLanguage;
        _scheduledAt = null;
        _showScheduledPost = false;
        _showEmojiPicker = false;
        // 公開範囲もデフォルトに戻す
        _visibilityManuallySet = false;
      });
      _clearPoll();
      _applyDefaultVisibilityFromPreferences();
      // 全入力を破棄したので退避下書きも完全に消す。ここで消さないと、破棄後
      // dispose 前に kill されたとき旧い下書きが復活してしまう。
      final prefs = await SharedPreferences.getInstance();
      await _removeAllTempKeys(prefs);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.composeDiscarded)));
      }
    }
  }

  Future<void> _submit() async {
    // 二重投稿ガード: 投稿処理中 (_isPosting) の再入を入口で弾く。
    // FAB は `_isPosting` でリビルド後に無効化されるが、それまでの間に
    // (1) リビルド前の高速ダブルタップ、(2) Ctrl/Cmd+Enter のキーリピート
    // で _submit が複数回呼ばれ得る。ここで弾かないと両方が投稿に進んで
    // 二重投稿になる (Ctrl+Enter のコメントが前提していた「投稿中の判定は
    // _submit() 側に任せる」ガードがこれ)。_isPosting は全完了パス
    // (成功 pop / finally / preflight 失敗 / 編集 finally) で false に戻る
    // ので恒久ロックにはならない。
    if (_isPosting) return;

    final authState = ref.read(authProvider);
    if (_selectedAccountIds.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
          SnackBar(content: Text(context.l10n.composeSelectPostAccount)));
      return;
    }

    // ボタンを `_isUploading` で無効化済みだが、二重防御。アップロード中に
    // 投稿してしまうと _mediaItems が未確定で「添付なし投稿」になる。
    if (_isUploading) {
      _showPostPageSnackBar(context.l10n.composeWaitMediaUpload);
      return;
    }

    final originalText = _controller.text.trim();
    if (originalText.isEmpty && _mediaItems.isEmpty) return;

    // 実況モードが有効な場合はハッシュタグを自動挿入。編集モードでは
    // 元投稿の意図を維持するため挿入しない (ライブモードは新規投稿用)。
    String finalText = originalText;
    if (!widget.isEditing &&
        _liveModeSettings.isEnabled &&
        _liveModeSettings.hashtags.isNotEmpty) {
      final hashtagString = _liveModeSettings.hashtagString;
      if (_liveModeSettings.insertAtEnd) {
        finalText = '$originalText$hashtagString';
      } else {
        finalText = '${hashtagString.trim()} $originalText';
      }
    }

    setState(() => _isPosting = true);

    // —— 編集モード: 単一アカウントに対し PUT /api/v1/statuses/:id —— //
    if (widget.isEditing) {
      await _submitEdit(authState, finalText);
      return;
    }

    int successCount = 0;
    int failCount = 0;
    final errors = <String>[];

    try {
      // 予約投稿かどうかを事前に記録（後でリセットされるため）
      final isScheduledPost = _scheduledAt != null;

      // --- pre-flight: 選択中アカウントのうち未アップロード分を埋める ---
      //
      // 通常は _uploadImageFile / _pickMedia が選択時の全アカウントへ並行
      // アップロード済みだが、「アップロード後にアカウントを追加した」
      // ケースだけ穴があく。そのアカウント用 mediaId を投稿前に作る。
      //
      // 何かしら 1 件でも失敗したら投稿全体を中止する。クロスポストで
      // 「画像なし投稿だけが片側に乗る」事故を避けるため。
      try {
        final preflight = <Future<void>>[];
        for (final m in _mediaItems) {
          for (final accountId in _selectedAccountIds) {
            if (m.mediaIdsByAccount.containsKey(accountId)) continue;
            final file = m.file;
            if (file == null) {
              throw Exception(l10n.composePreflightMissingFile(accountId));
            }
            final acct = authState.accounts.firstWhere(
              (a) => a.id == accountId,
              orElse: () => authState.accounts.first,
            );
            preflight.add(
              uploadMedia(
                instanceUrl: acct.instanceUrl,
                accessToken: acct.accessToken,
                file: file,
              ).then((id) {
                m.mediaIdsByAccount[accountId] = id;
              }),
            );
          }
        }
        if (preflight.isNotEmpty) {
          await Future.wait(preflight);
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.composeExtraUploadFailed('$e'))),
          );
        }
        setState(() => _isPosting = false);
        return;
      }

      // 選択された各アカウントに対して並行投稿
      final futures = <Future<void>>[];

      for (final accountId in _selectedAccountIds) {
        final acct = authState.accounts.firstWhere(
          (a) => a.id == accountId,
          orElse: () => authState.accounts.first,
        );

        // 投票データを作成
        PollData? pollData;
        if (_showPollCreation && _pollOptionControllers.isNotEmpty) {
          final options =
              _pollOptionControllers
                  .map((controller) => controller.text.trim())
                  .where((text) => text.isNotEmpty)
                  .toList();
          if (options.length >= 2) {
            pollData = PollData(
              options: options,
              expiresInSeconds: _pollDuration,
              multiple: _pollMultiple,
            );
          }
        }

        // 媒体 id は **このアカウントのインスタンス向け** に発行されたものを
        // 引く。pre-flight 後なので必ず key がある前提で `!` でアクセス。
        final mediaIdsForAccount = _mediaItems
            .map((m) => m.mediaIdsByAccount[accountId]!)
            .toList();

        futures.add(
          postStatus(
                instanceUrl: acct.instanceUrl,
                accessToken: acct.accessToken,
                statusText: finalText,
                visibility: _visibility,
                mediaIds:
                    mediaIdsForAccount.isEmpty ? null : mediaIdsForAccount,
                spoilerText: _showSpoilerField ? _spoilerController.text : null,
                inReplyToId: widget.replyToStatusId,
                poll: pollData,
                sensitive: _isNSFW,
                language: _language,
                scheduledAt: _scheduledAt,
                quotedStatusId: _quotedStatus?.id,
              )
              .then((status) {
                successCount++;
                debugPrint(
                  '予約投稿成功: ${acct.username}@${acct.instanceUrl}, StatusID: ${status.id}',
                );
                // 即時投稿だけ bus に流す。予約投稿は実際にタイムラインに
                // 乗るのが未来時刻なのでここで流すと存在しない投稿が出てしまう。
                if (_scheduledAt == null) {
                  publishLocalPost(accountId: acct.id);
                }
              })
              .catchError((e) {
                failCount++;
                final errorMsg = '${acct.username}@${acct.instanceUrl}: $e';
                errors.add(errorMsg);
                debugPrint('予約投稿エラー: $errorMsg');
                debugPrint('エラーの詳細: ${e.runtimeType} - $e');
              }),
        );
      }

      await Future.wait(futures);

      // 解析用に「クリア前」の構成を控える (下の setState / _clearPoll で
      // _mediaItems / poll がクリアされるため)。集計値のみで PII は含めない。
      final hadMedia = _mediaItems.isNotEmpty;
      final hadPoll = _showPollCreation && _pollOptionControllers.isNotEmpty;
      final postVisibility = _visibility;

      // フォームのクリア & 一時下書き削除は「全アカウント成功」した時だけ行う。
      // 1 件でも失敗 (文字数上限超過・ネットワーク・サーバエラー等) したら、
      // 入力 (本文/添付/CW/予約/投票) を残してユーザーが修正・再送できるように
      // する。失敗を確認する前に無条件でクリアしていたため、上限超過で 422 が
      // 返ったときに本文ごと消えていたのがこの不具合の原因。
      // 失敗時は post_temp も消さないので、画面を閉じても dispose の
      // _saveTempDraft で本文が次回まで保持される。
      if (failCount == 0) {
        final prefs = await SharedPreferences.getInstance();
        await _removeAllTempKeys(prefs);

        _remaining.value = _maxChars;
        setState(() {
          _controller.clear();
          _mediaItems.clear();
          _showSpoilerField = false;
          _spoilerController.clear();
          _isNSFW = false;
          _language = ref.read(settingsProvider).defaultPostLanguage;
          _scheduledAt = null;
          _showScheduledPost = false;
          _showEmojiPicker = false;
          // 公開範囲もデフォルトに戻す (前回の手動選択を持ち越さない)
          _visibilityManuallySet = false;
        });
        _clearPoll();
        _applyDefaultVisibilityFromPreferences();
      }

      // 結果のメッセージを表示
      String message;
      debugPrint('投稿結果: 成功=$successCount, 失敗=$failCount, 予約=$isScheduledPost');

      if (failCount == 0) {
        if (isScheduledPost) {
          message = l10n.composeScheduledToAccounts(successCount);
        } else {
          message = l10n.composePostedToAccounts(successCount);
        }
      } else {
        if (isScheduledPost) {
          message = l10n.composeScheduledPartial(successCount, failCount);
        } else {
          message = l10n.composePostedPartial(successCount, failCount);
        }
        if (errors.isNotEmpty) {
          debugPrint('Post errors: ${errors.join(", ")}');
          // エラーの詳細をユーザーに表示
          if (mounted) {
            showDialog(
              context: context,
              builder:
                  (context) => AlertDialog(
                    title: Text(context.l10n.composePostErrorDetailTitle),
                    content: SingleChildScrollView(
                      child: Text(errors.join('\n\n')),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(context.l10n.close),
                      ),
                    ],
                  ),
            );
          }
        }
      }

      if (mounted) {
        // pop 直後にメインページ上で表示される。FAB と被らないよう、中央寄せ
        // + 内容幅自動の軽量トーストで出す (rootOverlay を使うので pop しても
        // 表示は維持される)。
        showCenteredToast(context, message);

        if (successCount > 0) {
          // 効果音 (フォアグラウンドのみ・既定 OFF)。通常投稿・予約投稿の両方。
          if (ref.read(settingsProvider).soundOnPost) {
            SoundService.instance.post();
          }
          // 利用状況: 投稿成功 (集計値のみ。本文/宛先/サーバなどは送らない)。
          // 1 件でも成功すれば記録・「使ったアカウント」記憶は行う。
          AnalyticsService.instance.logEvent('post_published', parameters: {
            'has_media': hadMedia,
            'has_poll': hadPoll,
            'visibility': postVisibility,
            'is_scheduled': isScheduledPost,
            'account_count': successCount,
          });
          // 次回開いた時に同じアカウントが選ばれているように記憶
          await _saveLastUsedAccountIds(_selectedAccountIds);
        }

        if (!mounted) return;
        // 画面を閉じる / ホストに通知するのは全アカウント成功した時だけ。
        // 失敗が 1 件でも残るなら、保持した入力をユーザーが修正・再送できるよう
        // 画面に留まる (フォームも上のブロックでクリアしていない)。
        if (failCount == 0) {
          if (widget.embedded) {
            // 埋め込み (横ペイン) はフォームが既にクリア済み。ページを pop せず
            // ホストに通知し、ピン留めなら維持・非ピンなら閉じる判断を委ねる。
            widget.onPosted?.call();
          } else {
            Navigator.pop(context, true);
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.composePostFailed('$e'))));
      }
    } finally {
      setState(() => _isPosting = false);
    }
  }

  /// 投稿の編集 (`PUT /api/v1/statuses/:id`)。
  ///
  /// 編集対象の所有アカウントで PUT を送り、成功したら更新後の Status を
  /// 返値に詰めて画面を閉じる (`Navigator.pop(context, updatedStatus)`)。
  /// 呼び出し元 (PostTile の `_editPost`) はこの値を見てタイムラインを
  /// オプティミスティックに更新するなりリフレッシュするなりできる。
  Future<void> _submitEdit(AuthState authState, String finalText) async {
    // 予約日時が付いたまま編集保存しようとした場合は中断して知らせる。
    // PUT /api/v1/statuses/:id に scheduled_at は無く、黙って無視すると
    // 「保存できたのに予約されていない」ように見える (実際にあった報告)。
    // 編集モードでは予約 UI を出さないが、下書き読み込み等で予約日時が
    // 紛れ込む経路への防御。
    if (_scheduledAt != null) {
      _showPostPageSnackBar(context.l10n.composeEditNoSchedule);
      setState(() => _isPosting = false);
      return;
    }

    final accountId = _selectedAccountIds.first;
    final acct = authState.accounts.firstWhere(
      (a) => a.id == accountId,
      orElse: () => authState.accounts.first,
    );

    // 投票データ構築 (新規投稿と同じロジック)
    PollData? pollData;
    if (_showPollCreation && _pollOptionControllers.isNotEmpty) {
      final options = _pollOptionControllers
          .map((controller) => controller.text.trim())
          .where((text) => text.isNotEmpty)
          .toList();
      if (options.length >= 2) {
        pollData = PollData(
          options: options,
          expiresInSeconds: _pollDuration,
          multiple: _pollMultiple,
        );
      }
    }

    // メディアは「現状この投稿に紐づけたい id 全て」を渡す。新規追加は
    // 既に uploadMedia 済みなので id が入っており、リモート維持分は
    // _restoreFromEditTarget で生成した既存 id がそのまま流れる。
    // 編集は単一アカウント (= `accountId`) でしか走らないので、当該
    // アカウント用の id を引く (= `mediaIdsByAccount[accountId]`)。
    // 編集モードでは MediaItem 構築時に必ずこの key を入れている。
    // 旧データ等で key が無い場合は最初の値にフォールバック。
    final mediaIdsForEdit = _mediaItems.isEmpty
        ? null
        : _mediaItems
            .map((m) =>
                m.mediaIdsByAccount[accountId] ??
                m.mediaIdsByAccount.values.first)
            .toList();

    // 投稿済みメディアの ALT は `PUT /api/v1/media/:id` では更新できない
    // (unattached 限定) ので、status 編集と同時に `media_attributes[]` で
    // 送る。description 空の場合も「未指定」と区別できるよう常に送る。
    final mediaAttributesForEdit = mediaIdsForEdit == null
        ? null
        : [
            for (var i = 0; i < _mediaItems.length; i++)
              {
                'id': mediaIdsForEdit[i],
                'description': _mediaItems[i].altText,
              },
          ];

    try {
      final updated = await editStatus(
        instanceUrl: acct.instanceUrl,
        accessToken: acct.accessToken,
        statusId: widget.editStatusId!,
        statusText: finalText,
        spoilerText: _showSpoilerField ? _spoilerController.text : '',
        sensitive: _isNSFW,
        language: _language,
        mediaIds: mediaIdsForEdit,
        mediaAttributes: mediaAttributesForEdit,
        poll: pollData,
      );

      if (!mounted) return;
      // 編集結果を bus に流して表示中リスト (TL / プロフィール / スレッド等) を
      // その場で差し替える。embedded / フルスクリーンのどちらでも PostPage 側で
      // 公開するので、呼び出し元は結果を受け取らなくてよい。
      publishLocalStatusEdited(accountId: acct.id, updated: updated);
      // 中央寄せの軽量トーストで FAB と被らないように。
      showCenteredToast(context, context.l10n.composePostUpdated);
      if (widget.embedded) {
        // 埋め込み (横ペイン): ページ遷移ではないので pop せずホストに通知
        // (ホストが新規コンポーズへ戻す / 閉じるを判断)。
        widget.onPosted?.call();
      } else {
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l10n.composeEditFailed('$e'))));
      }
    } finally {
      if (mounted) setState(() => _isPosting = false);
    }
  }

  /// 投票選択肢を追加
  void _addPollOption() {
    if (_pollOptionControllers.length < 4) {
      setState(() {
        _pollOptionControllers.add(TextEditingController());
      });
    }
  }

  /// 投票選択肢を削除
  void _removePollOption(int index) {
    if (_pollOptionControllers.length > 2) {
      setState(() {
        _pollOptionControllers[index].dispose();
        _pollOptionControllers.removeAt(index);
      });
    }
  }

  /// 投票設定をクリア
  void _clearPoll() {
    setState(() {
      _showPollCreation = false;
      for (final controller in _pollOptionControllers) {
        controller.dispose();
      }
      _pollOptionControllers.clear();
      _pollDuration = 86400;
      _pollMultiple = false;
    });
    _addPollOption();
    _addPollOption();
  }

  /// 予約投稿の日時をフォーマット
  String _formatScheduledDateTime(DateTime dateTime) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final scheduledDate = DateTime(dateTime.year, dateTime.month, dateTime.day);

    final timeStr =
        '${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';

    // 今日の場合
    if (scheduledDate == today) {
      return context.l10n
          .composeScheduledPrefix(context.l10n.scheduledToday(timeStr));
    }

    // 明日の場合
    final tomorrow = today.add(const Duration(days: 1));
    if (scheduledDate == tomorrow) {
      return context.l10n
          .composeScheduledPrefix(context.l10n.scheduledTomorrow(timeStr));
    }

    // 今年の場合は年を省略
    if (dateTime.year == now.year) {
      return context.l10n.composeScheduledPrefix(context.l10n
          .scheduledDateShort(dateTime.month, dateTime.day, timeStr));
    }

    // 来年以降の場合は年も表示
    return context.l10n.composeScheduledPrefix(context.l10n.scheduledDateFull(
        dateTime.year, dateTime.month, dateTime.day, timeStr));
  }

  /// 予約投稿の日時選択ダイアログを表示
  Future<void> _showScheduledDateTimePicker() async {
    // 編集モードでは予約不可 (ボタン自体を非表示にしているが二重防御)。
    if (widget.isEditing) {
      _showPostPageSnackBar(context.l10n.composeEditCannotSchedule);
      return;
    }
    final now = DateTime.now();
    // 最低5分後から選択可能
    final minDate = now.add(const Duration(minutes: 5));

    // 日付選択
    final selectedDate = await showDatePicker(
      context: context,
      initialDate: _scheduledAt ?? minDate,
      firstDate: minDate,
      lastDate: now.add(const Duration(days: 365)), // 1年後まで
      helpText: context.l10n.composePickDateHelp,
      cancelText: context.l10n.cancel,
      confirmText: 'OK',
    );

    if (selectedDate == null) return;
    if (!mounted) return;

    // 時刻選択
    final selectedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_scheduledAt ?? minDate),
      helpText: context.l10n.composePickTimeHelp,
      hourLabelText: context.l10n.composeHourLabel,
      minuteLabelText: context.l10n.composeMinuteLabel,
      cancelText: context.l10n.cancel,
      confirmText: 'OK',
    );

    if (selectedTime == null) return;

    final scheduledDateTime = DateTime(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
      selectedTime.hour,
      selectedTime.minute,
    );

    // 過去または5分以内の時刻は無効
    if (scheduledDateTime.isBefore(minDate)) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(
            SnackBar(content: Text(context.l10n.composeScheduleMinFive)));
      }
      return;
    }

    setState(() {
      _scheduledAt = scheduledDateTime;
      _showScheduledPost = true;
    });
  }

  /// 絵文字を選択
  void _onEmojiSelected(String emoji) {
    // カーソル位置が無効な場合 (まだ focus 取ったことがない等) は
    // 末尾に挿入する。これでピッカーから連続挿入してもクラッシュしない。
    final selection = _controller.selection;
    final text = _controller.text;
    final cursorPos = selection.isValid && selection.baseOffset >= 0
        ? selection.baseOffset
        : text.length;
    final beforeCursor = text.substring(0, cursorPos);
    final afterCursor = text.substring(cursorPos);

    // カスタム絵文字ショートコード (`:foo:`) は Mastodon のパース仕様で前後が
    // 空白文字 (または行頭/行末/記号など非英数字) でないと描画されない。
    // 例えば「Hello:smile:」だと `:smile:` は表示されず生テキストのまま残る。
    // 挿入位置の直前 / 直後を見て、空白が無ければ自動的に半角スペースを補う。
    // Unicode 絵文字 (1〜2 文字) はこの制約が無いのでそのまま挿入する。
    final isShortcode = emoji.length > 2 &&
        emoji.startsWith(':') &&
        emoji.endsWith(':');
    String prefix = '';
    String suffix = '';
    if (isShortcode) {
      if (beforeCursor.isNotEmpty &&
          !RegExp(r'\s$').hasMatch(beforeCursor)) {
        prefix = ' ';
      }
      if (afterCursor.isNotEmpty &&
          !RegExp(r'^\s').hasMatch(afterCursor)) {
        suffix = ' ';
      }
    }

    final newText = '$beforeCursor$prefix$emoji$suffix$afterCursor';
    // カーソルはショートコード + 補った suffix の右側に置く。連続挿入時に
    // 直前が空白扱いになって prefix を二重に入れないで済むので自然。
    final newCursorPos =
        cursorPos + prefix.length + emoji.length + suffix.length;

    _controller.text = newText;
    _controller.selection = TextSelection.collapsed(offset: newCursorPos);

    // ピッカーは閉じず、textfield にも focus を戻さない。連続挿入したい
    // ケースが多く、focus を戻すとキーボードが復活してピッカーを覆って
    // しまう。ユーザーが完了したら手動でピッカーを閉じる。
  }

  /// コンパクトな水平スクロール候補ウィジェットを構築
  /// 引用元投稿のコンパクトプレビュー (公式引用用)。閉じるボタンで取消できる。
  Widget _buildQuotedStatusPreview() {
    final q = _quotedStatus!;
    // CW 付き投稿を引用したときは spoilerText を「CW: …」として出し、
    // 本文プレビューでネタバレしないようにする。
    final hasCw = q.spoilerText.isNotEmpty;
    final previewText = hasCw ? 'CW: ${q.spoilerText}' : _quotedStatusPlain;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade400),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.format_quote, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.composeQuoteLabel(q.account.acct),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  previewText,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: hasCw
                        ? Colors.orange.shade700
                        : Colors.grey[700],
                    fontWeight: hasCw ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: context.l10n.composeQuoteCancelTooltip,
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _setQuotedStatus(null)),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactSuggestionsWidget() {
    return Container(
      height: 40,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        itemCount: _currentSuggestionType == '@' 
            ? _userSuggestions.length 
            : _hashtagSuggestions.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          if (_currentSuggestionType == '@') {
            final user = _userSuggestions[index];
            return _buildUserChip(user);
          } else {
            final hashtag = _hashtagSuggestions[index];
            return _buildHashtagChip(hashtag);
          }
        },
      ),
    );
  }

  /// ユーザー候補チップを構築
  Widget _buildUserChip(Account user) {
    return GestureDetector(
      onTap: () => _insertSuggestion(user.username),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 140),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).primaryColor.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Theme.of(context).primaryColor.withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            UserAvatar(
              url: user.avatarStatic,
              radius: 10,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                '@${user.username}',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// ハッシュタグ候補チップを構築
  Widget _buildHashtagChip(String hashtag) {
    return GestureDetector(
      onTap: () => _insertSuggestion(hashtag),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 120),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.blue.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Colors.blue.withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.tag,
              color: Colors.blue,
              size: 14,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                hashtag,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                  color: Colors.blue,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// ハッシュタグ挿入ボタン
  Widget _buildHashtagButton() {
    return ElevatedButton(
      onPressed: () {
        final cursorPos = _controller.selection.baseOffset;
        final text = _controller.text;
        final beforeCursor = text.substring(0, cursorPos);
        final afterCursor = text.substring(cursorPos);

        // カーソル位置に#を挿入
        final newText = '$beforeCursor#$afterCursor';
        final newCursorPos = cursorPos + 1;

        _controller.text = newText;
        _controller.selection = TextSelection.collapsed(offset: newCursorPos);
        _textFocusNode.requestFocus();
      },
      style: ElevatedButton.styleFrom(
        minimumSize: const Size(40, 40),
        padding: const EdgeInsets.all(8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      child: const Icon(Icons.tag, size: 20),
    );
  }

  /// 実況モード設定ダイアログを表示
  Future<void> _showLiveModeSettingsDialog() async {
    final result = await showDialog<LiveModeSettings>(
      context: context,
      builder:
          (context) =>
              LiveModeSettingsDialog(initialSettings: _liveModeSettings),
    );

    if (result != null) {
      setState(() {
        _liveModeSettings = result;
      });
      await _saveLiveModeSettings();
      // 実況モード設定変更時に文字数を再計算
      _onTextChanged();
    }
  }

  /// ALT文編集ダイアログを表示
  Future<void> _showAltTextDialog(int index) async {
    final mediaItem = _mediaItems[index];
    final controller = TextEditingController(text: mediaItem.altText);

    String? result;
    try {
      result = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.l10n.composeAltEditTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                context.l10n.composeAltHelp,
                style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                maxLines: 3,
                maxLength: 1500,
                decoration: InputDecoration(
                  labelText: context.l10n.composeAltLabel,
                  hintText: context.l10n.composeAltHint,
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.cancel),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: Text(context.l10n.save),
            ),
          ],
        ),
      );
    } finally {
      // back ボタン / barrier タップ等いずれの経路でも controller を確実に dispose する。
      // ただし即時 dispose すると、ダイアログ閉鎖時の focus 外れに伴って
      // EditableTextState._handleFocusChanged → controller.clearComposing()
      // がマイクロタスクで遅延実行される際に「disposed な controller を使用」
      // 例外を投げる (この例外が連鎖して _dependents.isEmpty assert / dirty
      // widget 例外まで噴き出す)。1 フレーム後の post-frame callback まで
      // 待ってから dispose する。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.dispose();
      });
    }

    final saved = result;
    if (saved != null) {
      setState(() {
        _mediaItems[index].altText = saved;
      });

      // 編集モードで「既存の (= 投稿済みに紐づいた) リモートメディア」の
      // 場合は `PUT /api/v1/media/:id` が 404 を返す (サーバ側で unattached の
      // media にしか作用しない)。この場合はサーバ反映を _submitEdit の
      // `media_attributes[]` 経由に委ねるため、ここでは何も送らない。
      if (widget.isEditing && mediaItem.file == null) {
        return;
      }

      // サーバーに ALT 文を更新。クロスポストでアップロード済みの全アカ
      // ウントの media に対して並行反映する (各 instance 固有の media_id
      // なので個別に呼び出す必要がある)。
      try {
        final authState = ref.read(authProvider);
        final futures = <Future<void>>[];
        for (final entry in mediaItem.mediaIdsByAccount.entries) {
          final acct = authState.accounts.firstWhere(
            (a) => a.id == entry.key,
            orElse: () => authState.accounts.first,
          );
          futures.add(
            updateMediaDescription(
              instanceUrl: acct.instanceUrl,
              accessToken: acct.accessToken,
              mediaId: entry.value,
              description: saved,
            ),
          );
        }
        await Future.wait(futures);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(
              SnackBar(content: Text(l10n.composeAltUpdateFailed('$e'))));
        }
      }
    }
  }

  /// アカウント選択ダイアログを表示
  Future<void> _showAccountSelectionDialog(
    BuildContext context,
    List<dynamic> accounts,
  ) async {
    final selectedIds = Set<String>.from(_selectedAccountIds);

    await showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            // 広い画面 (Deck) では double.maxFinite だとダイアログがウィンドウ幅
            // いっぱいまで横に広がるので最大幅を制限する (通知フィルター等と同じ
            // 方針)。狭い画面 (スマホ) は従来どおりフル幅。
            final screenWidth = MediaQuery.of(context).size.width;
            final dialogContentWidth =
                screenWidth < 480 ? double.maxFinite : 400.0;
            return AlertDialog(
              title: Text(context.l10n.composeSelectAccountsTitle),
              content: SizedBox(
                width: dialogContentWidth,
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: accounts.length,
                  itemBuilder: (context, index) {
                    final account = accounts[index];
                    final isSelected = selectedIds.contains(account.id);

                    return CheckboxListTile(
                      value: isSelected,
                      onChanged: (bool? value) {
                        setDialogState(() {
                          if (value == true) {
                            selectedIds.add(account.id);
                          } else {
                            selectedIds.remove(account.id);
                          }
                        });
                      },
                      secondary: UserAvatar(
                        url: account.avatarUrl,
                        radius: 20,
                      ),
                      title: Row(
                        children: [
                          if (account.accountColor != null)
                            Container(
                              width: 12,
                              height: 12,
                              margin: const EdgeInsets.only(right: 8),
                              decoration: BoxDecoration(
                                color: account.accountColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                          Expanded(
                            child: Text(
                              account.displayName,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      subtitle: Text(
                        '@${account.username}@${account.host}',
                        style: const TextStyle(fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                      dense: true,
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(context.l10n.cancel),
                ),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _selectedAccountIds = selectedIds;
                    });
                    _updateMaxCharsForSelectedAccount();
                    _applyDefaultVisibilityFromPreferences();
                    Navigator.of(context).pop();
                  },
                  child: Text(
                      context.l10n.composeSelectCount(selectedIds.length)),
                ),
              ],
            );
          },
        );
      },
    );
  }


  /// 機能ボタンを構築
  Widget _buildFeatureButton({
    required String label,
    IconData? icon,
    Widget? child,
    required bool isActive,
    required VoidCallback onPressed,
    Color? activeColor,
  }) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final color =
        isActive
            ? (activeColor ?? Theme.of(context).primaryColor)
            : (isDarkMode ? Colors.grey.shade400 : Colors.grey.shade600);

    final backgroundColor = isActive
        ? (activeColor ?? Theme.of(context).primaryColor).withValues(alpha: isDarkMode ? 0.25 : 0.1)
        : (isDarkMode ? Colors.grey.shade800.withValues(alpha: 0.5) : Colors.grey.shade50);

    final borderColor = isActive
        ? (activeColor ?? Theme.of(context).primaryColor).withValues(alpha: isDarkMode ? 0.6 : 0.3)
        : (isDarkMode ? Colors.grey.shade700 : Colors.grey.shade300);

    return Expanded(
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            children: [
              child ?? Icon(icon, size: 20, color: color),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: color,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// メディアサムネイルを構築
  Widget _buildMediaThumbnail(int index) {
    final mediaItem = _mediaItems[index];
    final file = mediaItem.file;
    // 新規アップロードの場合はローカルファイルから MIME 判定。リモート既存
    // メディア (= 編集対象投稿に元から付いていたもの) は file が null なので
    // remotePreviewUrl の拡張子からざっくり判定する (詳細な video/image 識別が
    // 必要なら editTargetStatus.mediaAttachments[i].type を参照する手もあるが、
    // ここではプレビュー絵を出すだけなので素朴な判定で十分)。
    //
    // Web では `file.path` が blob URL で拡張子無しのため lookupMimeType は
    // 返さない。XFile が image_picker 経由で受け取った `mimeType` を優先する。
    final mimeType = file != null
        ? (file.mimeType ?? lookupMimeType(file.name) ?? '')
        : (lookupMimeType(mediaItem.remotePreviewUrl ?? '') ?? '');
    final isVideo = mimeType.startsWith('video/');

    final Widget previewChild;
    if (isVideo) {
      previewChild = Stack(
        children: [
          Container(
            width: 84,
            height: 84,
            color: Colors.black87,
            child: const Icon(
              Icons.videocam,
              color: Colors.white,
              size: 32,
            ),
          ),
          Positioned(
            bottom: 4,
            left: 4,
            right: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                context.l10n.composeVideoLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      );
    } else if (mediaItem.localBytes != null) {
      // クリップボード貼り付け等のメモリ上画像。XFile.fromData の path は io 実装
      // だと `data:` URI で Image.file が読めないため、保持しておいたバイト列を
      // 直接デコードする (Web/デスクトップ共通)。
      previewChild = Image.memory(
        mediaItem.localBytes!,
        width: 84,
        height: 84,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => Container(
          width: 84,
          height: 84,
          color: Colors.grey.shade300,
          child: const Icon(Icons.broken_image, size: 32),
        ),
      );
    } else if (file != null) {
      // Web では XFile.path が blob: URL のためそのまま Image.network が動く
      // (ブラウザが blob URL を解決して bytes を返す)。
      // モバイル/デスクトップでは Image.file (dart:io File) で従来通り読む。
      previewChild = kIsWeb
          ? Image.network(
              file.path,
              width: 84,
              height: 84,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) {
                return Container(
                  width: 84,
                  height: 84,
                  color: Colors.grey.shade300,
                  child: const Icon(Icons.broken_image, size: 32),
                );
              },
            )
          : Image.file(
              File(file.path),
              width: 84,
              height: 84,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) {
                return Container(
                  width: 84,
                  height: 84,
                  color: Colors.grey.shade300,
                  child: const Icon(Icons.broken_image, size: 32),
                );
              },
            );
    } else if (mediaItem.remotePreviewUrl != null) {
      previewChild = Image.network(
        mediaItem.remotePreviewUrl!,
        width: 84,
        height: 84,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => Container(
          width: 84,
          height: 84,
          color: Colors.grey.shade300,
          child: const Icon(Icons.broken_image, size: 32),
        ),
      );
    } else {
      previewChild = Container(
        width: 84,
        height: 84,
        color: Colors.grey.shade300,
        child: const Icon(Icons.broken_image, size: 32),
      );
    }

    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 84,
            height: 84,
            color: Colors.grey.shade300,
            child: previewChild,
          ),
        ),
        // 削除ボタン
        Positioned(
          top: 4,
          right: 4,
          child: GestureDetector(
            onTap: () {
              setState(() {
                _mediaItems.removeAt(index);
              });
            },
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: const BoxDecoration(
                color: Colors.black54,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close, size: 16, color: Colors.white),
            ),
          ),
        ),
        // ALT文編集ボタン
        Positioned(
          bottom: 4,
          left: 4,
          child: GestureDetector(
            onTap: () => _showAltTextDialog(index),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.edit, size: 12, color: Colors.white),
                  const SizedBox(width: 2),
                  const Text(
                    'ALT',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 投票作成UIを構築
  Widget _buildPollCreationUI() {
    return Card(
      elevation: 1,
      color: Theme.of(context).brightness == Brightness.dark
          ? Colors.grey.shade800
          : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.poll, size: 20),
                const SizedBox(width: 8),
                Text(
                  context.l10n.composePollCreate,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: _clearPoll,
                  tooltip: context.l10n.composePollDeleteTooltip,
                ),
              ],
            ),
            const SizedBox(height: 16),

            // 投票選択肢
            ...List.generate(_pollOptionControllers.length, (index) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _pollOptionControllers[index],
                        decoration: InputDecoration(
                          labelText:
                              context.l10n.composePollOptionN(index + 1),
                          border: const OutlineInputBorder(),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                        ),
                        maxLength: 50,
                      ),
                    ),
                    if (_pollOptionControllers.length > 2) ...[
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.remove_circle_outline),
                        onPressed: () => _removePollOption(index),
                        tooltip: context.l10n.composePollOptionDeleteTooltip,
                      ),
                    ],
                  ],
                ),
              );
            }),

            // 選択肢追加ボタン
            if (_pollOptionControllers.length < 4)
              OutlinedButton.icon(
                icon: const Icon(Icons.add),
                label: Text(context.l10n.composePollAddOption),
                onPressed: _addPollOption,
              ),

            const SizedBox(height: 16),

            // 投票設定
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: _pollDuration,
                    decoration: InputDecoration(
                      labelText: context.l10n.composePollDuration,
                      border: const OutlineInputBorder(),
                    ),
                    items: [
                      DropdownMenuItem(
                          value: 300,
                          child: Text(context.l10n.composeDuration5m)),
                      DropdownMenuItem(
                          value: 1800,
                          child: Text(context.l10n.composeDuration30m)),
                      DropdownMenuItem(
                          value: 3600,
                          child: Text(context.l10n.composeDuration1h)),
                      DropdownMenuItem(
                          value: 21600,
                          child: Text(context.l10n.composeDuration6h)),
                      DropdownMenuItem(
                          value: 86400,
                          child: Text(context.l10n.composeDuration1d)),
                      DropdownMenuItem(
                          value: 259200,
                          child: Text(context.l10n.composeDuration3d)),
                      DropdownMenuItem(
                          value: 604800,
                          child: Text(context.l10n.composeDuration7d)),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => _pollDuration = value);
                      }
                    },
                  ),
                ),
                const SizedBox(width: 16),
                Column(
                  children: [
                    Text(context.l10n.composePollMultiple,
                        style: const TextStyle(fontSize: 12)),
                    Switch(
                      value: _pollMultiple,
                      onChanged:
                          (value) => setState(() => _pollMultiple = value),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }


  /// 下部入力セクションを構築
  Widget _buildBottomInputSection() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // 編集モードのときだけ「公開範囲は変更できません」「アカウントは
          // 投稿主に固定」等の制限を 1 ヶ所にまとめて表示する。
          if (widget.isEditing)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest
                    .withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.edit_note,
                    size: 16,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      context.l10n.composeEditModeNotice,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          // ハッシュタグ挿入ボタンと言語選択（テキスト入力エリアの上）。狭い
          // ペイン幅 (360px) でもあふれないよう、公開範囲セレクタはアイコンのみ
          // 表示にして横幅を抑えている (メニューを開けばラベルが出る)。
          Row(
            children: [
              // 公開範囲選択。トリガーはアイコンのみで横幅を抑え、メニューは
              // PopupMenuButton で出す (内容に合わせて幅が決まるので項目テキストが
              // あふれない。DropdownButton はメニュー幅がボタン幅に追従するため、
              // アイコンのみだとメニュー側がオーバーフローしていた)。編集モードは
              // Mastodon API 仕様上 visibility 変更不可なので無効化する。
              PopupMenuButton<String>(
                enabled: !widget.isEditing,
                tooltip: context.l10n.composeVisibilityTooltip,
                position: PopupMenuPosition.under,
                onSelected: (v) => setState(() {
                  _visibility = v;
                  _visibilityManuallySet = true;
                }),
                itemBuilder: (context) => [
                  _visibilityMenuItem(
                      'public', Icons.public, context.l10n.visibilityPublic),
                  _visibilityMenuItem('unlisted', Icons.lock_open,
                      context.l10n.visibilityQuietPublic),
                  _visibilityMenuItem('private', Icons.lock,
                      context.l10n.visibilityFollowers),
                  _visibilityMenuItem('direct', Icons.alternate_email,
                      context.l10n.visibilitySpecificPeople),
                ],
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(_visibilityIcon(_visibility),
                          size: 20, color: Colors.grey.shade600),
                      Icon(Icons.arrow_drop_down,
                          size: 20, color: Colors.grey.shade600),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              _buildHashtagButton(),
              const SizedBox(width: 8),
              // 絵文字ボタン
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _showEmojiPicker = !_showEmojiPicker;
                  });
                },
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(40, 40),
                  padding: const EdgeInsets.all(8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: Icon(
                  _showEmojiPicker ? Icons.keyboard : Icons.emoji_emotions,
                  size: 20,
                ),
              ),
              const Spacer(),
              // 言語選択
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.language,
                    size: 16,
                    color: Colors.grey.shade600,
                  ),
                  const SizedBox(width: 4),
                  DropdownButton<String?>(
                    value: _language,
                    hint: Text(
                      context.l10n.composeLanguageLabel,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                    underline: const SizedBox.shrink(),
                    items: [
                      DropdownMenuItem<String?>(
                        value: null,
                        child: Text(context.l10n.composeLangAuto,
                            style: const TextStyle(fontSize: 12)),
                      ),
                      const DropdownMenuItem<String>(
                        value: 'ja',
                        child: Text('日本語', style: TextStyle(fontSize: 12)),
                      ),
                      const DropdownMenuItem<String>(
                        value: 'en',
                        child: Text('English', style: TextStyle(fontSize: 12)),
                      ),
                      const DropdownMenuItem<String>(
                        value: 'ko',
                        child: Text('한국어', style: TextStyle(fontSize: 12)),
                      ),
                      const DropdownMenuItem<String>(
                        value: 'zh-CN',
                        child: Text('中文(简体)', style: TextStyle(fontSize: 12)),
                      ),
                      const DropdownMenuItem<String>(
                        value: 'zh-TW',
                        child: Text('中文(繁體)', style: TextStyle(fontSize: 12)),
                      ),
                      const DropdownMenuItem<String>(
                        value: 'es',
                        child: Text('Español', style: TextStyle(fontSize: 12)),
                      ),
                      const DropdownMenuItem<String>(
                        value: 'fr',
                        child: Text('Français', style: TextStyle(fontSize: 12)),
                      ),
                      const DropdownMenuItem<String>(
                        value: 'de',
                        child: Text('Deutsch', style: TextStyle(fontSize: 12)),
                      ),
                      const DropdownMenuItem<String>(
                        value: 'it',
                        child: Text('Italiano', style: TextStyle(fontSize: 12)),
                      ),
                      const DropdownMenuItem<String>(
                        value: 'pt',
                        child: Text('Português', style: TextStyle(fontSize: 12)),
                      ),
                      const DropdownMenuItem<String>(
                        value: 'ru',
                        child: Text('Русский', style: TextStyle(fontSize: 12)),
                      ),
                      const DropdownMenuItem<String>(
                        value: 'ar',
                        child: Text('العربية', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                    onChanged: (value) => setState(() => _language = value),
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade700,
                    ),
                    dropdownColor: Theme.of(context).scaffoldBackgroundColor,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          
          // オートコンプリート候補表示（水平スクロール）
          if (_showSuggestions) _buildCompactSuggestionsWidget(),

          // 引用元プレビュー (Mastodon 4.4+ 公式引用)
          if (_quotedStatus != null) _buildQuotedStatusPreview(),

          // テキスト入力エリア（固定サイズ）
          SizedBox(
            height: 200,
            child: Stack(
              children: [
                // Desktop は Ctrl/Cmd+V でクリップボード画像を pull するため、
                // 本文 TextField を Focus で包む (非消費なのでテキスト貼付けは
                // 通常通り動く)。Web/モバイルでは素通し。
                _wrapWithPasteKeyHandler(
                  TextField(
                    controller: _controller,
                    focusNode: _textFocusNode,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    decoration: InputDecoration(
                      hintText: context.l10n.composeBodyHint,
                      border: const OutlineInputBorder(),
                      alignLabelWithHint: true,
                      contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 48), // 下部に余白を追加
                    ),
                  ),
                ),
                // 残り文字数（左下）。ValueListenableBuilder でこの行のみ rebuild。
                Positioned(
                  bottom: 8,
                  left: 12,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ValueListenableBuilder<int>(
                        valueListenable: _remaining,
                        builder: (context, remaining, _) {
                          final host = _maxCharsSourceInstanceHost;
                          // 複数アカウント選択時で制限の根拠 host が分かる
                          // ときだけ "(host)" を併記して、最も厳しい上限が
                          // どのインスタンス由来かをユーザーに示す。
                          final label = host != null
                              ? context.l10n
                                  .composeRemainingCharsHost(remaining, host)
                              : context.l10n.composeRemainingChars(remaining);
                          return Text(
                            label,
                            style: TextStyle(
                              fontSize: 12,
                              color: remaining < 0
                                  ? Colors.red
                                  : Colors.grey.shade600,
                              fontWeight: remaining < 0
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          );
                        },
                      ),
                      if (_liveModeSettings.isEnabled && _liveModeSettings.hashtags.isNotEmpty)
                        Text(
                          context.l10n.composeLiveTag(
                              _liveModeSettings.formattedHashtags.join(' ')),
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.blue,
                          ),
                        ),
                    ],
                  ),
                ),
                // 投稿ボタン（右下）
                Positioned(
                  bottom: 8,
                  right: 8,
                  child: FloatingActionButton.small(
                    // 遷移元 (メイン等) の default heroTag FAB と衝突しないよう
                    // 一意タグを付与 (multiple heroes share the same tag 対策)。
                    // 埋め込み (横ペイン) はページ遷移しないので hero 不要 = null。
                    heroTag: widget.embedded ? null : 'post_submit_fab',
                    // アップロード中は無効化。タップしてしまうと
                    // _mediaItems がまだ空のまま本文だけ送信されて
                    // 「画像つきのつもりが添付なし」事故になるため。
                    onPressed: (_isPosting || _isUploading) ? null : _submit,
                    elevation: 2,
                    tooltip: _isUploading
                        ? context.l10n.composeUploadingMedia
                        : (_isPosting ? context.l10n.composePosting : null),
                    child: (_isPosting || _isUploading)
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Icon(
                            widget.isEditing
                                ? Icons.save
                                : (_scheduledAt != null
                                    ? Icons.schedule_send
                                    : Icons.send),
                            size: 20,
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// フローティング絵文字ピッカーを構築
  Widget _buildFloatingEmojiPicker() {
    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    final bottomSpace =
        keyboardHeight > 0 ? 20.0 : 100.0; // キーボード表示時は20px、通常時は100px

    return Positioned(
      top: 20,
      left: 16,
      right: 16,
      bottom: bottomSpace,
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              // ヘッダー（タイトルと閉じるボタン）
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(context).primaryColor.withValues(alpha: 0.1),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(12),
                    topRight: Radius.circular(12),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.emoji_emotions,
                      color: Theme.of(context).primaryColor,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      context.l10n.composeEmojiPickerTitle,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).primaryColor,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () {
                        setState(() {
                          _showEmojiPicker = false;
                        });
                      },
                      icon: const Icon(Icons.close),
                      iconSize: 20,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      tooltip: context.l10n.close,
                    ),
                  ],
                ),
              ),
              // 絵文字ピッカー本体
              Expanded(
                child: EmojiPicker(
                  onEmojiSelected: _onEmojiSelected,
                  selectedAccountIds: _selectedAccountIds,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 編集中で「失われたら困る」状態を持っているか。
  /// 本文・CW・予約日時・投票は dispose の _saveTempDraft で下書きとして自動
  /// 保存され次回復元されるが、メディア・NSFW 等はサーバ側に未確定 / 復元できない
  /// 情報なので、ユーザーには離脱前に明示確認させる (自動保存される項目だけが
  /// 残っている場合も、念のため確認ダイアログを出す)。
  bool _hasInProgressContent() {
    if (_controller.text.trim().isNotEmpty) return true;
    if (_mediaItems.isNotEmpty) return true;
    if (_spoilerController.text.trim().isNotEmpty) return true;
    if (_scheduledAt != null) return true;
    if (_showPollCreation) return true;
    if (_isNSFW) return true;
    return false;
  }

  Future<_LeaveAction?> _confirmLeave() async {
    return showDialog<_LeaveAction>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.composeInterruptTitle),
        content: Text(ctx.l10n.composeInterruptBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, _LeaveAction.cancel),
            child: Text(ctx.l10n.composeKeepWriting),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _LeaveAction.discard),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(ctx.l10n.composeDiscard),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _LeaveAction.leaveKeepDraft),
            child: Text(ctx.l10n.close),
          ),
        ],
      ),
    );
  }

  /// 編集中状態を全て破棄する。dispose 内の _saveTempDraft が「中身が空」と
  /// 判定して退避下書きキーを削除するため、prefs の下書きも自動的にクリア
  /// される。サーバー側に既にアップロード済みのメディアはローカルから外す
  /// だけで残る (Mastodon 側で TTL 後に GC)。
  void _discardAll() {
    _controller.clear();
    _setQuotedStatus(null);
    _mediaItems.clear();
    _showSpoilerField = false;
    _spoilerController.clear();
    _isNSFW = false;
    _scheduledAt = null;
    _showScheduledPost = false;
    _showEmojiPicker = false;
    _showPollCreation = false;
    _clearPoll();
    _liveModeSettings = const LiveModeSettings();
    _remaining.value = _maxChars;
  }

  @override
  Widget build(BuildContext context) {
    // 埋め込み (横ペイン) はページ遷移ではないので PopScope を張らない。張ると
    // ルートルートの戻る (システムバック) を横取りしてしまう。離脱確認は不要
    // (閉じても下書きは post_temp に退避される)。
    if (widget.embedded) {
      return CallbackShortcuts(
        bindings: {
          // includeRepeats: false — キー長押しのオートリピートで _submit が
          // 連発されないようにする (二重投稿の保険。最終的な再入ガードは
          // _submit() 冒頭の _isPosting チェック)。
          const SingleActivator(LogicalKeyboardKey.enter,
              control: true, includeRepeats: false): _submit,
          const SingleActivator(LogicalKeyboardKey.enter,
              meta: true, includeRepeats: false): _submit,
        },
        child: _buildScaffold(context),
      );
    }

    // canPop は build 時に評価される。本文編集中は ValueNotifier 経由で
    // setState を呼ばずにいるため、`!_hasInProgressContent()` だと
    // canPop が stale になる (空 → 入力済み, 入力済み → 空 のどちらの遷移
    // でも反映されない)。PopScope では canPop = false 固定にして、ポップ
    // 試行時のコールバック内で live に判定するのが確実。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // await 越しに State.context を使うと lint が出るので、
        // navigator を await 前に capture しておく。
        final navigator = Navigator.of(context);
        // 編集中の状態が無ければそのまま離脱
        if (!_hasInProgressContent()) {
          navigator.pop();
          return;
        }
        final action = await _confirmLeave();
        if (action == null || action == _LeaveAction.cancel) return;
        if (action == _LeaveAction.discard) {
          _discardAll();
          // dispose 側の _saveTempDraft が空テキストを書き込んでくれる。
        }
        navigator.pop();
      },
      // Ctrl+Enter / Cmd+Enter で投稿。複数行 TextField は素の Enter を改行
      // として消費するが、修飾キー付き Enter は消費しないため、祖先の
      // CallbackShortcuts まで伝播して拾える。投稿可否 (空 / アップロード中 /
      // 投稿中) の判定は _submit() 側に任せる。
      child: CallbackShortcuts(
        bindings: {
          // includeRepeats: false — キー長押しのオートリピートで _submit が
          // 連発されないようにする (二重投稿の保険。最終的な再入ガードは
          // _submit() 冒頭の _isPosting チェック)。
          const SingleActivator(LogicalKeyboardKey.enter,
              control: true, includeRepeats: false): _submit,
          const SingleActivator(LogicalKeyboardKey.enter,
              meta: true, includeRepeats: false): _submit,
        },
        child: _buildScaffold(context),
      ),
    );
  }

  /// 公開範囲の値に対応するアイコン (トリガー表示用)。
  IconData _visibilityIcon(String v) {
    switch (v) {
      case 'unlisted':
        return Icons.lock_open;
      case 'private':
        return Icons.lock;
      case 'direct':
        return Icons.alternate_email;
      case 'public':
      default:
        return Icons.public;
    }
  }

  /// 公開範囲メニューの 1 項目 (アイコン + ラベル、現在値にはチェック)。
  PopupMenuItem<String> _visibilityMenuItem(
      String value, IconData icon, String label) {
    final selected = _visibility == value;
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: Colors.grey.shade700),
          const SizedBox(width: 10),
          Text(label),
          if (selected) ...[
            const SizedBox(width: 12),
            Icon(Icons.check,
                size: 18, color: Theme.of(context).colorScheme.primary),
          ],
        ],
      ),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // 埋め込み (横ペイン) では戻る矢印の代わりに:
        //  - 編集モード中: 「編集をやめて新規投稿に戻る」(×)。ピン固定中に編集を
        //    抜ける唯一の導線。
        //  - それ以外: ピン留め (固定表示) トグル。開閉はペン (投稿) ボタンで
        //    行うので閉じる × は出さない。
        automaticallyImplyLeading: !widget.embedded,
        leading: !widget.embedded
            ? null
            : widget.isEditing
                ? IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: context.l10n.composeStopEditTooltip,
                    onPressed: widget.onCancelEdit,
                  )
                : IconButton(
                    icon: Icon(widget.pinned
                        ? Icons.push_pin
                        : Icons.push_pin_outlined),
                    tooltip: widget.pinned
                        ? context.l10n.composeUnpinTooltip
                        : context.l10n.composePinTooltip,
                    color: widget.pinned
                        ? Theme.of(context).colorScheme.primary
                        : null,
                    onPressed: widget.onTogglePin,
                  ),
        title: Text(widget.isEditing
            ? context.l10n.composeEditTitle
            : (widget.replyToStatusId != null
                ? context.l10n.composeReplyTitle
                : context.l10n.composeNewTitle)),
        actions: [
          // メディア選択ボタン
          PopupMenuButton<String>(
            icon: _isUploading
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.attach_file),
            tooltip: context.l10n.composePickMediaTooltip,
            enabled: !_isUploading,
            onSelected: (String value) {
              switch (value) {
                case 'file':
                  _pickMedia();
                  break;
                case 'camera':
                  _pickFromCamera();
                  break;
                case 'gallery':
                  _pickFromGallery();
                  break;
                case 'paste_clipboard':
                  _pullClipboardImages(notifyIfEmpty: true);
                  break;
              }
            },
            itemBuilder: (BuildContext context) => [
              PopupMenuItem(
                value: 'file',
                child: ListTile(
                  leading: const Icon(Icons.attach_file),
                  title: Text(context.l10n.composePickFile),
                  dense: true,
                ),
              ),
              PopupMenuItem(
                value: 'camera',
                child: ListTile(
                  leading: const Icon(Icons.camera_alt),
                  title: Text(context.l10n.composeTakePhoto),
                  dense: true,
                ),
              ),
              PopupMenuItem(
                value: 'gallery',
                child: ListTile(
                  leading: const Icon(Icons.photo_library),
                  title: Text(context.l10n.composePickFromGallery),
                  dense: true,
                ),
              ),
              // クリップボードからの貼り付けは Desktop のみメニューに出す。
              // Web はメニュー契機だと paste イベントを発火できず async
              // Clipboard API (Chrome 限定 + 権限) になるため、Web は本文での
              // Ctrl/Cmd+V (paste イベント購読) に一本化する。
              if (clipboardPullSupported)
                PopupMenuItem(
                  value: 'paste_clipboard',
                  child: ListTile(
                    leading: const Icon(Icons.content_paste),
                    title: Text(context.l10n.composePasteFromClipboard),
                    dense: true,
                  ),
                ),
            ],
          ),
          // 入力を破棄ボタン
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: context.l10n.composeDiscardTitle,
            onPressed: _confirmClear,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: context.l10n.composeOptionsTooltip,
            onSelected: (String value) {
              switch (value) {
                case 'scheduled':
                  _openScheduledPosts();
                  break;
                case 'drafts':
                  _openDrafts();
                  break;
                case 'save_draft':
                  _saveNewDraft();
                  break;
              }
            },
            itemBuilder:
                (BuildContext context) => [
                  PopupMenuItem(
                    value: 'scheduled',
                    child: ListTile(
                      leading: const Icon(Icons.schedule),
                      title: Text(context.l10n.composeScheduledManage),
                      dense: true,
                    ),
                  ),
                  PopupMenuItem(
                    value: 'drafts',
                    child: ListTile(
                      leading: const Icon(Icons.article_outlined),
                      title: Text(context.l10n.draftsTitle),
                      dense: true,
                    ),
                  ),
                  PopupMenuItem(
                    value: 'save_draft',
                    child: ListTile(
                      leading: const Icon(Icons.save_alt),
                      title: Text(context.l10n.composeSaveDraftTitle),
                      dense: true,
                    ),
                  ),
                ],
          ),
        ],
      ),
      body: _wrapWithDropTarget(
        context,
        SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // アカウント選択セクション
                      Text(
                        context.l10n.composeAccountSelectLabel,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey.shade700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Consumer(
                          builder: (context, ref, _) {
                            // accounts リストの変化のみで rebuild する
                            // (current 切替や他フィールド変化では rebuild しない)
                            final accounts = ref.watch(authProvider
                                .select((s) => s.accounts));
                            final selectedAccounts =
                                accounts
                                    .where(
                                      (a) => _selectedAccountIds.contains(a.id),
                                    )
                                    .toList();

                            return InkWell(
                              onTap:
                                  () => _showAccountSelectionDialog(
                                    context,
                                    accounts,
                                  ),
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: Theme.of(context).brightness == Brightness.dark
                                        ? Colors.grey.shade600
                                        : Colors.grey.shade300,
                                  ),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child:
                                          selectedAccounts.isEmpty
                                              ? Text(
                                                context.l10n
                                                    .composeSelectAccountsTitle,
                                                style: TextStyle(
                                                  color: Theme.of(context).brightness == Brightness.dark
                                                      ? Colors.grey.shade400
                                                      : Colors.grey.shade600,
                                                ),
                                              )
                                              : Wrap(
                                                spacing: 8,
                                                runSpacing: 4,
                                                children:
                                                    selectedAccounts.map((
                                                      account,
                                                    ) {
                                                      return Chip(
                                                        avatar: Stack(
                                                          children: [
                                                            UserAvatar(
                                                              url: account.avatarUrl,
                                                              radius: 12,
                                                            ),
                                                            if (account.accountColor != null)
                                                              Positioned(
                                                                bottom: 0,
                                                                right: 0,
                                                                child: Container(
                                                                  width: 8,
                                                                  height: 8,
                                                                  decoration: BoxDecoration(
                                                                    color: account.accountColor,
                                                                    shape: BoxShape.circle,
                                                                    border: Border.all(
                                                                      color: Colors.white,
                                                                      width: 1,
                                                                    ),
                                                                  ),
                                                                ),
                                                              ),
                                                          ],
                                                        ),
                                                        label: Text(
                                                          '@${account.username}',
                                                          style:
                                                              const TextStyle(
                                                                fontSize: 12,
                                                              ),
                                                        ),
                                                        deleteIcon: const Icon(
                                                          Icons.close,
                                                          size: 16,
                                                        ),
                                                        onDeleted: () {
                                                          setState(() {
                                                            _selectedAccountIds
                                                                .remove(
                                                                  account.id,
                                                                );
                                                          });
                                                          _updateMaxCharsForSelectedAccount();
                                                          _applyDefaultVisibilityFromPreferences();
                                                        },
                                                        materialTapTargetSize:
                                                            MaterialTapTargetSize
                                                                .shrinkWrap,
                                                        padding: const EdgeInsets.symmetric(horizontal: 4),
                                                        labelPadding: const EdgeInsets.only(left: 4, right: 2),
                                                      );
                                                    }).toList(),
                                              ),
                                    ),
                                    Icon(
                                      Icons.arrow_drop_down,
                                      color: Theme.of(context).brightness == Brightness.dark
                                          ? Colors.grey.shade400
                                          : Colors.grey.shade600,
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 16),

                      // CW警告文入力欄
                      if (_showSpoilerField) ...[
                        Card(
                          elevation: 1,
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Colors.grey.shade800
                              : null,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: TextField(
                              controller: _spoilerController,
                              decoration: InputDecoration(
                                labelText: context.l10n.composeCwLabel,
                                hintText: context.l10n.composeCwHint,
                                border: const OutlineInputBorder(),
                                prefixIcon: Icon(
                                  Icons.warning_outlined,
                                  color: Colors.orange.withValues(
                                    alpha: Theme.of(context).brightness == Brightness.dark ? 0.8 : 1.0,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],

                      // 投稿機能ボタン
                      Row(
                        children: [
                          // CW
                          _buildFeatureButton(
                            icon: Icons.warning_outlined,
                            label: 'CW',
                            isActive: _showSpoilerField,
                            onPressed:
                                () => setState(
                                  () => _showSpoilerField = !_showSpoilerField,
                                ),
                            activeColor: Colors.orange,
                          ),
                          const SizedBox(width: 8),
                          // NSFW
                          _buildFeatureButton(
                            icon: Icons.visibility_off_outlined,
                            label: 'NSFW',
                            isActive: _isNSFW,
                            onPressed: () => setState(() => _isNSFW = !_isNSFW),
                            activeColor: Colors.red,
                          ),
                          const SizedBox(width: 8),
                          // 投票
                          _buildFeatureButton(
                            icon: Icons.poll_outlined,
                            label: context.l10n.composePollLabel,
                            isActive: _showPollCreation,
                            onPressed:
                                () => setState(
                                  () => _showPollCreation = !_showPollCreation,
                                ),
                            activeColor: Colors.green,
                          ),
                          const SizedBox(width: 8),
                          // 予約投稿 (編集モードでは非表示 — Mastodon には
                          // 公開済み投稿の編集を予約する API が無く、
                          // PUT /statuses/:id に scheduled_at は存在しない。
                          // 表示したままだと「保存できたのに予約されない」
                          // ように見える)
                          if (!widget.isEditing) ...[
                            _buildFeatureButton(
                              icon: Icons.schedule_outlined,
                              label: context.l10n.composeScheduleChipLabel,
                              isActive: _showScheduledPost,
                              onPressed: _showScheduledDateTimePicker,
                              activeColor: Colors.blue,
                            ),
                            const SizedBox(width: 8),
                          ],
                          // 実況モード
                          _buildFeatureButton(
                            icon: Icons.live_tv_outlined,
                            label: context.l10n.composeLiveChipLabel,
                            isActive: _liveModeSettings.isEnabled,
                            onPressed: _showLiveModeSettingsDialog,
                            activeColor: Colors.red,
                          ),
                        ],
                      ),

                      // アクティブな機能の詳細表示
                      if (_showScheduledPost && _scheduledAt != null) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context).brightness == Brightness.dark
                                ? Colors.blue.shade900.withValues(alpha: 0.3)
                                : Colors.blue.shade50,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: Theme.of(context).brightness == Brightness.dark
                                  ? Colors.blue.shade700
                                  : Colors.blue.shade200,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.schedule,
                                size: 16,
                                color: Theme.of(context).brightness == Brightness.dark
                                    ? Colors.blue.shade300
                                    : Colors.blue.shade600,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _formatScheduledDateTime(_scheduledAt!),
                                  style: TextStyle(
                                    color: Theme.of(context).brightness == Brightness.dark
                                        ? Colors.blue.shade300
                                        : Colors.blue.shade600,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.close, size: 16),
                                onPressed:
                                    () => setState(() {
                                      _scheduledAt = null;
                                      _showScheduledPost = false;
                                    }),
                                constraints: const BoxConstraints(),
                                padding: EdgeInsets.zero,
                              ),
                            ],
                          ),
                        ),
                      ],

                      if (_liveModeSettings.isEnabled &&
                          _liveModeSettings.hashtags.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context).brightness == Brightness.dark
                                ? Colors.red.shade900.withValues(alpha: 0.3)
                                : Colors.red.shade50,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: Theme.of(context).brightness == Brightness.dark
                                  ? Colors.red.shade700
                                  : Colors.red.shade200,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.live_tv,
                                size: 16,
                                color: Theme.of(context).brightness == Brightness.dark
                                    ? Colors.red.shade300
                                    : Colors.red.shade600,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  context.l10n.composeLiveTag(_liveModeSettings
                                      .formattedHashtags
                                      .join(' ')),
                                  style: TextStyle(
                                    color: Theme.of(context).brightness == Brightness.dark
                                        ? Colors.red.shade300
                                        : Colors.red.shade600,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],

                      if (_mediaItems.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Container(
                          height: 100,
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: Theme.of(context).brightness == Brightness.dark
                                  ? Colors.grey.shade600
                                  : Colors.grey.shade300,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          // 長押しドラッグでメディアの並び順を変更できる。
                          // ReorderableListView は各 child に unique key
                          // (mediaId) を要求する。
                          child: ReorderableListView.builder(
                            padding: const EdgeInsets.all(8),
                            scrollDirection: Axis.horizontal,
                            buildDefaultDragHandles: true,
                            itemCount: _mediaItems.length,
                            itemBuilder: (_, i) => Padding(
                              key: ValueKey(_mediaItems[i].keyId),
                              padding: const EdgeInsets.only(right: 8),
                              child: _buildMediaThumbnail(i),
                            ),
                            onReorder: (oldIndex, newIndex) {
                              setState(() {
                                if (newIndex > oldIndex) newIndex -= 1;
                                final item = _mediaItems.removeAt(oldIndex);
                                _mediaItems.insert(newIndex, item);
                              });
                            },
                          ),
                        ),
                      ],

                      // 投票作成UI
                      if (_showPollCreation) ...[
                        const SizedBox(height: 16),
                        _buildPollCreationUI(),
                      ],

                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ),
              // 下部ツールバーとテキスト入力エリア
              _buildBottomInputSection(),
            ],
          ),
            // フローティング絵文字ピッカー
            if (_showEmojiPicker) _buildFloatingEmojiPicker(),
          ],
        ),
      )),
    );
  }
}
