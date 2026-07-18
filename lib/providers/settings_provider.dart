// lib/providers/settings_provider.dart

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// タイムラインの投稿同士の区切り方。
/// `line` は薄い水平線、`card` は各投稿を角丸カードで包むスタイル。
enum TimelineLayout { line, card }

/// メディア添付のサムネイル表示スタイル。
/// `grid` は枚数別グリッド (16:9 ウィンドウに 1〜4 枚を配置、5 枚以上は
/// +N オーバーレイ)。デフォルト。
/// `horizontal` は従来の横スクロール (1 投稿あたり高さ固定)。
///
/// 宣言順は picker ダイアログの選択肢順序にそのまま反映されるため、
/// 推奨される (デフォルトの) `grid` を先に置く。永続化は
/// `_mediaLayoutToString` 経由の文字列ベースなので、宣言順を変えても
/// 保存済みの設定値には影響しない。
enum MediaLayout { grid, horizontal }

/// OGP プレビューカードの表示スタイル。
/// `standard` は 16:9 ヘッダー画像 + 題名 + 説明 + ドメイン (従来挙動)。
/// `compact` は左に小サムネ + 右に題名 + ドメインの横並び 1〜2 行で、
/// 投稿 1 件あたりの縦幅を大きく節約する。
enum OgpLayout { standard, compact }

/// Deck (ワイド/デスクトップ) のカラム幅の決め方。
/// `flexible` は従来挙動 (ウィンドウ幅に合わせて等分・中央寄せ、収まらなければ
/// 既定幅で横スクロール)。`fixed` は各カラムが指定幅 (`column['width']`) を保ち、
/// 左寄せ + 余白は右、はみ出せば横スクロールする。
enum ColumnWidthMode { flexible, fixed }

/// copyWith で「引数未指定 (= 変更なし)」と「null を明示指定」を区別するための
/// センチネル。nullable フィールド (fontFamily) を null にリセットできるようにする。
const Object _unset = Object();

/// アプリ全体の外観設定モデル
class Settings {
  final bool useRelativeTime;
  final bool showUserId;
  final bool showPostActions;
  final double actionIconSize;   // アクションアイコンサイズ
  final bool confirmReply;       // リプライ時に確認ダイアログを出す
  final bool confirmReblog;      // ブースト時に確認ダイアログを出す
  final bool confirmFavourite;   // お気に入り時に確認ダイアログを出す
  final bool confirmBookmark;    // ブックマーク時に確認ダイアログを出す
  final double fontSize;
  final double lineHeight;

  /// 追加: ユーザー選択フォント (google_fonts のファミリ名)。
  /// null = 端末デフォルト。実体の取得は google_fonts の実行時取得
  /// (lib/utils/app_fonts.dart) で行い、テーマ適用は main.dart _buildTheme。
  final String? fontFamily;

  final Color themeColor;
  final double photoSize;
  final bool isAvatarSquare;
  final double avatarSize;
  final double emojiScale;       // 本文フォントサイズに対する絵文字倍率
  final double emojiScaleInDisplayName;  // 表示名フォントサイズに対する絵文字倍率

  /// 追加: メディアのぼかしを常に解除するフラグ
  final bool disableMediaBlur;

  /// 追加: 投稿の折りたたみ行数（0の場合は無効）
  final int collapseAfterLines;

  /// 追加: デフォルト投稿言語
  final String? defaultPostLanguage;

  /// 追加: リアクション数表示
  final bool showReactionCounts;

  /// 追加: アプリ終了時の確認ダイアログ
  final bool confirmAppExit;

  /// 追加: CWを常に開く
  final bool alwaysExpandCW;

  /// 追加: スリープ無効化（画面の自動消灯を防ぐ）
  final bool keepScreenOn;

  /// 追加: カスタム絵文字のアニメーション設定
  final bool disableCustomEmojiAnimationInDisplayName;  // 表示名でのアニメーション無効化
  final bool disableCustomEmojiAnimationInContent;     // 本文でのアニメーション無効化

  /// 追加: テーマモード (ライト / ダーク / システム)
  final ThemeMode themeMode;

  /// 追加: タイムラインの SSE ストリーミング有効化
  final bool streamingEnabled;

  /// 追加: 解除時 (アンドゥ) の確認ダイアログ。実行時とは独立に制御。
  final bool confirmUnreblog;
  final bool confirmUnfavourite;
  final bool confirmUnbookmark;

  /// 追加: 投稿の via (投稿元アプリ名) 表示
  final bool showVia;

  /// 追加: ワイド幅 (デスクトップ) で投稿ペインを常時固定表示するか。
  /// TweetDeck 風に、タイムライン横に投稿欄を出しっぱなしにする。OFF なら
  /// 投稿ボタンでスライド開閉する。ナロー幅では無視 (常にフルスクリーン投稿)。
  final bool composePaneFixed;

  /// 追加: アプリロック有効フラグ
  final bool appLockEnabled;

  /// 追加: アプリロック解除に生体認証を使うか
  final bool appLockBiometric;

  /// 追加: バックグラウンド復帰時に再ロックするまでの猶予秒数。
  /// 0 = 即時、その他は経過秒以上で再ロック。
  final int appLockTimeoutSeconds;

  /// 追加: タイムラインの投稿同士の区切り方 (line / card)
  final TimelineLayout timelineLayout;

  /// 追加: メディアサムネイルの表示スタイル (horizontal / grid)
  final MediaLayout mediaLayout;

  /// 追加: OGP プレビューカードの表示スタイル (standard / compact)
  final OgpLayout ogpLayout;

  /// 追加: クラッシュレポート送信フラグ。Firebase Crashlytics の自動収集
  /// (モバイル) と Sentry (Web/デスクトップ) を共通でこのフラグで ON/OFF する。
  /// デフォルトは ON (テスター配布フェーズでの不具合調査のため)。
  final bool crashReportingEnabled;

  /// 追加: 利用状況の解析 (Firebase Analytics / GA4) 送信フラグ。Web + Android
  /// で有効。送るのは集計用の真偽値/件数/enum のみで個人特定情報は含まない。
  /// デフォルトは ON (テスター配布フェーズでの利用状況把握のため)。
  final bool analyticsEnabled;

  /// 追加: プッシュ通知 (FCM) の有効化フラグ。Android のみ対象。OFF にすると
  /// 起動時の自動購読登録をスキップし、サーバ側の既存購読も解除する。
  /// デフォルトは ON (従来挙動の維持)。
  final bool pushNotificationsEnabled;

  /// 追加: 通知をグルーピング表示するか。Mastodon 4.3+ の
  /// `/api/v2/notifications` を使ってサーバ集約された「A さん他 N 人がいいね
  /// しました」スタイルで出す。未対応サーバではアカウントごとに v1 に
  /// フォールバックするので OFF と同じ見た目になる。デフォルト OFF。
  final bool groupedNotifications;

  /// 追加: Deck のカラム幅モード (flexible / fixed)。各カラムの幅は
  /// columnProvider 側 (`column['width']`) に保持する。
  final ColumnWidthMode columnWidthMode;

  /// 追加: ボスキー (偽装モード) の有効化。Web / デスクトップ限定の隠し機能。
  /// ON にすると F9 でアプリ全体を Google 風の見た目に切り替えられる。
  /// デフォルト OFF。
  final bool bossKeyEnabled;

  /// 追加: 効果音 (フォアグラウンド限定)。3 イベントを個別に ON/OFF する。
  /// 実際の再生は lib/services/sound_service.dart、音源は assets/sounds/。
  /// 既定はいずれも OFF (opt-in)。
  final bool soundOnNotification; // 通知受信時
  final bool soundOnPost; // 投稿完了時
  final bool soundOnRefresh; // 引っ張って更新時

  /// 追加: デスクトップ (Windows/macOS/Linux) で画像を保存する既定フォルダ。
  /// null / 空 = 未設定 (ダウンロードフォルダ → なければ Documents にフォールバック)。
  final String? imageSaveDirectory;

  /// 追加: 画像保存のたびにネイティブ保存ダイアログで保存先を尋ねるか
  /// (デスクトップのみ)。ON のとき [imageSaveDirectory] は無視される。既定 OFF。
  final bool confirmImageSaveLocation;

  Settings({
    required this.useRelativeTime,
    required this.showUserId,
    required this.showPostActions,
    required this.actionIconSize,
    required this.confirmReply,
    required this.confirmReblog,
    required this.confirmFavourite,
    required this.confirmBookmark,
    required this.fontSize,
    required this.lineHeight,
    this.fontFamily,
    required this.themeColor,
    required this.photoSize,
    required this.isAvatarSquare,
    required this.avatarSize,
    required this.emojiScale,
    required this.emojiScaleInDisplayName,
    required this.disableMediaBlur,
    required this.collapseAfterLines, // 追加
    this.defaultPostLanguage,
    required this.showReactionCounts,
    required this.confirmAppExit,
    required this.alwaysExpandCW,
    required this.keepScreenOn,
    required this.disableCustomEmojiAnimationInDisplayName,
    required this.disableCustomEmojiAnimationInContent,
    required this.themeMode,
    required this.streamingEnabled,
    required this.confirmUnreblog,
    required this.confirmUnfavourite,
    required this.confirmUnbookmark,
    required this.showVia,
    required this.composePaneFixed,
    required this.appLockEnabled,
    required this.appLockBiometric,
    required this.appLockTimeoutSeconds,
    required this.timelineLayout,
    required this.mediaLayout,
    required this.ogpLayout,
    required this.crashReportingEnabled,
    required this.analyticsEnabled,
    required this.pushNotificationsEnabled,
    required this.groupedNotifications,
    required this.columnWidthMode,
    required this.bossKeyEnabled,
    required this.soundOnNotification,
    required this.soundOnPost,
    required this.soundOnRefresh,
    this.imageSaveDirectory,
    required this.confirmImageSaveLocation,
  });

  Settings copyWith({
    bool? useRelativeTime,
    bool? showUserId,
    bool? showPostActions,
    double? actionIconSize,
    bool? confirmReply,
    bool? confirmReblog,
    bool? confirmFavourite,
    bool? confirmBookmark,
    double? fontSize,
    double? lineHeight,
    // fontFamily は null (端末デフォルト) への設定が必要なため sentinel 方式。
    // 既定の `?? this.x` だと null を渡しても旧値が残り「端末デフォルトに戻す」が
    // できない。`_unset` を渡す = 変更なし、それ以外 (null 含む) = その値に設定。
    Object? fontFamily = _unset,
    Color? themeColor,
    double? photoSize,
    bool? isAvatarSquare,
    double? avatarSize,
    double? emojiScale,
    double? emojiScaleInDisplayName,
    bool? disableMediaBlur,
    int? collapseAfterLines, // 追加
    String? defaultPostLanguage,
    bool? showReactionCounts,
    bool? confirmAppExit,
    bool? alwaysExpandCW,
    bool? keepScreenOn,
    bool? disableCustomEmojiAnimationInDisplayName,
    bool? disableCustomEmojiAnimationInContent,
    ThemeMode? themeMode,
    bool? streamingEnabled,
    bool? confirmUnreblog,
    bool? confirmUnfavourite,
    bool? confirmUnbookmark,
    bool? showVia,
    bool? composePaneFixed,
    bool? appLockEnabled,
    bool? appLockBiometric,
    int? appLockTimeoutSeconds,
    TimelineLayout? timelineLayout,
    MediaLayout? mediaLayout,
    OgpLayout? ogpLayout,
    bool? crashReportingEnabled,
    bool? analyticsEnabled,
    bool? pushNotificationsEnabled,
    bool? groupedNotifications,
    ColumnWidthMode? columnWidthMode,
    bool? bossKeyEnabled,
    bool? soundOnNotification,
    bool? soundOnPost,
    bool? soundOnRefresh,
    // imageSaveDirectory も null (既定に戻す) を明示できるよう sentinel 方式。
    Object? imageSaveDirectory = _unset,
    bool? confirmImageSaveLocation,
  }) {
    return Settings(
      useRelativeTime: useRelativeTime ?? this.useRelativeTime,
      showUserId: showUserId ?? this.showUserId,
      showPostActions: showPostActions ?? this.showPostActions,
      actionIconSize: actionIconSize ?? this.actionIconSize,
      confirmReply: confirmReply ?? this.confirmReply,
      confirmReblog: confirmReblog ?? this.confirmReblog,
      confirmFavourite: confirmFavourite ?? this.confirmFavourite,
      confirmBookmark: confirmBookmark ?? this.confirmBookmark,
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      fontFamily: identical(fontFamily, _unset)
          ? this.fontFamily
          : fontFamily as String?,
      themeColor: themeColor ?? this.themeColor,
      photoSize: photoSize ?? this.photoSize,
      isAvatarSquare: isAvatarSquare ?? this.isAvatarSquare,
      avatarSize: avatarSize ?? this.avatarSize,
      emojiScale: emojiScale ?? this.emojiScale,
      emojiScaleInDisplayName: emojiScaleInDisplayName ?? this.emojiScaleInDisplayName,
      disableMediaBlur: disableMediaBlur ?? this.disableMediaBlur,
      collapseAfterLines: collapseAfterLines ?? this.collapseAfterLines, // 追加
      defaultPostLanguage: defaultPostLanguage ?? this.defaultPostLanguage,
      showReactionCounts: showReactionCounts ?? this.showReactionCounts,
      confirmAppExit: confirmAppExit ?? this.confirmAppExit,
      alwaysExpandCW: alwaysExpandCW ?? this.alwaysExpandCW,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      disableCustomEmojiAnimationInDisplayName: disableCustomEmojiAnimationInDisplayName ?? this.disableCustomEmojiAnimationInDisplayName,
      disableCustomEmojiAnimationInContent: disableCustomEmojiAnimationInContent ?? this.disableCustomEmojiAnimationInContent,
      themeMode: themeMode ?? this.themeMode,
      streamingEnabled: streamingEnabled ?? this.streamingEnabled,
      confirmUnreblog: confirmUnreblog ?? this.confirmUnreblog,
      confirmUnfavourite: confirmUnfavourite ?? this.confirmUnfavourite,
      confirmUnbookmark: confirmUnbookmark ?? this.confirmUnbookmark,
      showVia: showVia ?? this.showVia,
      composePaneFixed: composePaneFixed ?? this.composePaneFixed,
      appLockEnabled: appLockEnabled ?? this.appLockEnabled,
      appLockBiometric: appLockBiometric ?? this.appLockBiometric,
      appLockTimeoutSeconds: appLockTimeoutSeconds ?? this.appLockTimeoutSeconds,
      timelineLayout: timelineLayout ?? this.timelineLayout,
      mediaLayout: mediaLayout ?? this.mediaLayout,
      ogpLayout: ogpLayout ?? this.ogpLayout,
      crashReportingEnabled:
          crashReportingEnabled ?? this.crashReportingEnabled,
      analyticsEnabled: analyticsEnabled ?? this.analyticsEnabled,
      pushNotificationsEnabled:
          pushNotificationsEnabled ?? this.pushNotificationsEnabled,
      groupedNotifications:
          groupedNotifications ?? this.groupedNotifications,
      columnWidthMode: columnWidthMode ?? this.columnWidthMode,
      bossKeyEnabled: bossKeyEnabled ?? this.bossKeyEnabled,
      soundOnNotification: soundOnNotification ?? this.soundOnNotification,
      soundOnPost: soundOnPost ?? this.soundOnPost,
      soundOnRefresh: soundOnRefresh ?? this.soundOnRefresh,
      imageSaveDirectory: identical(imageSaveDirectory, _unset)
          ? this.imageSaveDirectory
          : imageSaveDirectory as String?,
      confirmImageSaveLocation:
          confirmImageSaveLocation ?? this.confirmImageSaveLocation,
    );
  }

  Map<String, dynamic> toJson() => {
        'timeMode': useRelativeTime ? 'relative' : 'absolute',
        'showUserId': showUserId,
        'showPostActions': showPostActions,
        'actionIconSize': actionIconSize,
        'confirmReply': confirmReply,
        'confirmReblog': confirmReblog,
        'confirmFavourite': confirmFavourite,
        'confirmBookmark': confirmBookmark,
        'fontSize': fontSize,
        'lineHeight': lineHeight,
        'fontFamily': fontFamily,
        'themeColor': themeColor.toARGB32(),
        'photoSize': photoSize,
        'avatarSquare': isAvatarSquare,
        'avatarSize': avatarSize,
        'emojiScale': emojiScale,
        'emojiScaleInDisplayName': emojiScaleInDisplayName,
        'disableMediaBlur': disableMediaBlur,
        'collapseAfterLines': collapseAfterLines, // 追加
        'defaultPostLanguage': defaultPostLanguage,
        'showReactionCounts': showReactionCounts,
        'confirmAppExit': confirmAppExit,
        'alwaysExpandCW': alwaysExpandCW,
        'keepScreenOn': keepScreenOn,
        'disableCustomEmojiAnimationInDisplayName': disableCustomEmojiAnimationInDisplayName,
        'disableCustomEmojiAnimationInContent': disableCustomEmojiAnimationInContent,
        'themeMode': _themeModeToString(themeMode),
        'streamingEnabled': streamingEnabled,
        'confirmUnreblog': confirmUnreblog,
        'confirmUnfavourite': confirmUnfavourite,
        'confirmUnbookmark': confirmUnbookmark,
        'showVia': showVia,
        'composePaneFixed': composePaneFixed,
        'appLockEnabled': appLockEnabled,
        'appLockBiometric': appLockBiometric,
        'appLockTimeoutSeconds': appLockTimeoutSeconds,
        'timelineLayout': _timelineLayoutToString(timelineLayout),
        'mediaLayout': _mediaLayoutToString(mediaLayout),
        'ogpLayout': _ogpLayoutToString(ogpLayout),
        'crashReportingEnabled': crashReportingEnabled,
        'analyticsEnabled': analyticsEnabled,
        'pushNotificationsEnabled': pushNotificationsEnabled,
        'groupedNotifications': groupedNotifications,
        'columnWidthMode': _columnWidthModeToString(columnWidthMode),
        'bossKeyEnabled': bossKeyEnabled,
        'soundOnNotification': soundOnNotification,
        'soundOnPost': soundOnPost,
        'soundOnRefresh': soundOnRefresh,
        'imageSaveDirectory': imageSaveDirectory,
        'confirmImageSaveLocation': confirmImageSaveLocation,
      };

  factory Settings.fromJson(Map<String, dynamic> m) => Settings(
        useRelativeTime: (m['timeMode'] as String? ?? 'relative') == 'relative',
        showUserId: m['showUserId'] as bool? ?? false,
        showPostActions: m['showPostActions'] as bool? ?? true,
        actionIconSize: (m['actionIconSize'] as num?)?.toDouble() ?? 24.0,
        confirmReply: m['confirmReply'] as bool? ?? false,
        confirmReblog: m['confirmReblog'] as bool? ?? false,
        confirmFavourite: m['confirmFavourite'] as bool? ?? false,
        confirmBookmark: m['confirmBookmark'] as bool? ?? false,
        fontSize: (m['fontSize'] as num?)?.toDouble() ?? 14.0,
        lineHeight: (m['lineHeight'] as num?)?.toDouble() ?? 1.4,
        fontFamily: m['fontFamily'] as String?,
        themeColor: Color(m['themeColor'] as int? ?? 0xFF6750A4),
        photoSize: (m['photoSize'] as num?)?.toDouble() ?? 100.0,
        isAvatarSquare: m['avatarSquare'] as bool? ?? false,
        avatarSize: (m['avatarSize'] as num?)?.toDouble() ?? 48.0,
        emojiScale: (m['emojiScale'] as num?)?.toDouble() ?? 1.0,
        emojiScaleInDisplayName: (m['emojiScaleInDisplayName'] as num?)?.toDouble() ?? 1.0,
        disableMediaBlur: m['disableMediaBlur'] as bool? ?? false,
        collapseAfterLines: m['collapseAfterLines'] as int? ?? 0, // 追加（デフォルト0で無効）
        defaultPostLanguage: m['defaultPostLanguage'] as String?,
        showReactionCounts: m['showReactionCounts'] as bool? ?? true,
        confirmAppExit: m['confirmAppExit'] as bool? ?? true,
        alwaysExpandCW: m['alwaysExpandCW'] as bool? ?? false,
        keepScreenOn: m['keepScreenOn'] as bool? ?? false,
        disableCustomEmojiAnimationInDisplayName: m['disableCustomEmojiAnimationInDisplayName'] as bool? ?? false,
        disableCustomEmojiAnimationInContent: m['disableCustomEmojiAnimationInContent'] as bool? ?? false,
        // 旧バージョンとの互換: 'isDarkMode' (bool) しか保存されていない場合は
        // ライト/ダークの 2 値にマップする。新しい 'themeMode' (string) があれば
        // それを優先。
        themeMode: _parseThemeMode(m),
        streamingEnabled: m['streamingEnabled'] as bool? ?? false,
        // 旧バージョンとの互換: 解除確認は従来 confirmReblog 等と同じ値で
        // 動いていたので、未指定なら同じ値をフォールバックとして引き継ぐ
        confirmUnreblog: m['confirmUnreblog'] as bool? ??
            (m['confirmReblog'] as bool? ?? false),
        confirmUnfavourite: m['confirmUnfavourite'] as bool? ??
            (m['confirmFavourite'] as bool? ?? false),
        confirmUnbookmark: m['confirmUnbookmark'] as bool? ??
            (m['confirmBookmark'] as bool? ?? false),
        showVia: m['showVia'] as bool? ?? false,
        composePaneFixed: m['composePaneFixed'] as bool? ?? false,
        appLockEnabled: m['appLockEnabled'] as bool? ?? false,
        appLockBiometric: m['appLockBiometric'] as bool? ?? true,
        appLockTimeoutSeconds: m['appLockTimeoutSeconds'] as int? ?? 60,
        timelineLayout: _parseTimelineLayout(m['timelineLayout']),
        mediaLayout: _parseMediaLayout(m['mediaLayout']),
        ogpLayout: _parseOgpLayout(m['ogpLayout']),
        crashReportingEnabled:
            m['crashReportingEnabled'] as bool? ?? true,
        analyticsEnabled: m['analyticsEnabled'] as bool? ?? true,
        pushNotificationsEnabled:
            m['pushNotificationsEnabled'] as bool? ?? true,
        groupedNotifications:
            m['groupedNotifications'] as bool? ?? false,
        columnWidthMode: _parseColumnWidthMode(m['columnWidthMode']),
        bossKeyEnabled: m['bossKeyEnabled'] as bool? ?? false,
        soundOnNotification: m['soundOnNotification'] as bool? ?? false,
        soundOnPost: m['soundOnPost'] as bool? ?? false,
        soundOnRefresh: m['soundOnRefresh'] as bool? ?? false,
        imageSaveDirectory: m['imageSaveDirectory'] as String?,
        confirmImageSaveLocation:
            m['confirmImageSaveLocation'] as bool? ?? false,
      );
}

/// StateNotifier で設定を管理
class SettingsNotifier extends StateNotifier<Settings> {
  SettingsNotifier()
      : super(Settings(
          useRelativeTime: true,
          showUserId: false,
          showPostActions: true,
          actionIconSize: 24.0,
          confirmReply: false,
          // 誤タップ防止のため初回インストール時はデフォルト ON。ダイアログの
          // 「今後は表示しない」または設定画面から OFF にできる。
          confirmReblog: true,
          confirmFavourite: true,
          confirmBookmark: true,
          fontSize: 14.0,
          lineHeight: 1.4,
          fontFamily: null, // デフォルトは端末フォント
          themeColor: const Color(0xFF6750A4),
          photoSize: 100.0,
          isAvatarSquare: false,
          avatarSize: 48.0,
          emojiScale: 1.0,
          emojiScaleInDisplayName: 1.0,
          disableMediaBlur: false,
          collapseAfterLines: 0, // 追加（デフォルト0で無効）
          defaultPostLanguage: null, // デフォルトはnull（自動検出）
          showReactionCounts: true,
          confirmAppExit: true, // デフォルトは有効
          alwaysExpandCW: false, // デフォルトは無効
          keepScreenOn: false, // デフォルトは無効
          disableCustomEmojiAnimationInDisplayName: false, // デフォルトは有効（アニメーション）
          disableCustomEmojiAnimationInContent: false, // デフォルトは有効（アニメーション）
          themeMode: ThemeMode.system, // デフォルトは端末設定に追従
          streamingEnabled: true, // 初回インストール時はデフォルト ON (即時更新優先)
          // 解除側も同様に初回 ON。
          confirmUnreblog: true,
          confirmUnfavourite: true,
          confirmUnbookmark: true,
          showVia: false,
          composePaneFixed: false, // ワイド時の既定はスライド開閉 (固定しない)
          appLockEnabled: false, // デフォルト OFF (オプション機能)
          appLockBiometric: true, // 有効化時、端末対応していれば既定で生体使用
          appLockTimeoutSeconds: 60, // 1 分以内の復帰なら再ロックしない
          timelineLayout: TimelineLayout.line, // デフォルトは線区切り (従来挙動)
          mediaLayout: MediaLayout.grid, // デフォルトはグリッド表示
          ogpLayout: OgpLayout.standard, // デフォルトは大ヘッダー画像 (従来挙動)
          crashReportingEnabled: true, // テスター配布フェーズなのでデフォルト ON
          analyticsEnabled: true, // テスター配布フェーズなのでデフォルト ON
          pushNotificationsEnabled: true, // 従来挙動の維持でデフォルト ON
          groupedNotifications: false, // デフォルト OFF (オプトイン)
          columnWidthMode: ColumnWidthMode.flexible, // 既定は従来の可変幅
          bossKeyEnabled: false, // デフォルト OFF (Web/デスクトップ限定の隠し機能)
          soundOnNotification: false, // 効果音は既定 OFF (opt-in)
          soundOnPost: false,
          soundOnRefresh: false,
          imageSaveDirectory: null, // 既定はダウンロードフォルダ
          confirmImageSaveLocation: false, // 既定は尋ねない (黙って保存)
        )) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString('appearanceSettings');
    if (jsonStr != null) {
      try {
        state = Settings.fromJson(jsonDecode(jsonStr));
      } catch (e) {
        // 破損 JSON はデフォルト設定のまま続行 (クラッシュさせない)
        debugPrint('appearanceSettings の読み込みに失敗: $e');
      }
    }
  }

  /// バックアップからの一括インポート。現在の設定を丸ごと置き換えて保存する。
  /// 未知 / 欠損キーは Settings.fromJson のデフォルトで埋まる。
  Future<void> importFromJson(Map<String, dynamic> json) async {
    state = Settings.fromJson(json);
    await _save();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('appearanceSettings', jsonEncode(state.toJson()));
  }

  Future<void> setUseRelativeTime(bool v) async {
    state = state.copyWith(useRelativeTime: v);
    await _save();
  }

  Future<void> setShowUserId(bool v) async {
    state = state.copyWith(showUserId: v);
    await _save();
  }

  Future<void> setShowPostActions(bool v) async {
    state = state.copyWith(showPostActions: v);
    await _save();
  }

  Future<void> setActionIconSize(double v) async {
    state = state.copyWith(actionIconSize: v);
    await _save();
  }

  Future<void> setConfirmReply(bool v) async {
    state = state.copyWith(confirmReply: v);
    await _save();
  }

  Future<void> setConfirmReblog(bool v) async {
    state = state.copyWith(confirmReblog: v);
    await _save();
  }

  Future<void> setConfirmFavourite(bool v) async {
    state = state.copyWith(confirmFavourite: v);
    await _save();
  }

  Future<void> setConfirmBookmark(bool v) async {
    state = state.copyWith(confirmBookmark: v);
    await _save();
  }

  Future<void> setFontSize(double v) async {
    state = state.copyWith(fontSize: v);
    await _save();
  }

  Future<void> setLineHeight(double v) async {
    state = state.copyWith(lineHeight: v);
    await _save();
  }

  /// 追加: ユーザー選択フォント (null = 端末デフォルト)。
  /// copyWith の sentinel 方式により null を明示指定でき「端末デフォルトに戻す」が
  /// 効く。
  Future<void> setFontFamily(String? v) async {
    state = state.copyWith(fontFamily: v);
    await _save();
  }

  Future<void> setThemeColor(Color v) async {
    state = state.copyWith(themeColor: v);
    await _save();
  }

  Future<void> setPhotoSize(double v) async {
    state = state.copyWith(photoSize: v);
    await _save();
  }

  Future<void> setAvatarSquare(bool v) async {
    state = state.copyWith(isAvatarSquare: v);
    await _save();
  }

  Future<void> setAvatarSize(double v) async {
    state = state.copyWith(avatarSize: v);
    await _save();
  }

  /// 絵文字倍率を設定
  Future<void> setEmojiScale(double v) async {
    state = state.copyWith(emojiScale: v);
    await _save();
  }

  /// 表示名での絵文字倍率を設定
  Future<void> setEmojiScaleInDisplayName(double v) async {
    state = state.copyWith(emojiScaleInDisplayName: v);
    await _save();
  }

  /// 追加: メディアのぼかしをオン／オフ
  Future<void> setDisableMediaBlur(bool v) async {
    state = state.copyWith(disableMediaBlur: v);
    await _save();
  }

  /// 追加: 投稿の折りたたみ行数を設定
  Future<void> setCollapseAfterLines(int v) async {
    state = state.copyWith(collapseAfterLines: v);
    await _save();
  }

  /// 追加: デフォルト投稿言語を設定
  Future<void> setDefaultPostLanguage(String? v) async {
    state = state.copyWith(defaultPostLanguage: v);
    await _save();
  }

  /// 追加: リアクション数表示を設定
  Future<void> setShowReactionCounts(bool v) async {
    state = state.copyWith(showReactionCounts: v);
    await _save();
  }

  /// 追加: アプリ終了時確認ダイアログを設定
  Future<void> setConfirmAppExit(bool v) async {
    state = state.copyWith(confirmAppExit: v);
    await _save();
  }

  /// 追加: CWを常に開く設定
  Future<void> setAlwaysExpandCW(bool v) async {
    state = state.copyWith(alwaysExpandCW: v);
    await _save();
  }

  /// 追加: スリープ無効化設定
  Future<void> setKeepScreenOn(bool v) async {
    state = state.copyWith(keepScreenOn: v);
    await _save();
  }

  /// 追加: 表示名でのカスタム絵文字アニメーション無効化設定
  Future<void> setDisableCustomEmojiAnimationInDisplayName(bool v) async {
    state = state.copyWith(disableCustomEmojiAnimationInDisplayName: v);
    await _save();
  }

  /// 追加: 本文でのカスタム絵文字アニメーション無効化設定
  Future<void> setDisableCustomEmojiAnimationInContent(bool v) async {
    state = state.copyWith(disableCustomEmojiAnimationInContent: v);
    await _save();
  }

  /// 追加: テーマモード (ライト / ダーク / システム)
  Future<void> setThemeMode(ThemeMode v) async {
    state = state.copyWith(themeMode: v);
    await _save();
  }

  /// 追加: ストリーミング有効化設定
  Future<void> setStreamingEnabled(bool v) async {
    state = state.copyWith(streamingEnabled: v);
    await _save();
  }

  /// 追加: 解除時 (アンドゥ) の確認ダイアログ
  Future<void> setConfirmUnreblog(bool v) async {
    state = state.copyWith(confirmUnreblog: v);
    await _save();
  }

  Future<void> setConfirmUnfavourite(bool v) async {
    state = state.copyWith(confirmUnfavourite: v);
    await _save();
  }

  Future<void> setConfirmUnbookmark(bool v) async {
    state = state.copyWith(confirmUnbookmark: v);
    await _save();
  }

  /// 追加: via 表示
  Future<void> setShowVia(bool v) async {
    state = state.copyWith(showVia: v);
    await _save();
  }

  /// 追加: 投稿ペイン固定 (ワイド幅で投稿欄を常時表示)
  Future<void> setComposePaneFixed(bool v) async {
    state = state.copyWith(composePaneFixed: v);
    await _save();
  }

  /// 追加: アプリロック有効化
  Future<void> setAppLockEnabled(bool v) async {
    state = state.copyWith(appLockEnabled: v);
    await _save();
  }

  /// 追加: 生体認証使用フラグ
  Future<void> setAppLockBiometric(bool v) async {
    state = state.copyWith(appLockBiometric: v);
    await _save();
  }

  /// 追加: 自動ロック猶予秒数
  Future<void> setAppLockTimeoutSeconds(int v) async {
    state = state.copyWith(appLockTimeoutSeconds: v);
    await _save();
  }

  /// 追加: タイムラインの区切り方 (line / card)
  Future<void> setTimelineLayout(TimelineLayout v) async {
    state = state.copyWith(timelineLayout: v);
    await _save();
  }

  /// 追加: メディアサムネイルの表示スタイル (horizontal / grid)
  Future<void> setMediaLayout(MediaLayout v) async {
    state = state.copyWith(mediaLayout: v);
    await _save();
  }

  /// 追加: OGP プレビューカードの表示スタイル (standard / compact)
  Future<void> setOgpLayout(OgpLayout v) async {
    state = state.copyWith(ogpLayout: v);
    await _save();
  }

  /// 追加: クラッシュレポート送信フラグ。Firebase Crashlytics (モバイル) と
  /// Sentry (Web/デスクトップ) 側にも反映する。main.dart 起動時に prefs から
  /// 直接読んで初期反映しているので、ここでは state 更新のみ行い、
  /// FirebaseCrashlytics / Sentry への通知は呼び出し側 (UI) で行う。
  Future<void> setCrashReportingEnabled(bool v) async {
    state = state.copyWith(crashReportingEnabled: v);
    await _save();
  }

  /// 追加: 利用状況の解析 (Firebase Analytics) 送信フラグ。Firebase 側の
  /// 収集フラグへの反映は呼び出し側 (UI) で AnalyticsService.setEnabled を呼ぶ。
  Future<void> setAnalyticsEnabled(bool v) async {
    state = state.copyWith(analyticsEnabled: v);
    await _save();
  }

  /// 追加: プッシュ通知 (FCM) の有効化フラグ。実際の購読登録 / 解除は
  /// 呼び出し側 (UI) で PushNotificationService を操作する。
  Future<void> setPushNotificationsEnabled(bool v) async {
    state = state.copyWith(pushNotificationsEnabled: v);
    await _save();
  }

  /// 追加: 通知グルーピング表示 (Mastodon 4.3+) の有効化。
  Future<void> setGroupedNotifications(bool v) async {
    state = state.copyWith(groupedNotifications: v);
    await _save();
  }

  Future<void> setColumnWidthMode(ColumnWidthMode v) async {
    state = state.copyWith(columnWidthMode: v);
    await _save();
  }

  /// 追加: ボスキー (偽装モード) の有効化。
  Future<void> setBossKeyEnabled(bool v) async {
    state = state.copyWith(bossKeyEnabled: v);
    await _save();
  }

  /// 追加: 効果音 (フォアグラウンド限定) の各イベント ON/OFF。
  Future<void> setSoundOnNotification(bool v) async {
    state = state.copyWith(soundOnNotification: v);
    await _save();
  }

  Future<void> setSoundOnPost(bool v) async {
    state = state.copyWith(soundOnPost: v);
    await _save();
  }

  Future<void> setSoundOnRefresh(bool v) async {
    state = state.copyWith(soundOnRefresh: v);
    await _save();
  }

  /// 追加: 画像の既定保存先フォルダ (null = 既定のダウンロードフォルダに戻す)。
  /// copyWith の sentinel 方式により null を明示指定できる。
  Future<void> setImageSaveDirectory(String? v) async {
    state = state.copyWith(imageSaveDirectory: v);
    await _save();
  }

  /// 追加: 画像保存時に毎回保存先を尋ねるか (デスクトップのみ)。
  Future<void> setConfirmImageSaveLocation(bool v) async {
    state = state.copyWith(confirmImageSaveLocation: v);
    await _save();
  }
}

/// プロバイダ登録
final settingsProvider =
    StateNotifierProvider<SettingsNotifier, Settings>((ref) {
  return SettingsNotifier();
});

String _themeModeToString(ThemeMode m) {
  switch (m) {
    case ThemeMode.light:
      return 'light';
    case ThemeMode.dark:
      return 'dark';
    case ThemeMode.system:
      return 'system';
  }
}

ThemeMode _parseThemeMode(Map<String, dynamic> m) {
  final s = m['themeMode'] as String?;
  switch (s) {
    case 'light':
      return ThemeMode.light;
    case 'dark':
      return ThemeMode.dark;
    case 'system':
      return ThemeMode.system;
  }
  // 旧バージョン: bool isDarkMode しか保存されていなかった
  final legacy = m['isDarkMode'] as bool?;
  if (legacy != null) return legacy ? ThemeMode.dark : ThemeMode.light;
  return ThemeMode.system;
}

String _timelineLayoutToString(TimelineLayout v) {
  switch (v) {
    case TimelineLayout.line:
      return 'line';
    case TimelineLayout.card:
      return 'card';
  }
}

TimelineLayout _parseTimelineLayout(Object? raw) {
  switch (raw) {
    case 'card':
      return TimelineLayout.card;
    case 'line':
    default:
      return TimelineLayout.line;
  }
}

String _mediaLayoutToString(MediaLayout v) {
  switch (v) {
    case MediaLayout.horizontal:
      return 'horizontal';
    case MediaLayout.grid:
      return 'grid';
  }
}

MediaLayout _parseMediaLayout(Object? raw) {
  switch (raw) {
    case 'grid':
      return MediaLayout.grid;
    case 'horizontal':
    default:
      return MediaLayout.horizontal;
  }
}

String _ogpLayoutToString(OgpLayout v) {
  switch (v) {
    case OgpLayout.standard:
      return 'standard';
    case OgpLayout.compact:
      return 'compact';
  }
}

OgpLayout _parseOgpLayout(Object? raw) {
  switch (raw) {
    case 'compact':
      return OgpLayout.compact;
    case 'standard':
    default:
      return OgpLayout.standard;
  }
}

String _columnWidthModeToString(ColumnWidthMode v) {
  switch (v) {
    case ColumnWidthMode.fixed:
      return 'fixed';
    case ColumnWidthMode.flexible:
      return 'flexible';
  }
}

ColumnWidthMode _parseColumnWidthMode(Object? raw) {
  switch (raw) {
    case 'fixed':
      return ColumnWidthMode.fixed;
    case 'flexible':
    default:
      return ColumnWidthMode.flexible;
  }
}