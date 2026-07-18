// lib/main.dart

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'firebase_options.dart';
import 'services/analytics_service.dart';
import 'services/sentry_config.dart';
import 'pages/announcements_page.dart';
import 'pages/main_page.dart';
import 'pages/notifications_page.dart';
import 'pages/search_page.dart';
import 'pages/dm_page.dart';
import 'pages/my_profile_page.dart';
import 'pages/profile_page.dart';
import 'pages/post_page.dart';
import 'pages/settings_page.dart';
import 'pages/column_settings_page.dart';
import 'pages/app_lock_screen.dart';
import 'pages/boss_mode/boss_mode_gate.dart';
import 'providers/auth_provider.dart';
import 'providers/settings_provider.dart';
import 'providers/announcements_provider.dart';
import 'providers/notifications_provider.dart';
import 'providers/tab_state_provider.dart';
import 'providers/app_lock_provider.dart';
import 'providers/compose_pane_provider.dart';
import 'providers/deck_profile_provider.dart';
import 'providers/deck_popup_provider.dart';
import 'services/app_navigator.dart';
import 'providers/deck_column_settings_provider.dart';
import 'utils/open_profile.dart';
import 'services/push_notification_service.dart';
import 'services/mastodon_api.dart' show migrateCacheKeysIfNeeded;
import 'services/wake_lock_service.dart';
import 'services/app_lock_service.dart';
import 'services/share_intake_service.dart';
import 'l10n/l10n.dart';
import 'utils/app_fonts.dart';
import 'utils/breakpoints.dart';
import 'utils/platform.dart';
import 'utils/snackbar_helpers.dart';

/// Widget ツリー外 (PushNotificationService の通知タップコールバック等) から
/// Riverpod を操作するためのトップレベル ProviderContainer。
final _container = ProviderContainer();

/// 一過性のネットワーク断 (相手サーバが切った / Wi-Fi 瞬断 / TLS ハンドシェイク失敗 等)
/// を判定する。これらは本質的に致命的ではないため Crashlytics には fatal:false で記録し、
/// 「Fatal 件数」を実際のクラッシュ用に温存する。
/// dart:io を import すると web ビルドが落ちるので型名文字列で判定する。
bool _isTransientNetworkError(Object error) {
  switch (error.runtimeType.toString()) {
    case 'ClientException': // package:http (IOClient.send の "Connection closed while receiving data" 等)
    case 'SocketException': // dart:io
    case 'HandshakeException': // dart:io (TLS)
    case 'TlsException': // dart:io
    case 'HttpException': // dart:io
    case 'WebSocketException': // dart:io
    case 'TimeoutException': // dart:async
      return true;
  }
  return false;
}

/// SettingsNotifier の非同期 _load 完了を待たず、SharedPreferences の
/// `appearanceSettings` JSON を直接読んで `crashReportingEnabled` だけ取り出す。
/// runApp 前に Crashlytics の自動収集 ON/OFF を反映するために使う。
Future<bool> _readCrashReportingEnabled() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString('appearanceSettings');
    if (jsonStr == null) return true;
    final m = jsonDecode(jsonStr) as Map<String, dynamic>;
    return m['crashReportingEnabled'] as bool? ?? true;
  } catch (_) {
    return true;
  }
}

/// `_readCrashReportingEnabled` と同型。SettingsNotifier の非同期 _load 完了を
/// 待たず、`appearanceSettings` JSON から `analyticsEnabled` だけ取り出して
/// Analytics 収集 ON/OFF の初期反映に使う。
Future<bool> _readAnalyticsEnabled() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString('appearanceSettings');
    if (jsonStr == null) return true;
    final m = jsonDecode(jsonStr) as Map<String, dynamic>;
    return m['analyticsEnabled'] as bool? ?? true;
  } catch (_) {
    return true;
  }
}

/// BottomNav タブ index → Analytics の screen_name。enum 文字列のみで PII は
/// 含めない。順序は RootPage の 6 タブ (メイン/通知/検索/DM/マイプロフィール/設定)。
String tabScreenName(int index) {
  const names = [
    'main_timeline',
    'notifications',
    'search',
    'dm',
    'my_profile',
    'settings',
  ];
  return (index >= 0 && index < names.length) ? names[index] : 'unknown';
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // サードパーティ素材のライセンスを Flutter 標準のライセンス一覧
  // (showLicensePage) にも登録する。効果音は OtoLogic 提供 (CC BY 4.0) で
  // クレジット表記が必須なため。コールバックは遅延評価 (ライセンス画面を
  // 開いた時だけ走る) なので起動コストには影響しない。
  LicenseRegistry.addLicense(() async* {
    // 遅延評価 (ライセンス画面を開いた時に走る) なので、グローバル l10n は
    // その時点の表示言語を指している。
    yield LicenseEntryWithLineBreaks(
      const <String>['OtoLogic (効果音 / sound effects)'],
      l10n.otoLogicLicenseBody,
    );
  });

  // 起動高速化のため独立した I/O を並列にスタート:
  //  - Crashlytics opt-out フラグの prefs 読み
  //  - Firebase 初期化 (PushNotification と Crashlytics の両方の前提)
  // 最も時間の掛かる Firebase init を Hive 初期化と並走させることで
  // コールドスタート時の白画面時間を短縮する。
  final crashReportingFuture = _readCrashReportingEnabled();
  // Firebase を初期化する対象は **Web (Analytics) と Android (FCM/Crashlytics/
  // Analytics)** のみ。desktop/iOS は firebase_options.dart に設定が無く
  // `currentPlatform` getter が *同期* で UnsupportedError を投げる。これは
  // `Firebase.initializeApp` の引数評価時点で起き、`.catchError` には拾われずに
  // main() ごと unhandled で死ぬ (真っ白画面)。これを避けるため、
  //  (1) 対象プラットフォームを firebaseSupported で先に絞り、
  //  (2) currentPlatform の評価を Future.sync の closure 内に入れて、同期 throw
  //      も Future の失敗として catchError に取り込む (CLAUDE.md 記載の回避策)。
  // firebaseReadyFuture が true になるのは「対象プラットフォーム && init 成功」
  // のときだけなので、後続は firebaseOk だけ見れば対象判定も兼ねられる。
  final firebaseSupported =
      kIsWeb || defaultTargetPlatform == TargetPlatform.android;
  final firebaseReadyFuture = !firebaseSupported
      ? Future<bool>.value(false)
      : (Firebase.apps.isNotEmpty
          ? Future<bool>.value(true)
          : Future<void>.sync(() => Firebase.initializeApp(
                  options: DefaultFirebaseOptions.currentPlatform))
              .then((_) => true)
              .catchError((Object e) {
              debugPrint('Firebase 初期化エラー: $e');
              return false;
            }));

  // Hive は runApp 前に open まで完了している必要がある:
  // `mastodon_api.dart` がトップレベルで `Hive.box<String>('timelineCache')`
  // を読むため、box が開いていないと最初の API 呼び出しで落ちる。
  //
  // Web では `path_provider_web` が `getApplicationDocumentsDirectory` を
  // 実装しておらず MissingPluginException で死ぬため、呼び出し自体を skip。
  // `Hive.initFlutter` は kIsWeb なら path 引数を無視して IndexedDB に
  // 書くだけなので、null 渡しで問題ない。
  String? appDocPath;
  if (!kIsWeb) {
    appDocPath = (await getApplicationDocumentsDirectory()).path;
  }
  await Hive.initFlutter(appDocPath);
  await Hive.openBox<String>('timelineCache');

  // 旧形式 (`timeline_*` / `account_*_statuses`) のキャッシュキーを掃除。
  // 旧形式は複数アカウント間で衝突しており信頼できないため、起動時に
  // 一度だけ全消去して fresh fetch に任せる。新形式 (`tl:` / `acct:`
  // プレフィックス) のキーには触らない。
  migrateCacheKeysIfNeeded();

  // Crashlytics エラーフック (Web は未対応プラットフォームなのでスキップ)。
  // 初期フレーム前に登録しないと最初の数フレームで起きたクラッシュを
  // 報告できないため runApp 前に置く。Firebase init を並列で走らせて
  // いるので、ここで await しても Hive 処理と重なって実質ノーコスト。
  if (!kIsWeb) {
    try {
      final firebaseOk = await firebaseReadyFuture;
      if (firebaseOk) {
        final enabled = await crashReportingFuture;
        await FirebaseCrashlytics.instance
            .setCrashlyticsCollectionEnabled(enabled);
        FlutterError.onError = (details) {
          FlutterError.presentError(details);
          if (_isTransientNetworkError(details.exception)) {
            FirebaseCrashlytics.instance
                .recordFlutterError(details); // 非致命扱い
          } else {
            FirebaseCrashlytics.instance.recordFlutterFatalError(details);
          }
        };
        PlatformDispatcher.instance.onError = (error, stack) {
          final fatal = !_isTransientNetworkError(error);
          FirebaseCrashlytics.instance
              .recordError(error, stack, fatal: fatal);
          return true;
        };
      }
    } catch (e) {
      debugPrint('Crashlytics 初期化エラー: $e');
    }
  }

  // アプリロック: 永続化された有効化フラグを runApp 前に確認し、
  // 必要なら AppLockNotifier を初期ロック状態にしてから UI を起動する。
  // (SettingsNotifier._load() の非同期完了を待たないため、最初のフレームから
  //  正しくロック画面を出せる)
  try {
    final shouldLock = await AppLockService.instance.shouldStartLocked();
    if (shouldLock) {
      _container.read(appLockProvider.notifier).lock();
    }
  } catch (e) {
    debugPrint('アプリロック初期化エラー: $e');
  }

  // 通知ページのアカウント選択/フィルタの保存値を runApp 前に読み込む。
  // NotificationsNotifier._init (初回フレームのナビバッジ watch で即生成) と
  // 通知ページの initState が参照するため、ここで await しておかないと
  // 「保存選択なし」と誤認して accounts.first へのフォールバックフェッチや
  // 全アカウント自動選択が走る (旧実装は _initDeferredServices でプッシュ
  // 初期化の数秒後に回しており、起動時は常に空読みになっていた)。
  // SharedPreferences は上の AppLockService で既にロード済みなので実質ノーコスト。
  try {
    await NotificationsNotifier.loadSavedSettings();
  } catch (e) {
    debugPrint('通知設定の読み込みエラー: $e');
  }

  void appRunner() {
    runApp(
      UncontrolledProviderScope(
        container: _container,
        child: const MyApp(),
      ),
    );
  }

  // エラー収集: モバイルは上の Crashlytics、Web/デスクトップは Sentry。
  // Sentry の init は Web/デスクトップ限定なので、モバイルの Crashlytics が握る
  // FlutterError.onError / PlatformDispatcher.onError とは排他になり二重計上
  // しない。DSN 未設定 (sentry_config.dart が空) のときは init せず素の runApp。
  // 送信可否は crashReportingEnabled と連動 (beforeSend で live 反映)。
  final useSentry = isWebOrDesktop() && sentryDsn.isNotEmpty;
  if (useSentry) {
    sentryReportingEnabled = await crashReportingFuture;
    await SentryFlutter.init(
      (options) {
        options.dsn = sentryDsn;
        options.sendDefaultPii = false; // 個人特定情報は送らない
        // クラッシュレポート OFF のときはイベントを破棄 (ライブにオプトアウト)。
        options.beforeSend =
            (event, hint) => sentryReportingEnabled ? event : null;
      },
      appRunner: appRunner,
    );
  } else {
    appRunner();
  }

  // 初期フレーム描画後にバックグラウンドで初期化するもの:
  // - PushNotificationService.initialize (内部で FCM token 取得 + 各アカウント
  //   の `/api/v1/push/subscription` 登録 HTTP まで走るので 1〜数秒)
  // 初回フレームの内容には影響しないため await を runApp 後に逃がす。
  // 通知タップでの遷移は `onTapNotification` 登録までは動かないが、起動直後
  // 数秒の間にユーザーが通知タップする頻度は極めて低く許容範囲。
  unawaited(_initDeferredServices(firebaseReadyFuture));
}

/// `runApp` の後に走らせる「初期フレームに影響しない」初期化処理。
Future<void> _initDeferredServices(Future<bool> firebaseReadyFuture) async {
  final firebaseOk = await firebaseReadyFuture;

  // 利用状況の解析 (Firebase Analytics)。firebaseReadyFuture が true になるのは
  // Web/Android で init 成功したときだけなので available=firebaseOk で足りる。
  try {
    final analyticsEnabled = await _readAnalyticsEnabled();
    await AnalyticsService.instance
        .configure(available: firebaseOk, enabled: analyticsEnabled);
    // 初期画面 (現在タブ) の screen_view を 1 回だけ送る。以後のタブ遷移は
    // RootPage の ref.listen で送る (configure 完了後なので確実に乗る)。
    AnalyticsService.instance
        .logScreenView(tabScreenName(_container.read(tabStateProvider)));
  } catch (e) {
    debugPrint('Analytics 初期化エラー: $e');
  }

  // FCM は Web で動かない (firebase_options に web を足したことで firebaseOk が
  // web でも true になり得るため、明示的に !kIsWeb で弾く)。
  if (!kIsWeb && firebaseOk) {
    try {
      final pushEnabled =
          await PushNotificationService.readPushEnabledFromPrefs();
      await PushNotificationService().initialize(
        onTapNotification: () {
          _container.read(tabStateProvider.notifier).setTabIndex(1);
        },
        autoRegister: pushEnabled,
      );
    } catch (e) {
      debugPrint('プッシュ通知の初期化エラー: $e');
    }
  }
}

/// CJK (漢字) を日本語字形で出すための Noto Sans JP フォールバック。
///
/// CanvasKit / OS の自動フォールバックが Han ideograph に中国語字形の Noto を
/// 選ぶ前に、明示指定した Noto Sans JP を優先させる ("直" 等の修正本体)。
/// google_fonts の実行時取得で CDN から取得 → 端末キャッシュ。結果は不変なので
/// 1 回だけロードしてキャッシュする (通常 + 太字 w700 を登録)。
List<String>? _cachedNotoFallback;
bool _notoFallbackResolved = false;

List<String>? _notoSansJpFallback() {
  if (_notoFallbackResolved) return _cachedNotoFallback;
  _notoFallbackResolved = true;
  final family = GoogleFonts.notoSansJp().fontFamily;
  GoogleFonts.notoSansJp(fontWeight: FontWeight.w700);
  _cachedNotoFallback = family == null ? null : [family];
  return _cachedNotoFallback;
}

/// 設定の選択フォントとプラットフォームから、テーマに渡す
/// (primary fontFamily, fontFamilyFallback) を解決する。
///
/// - **primary**: ユーザーが選んだ書体 (Settings.fontFamily)。null = 端末
///   デフォルト。google_fonts の実行時取得をトリガし解決済みファミリ名を使う。
/// - **fallback (Noto Sans JP)**: CJK を JP 字形に保つ保険。
///   - 既定 (未選択): web/デスクトップのみ付与 (端末フォントが非 JP のため)。
///     モバイルは OS 日本語フォントで正しく出るので付与しない = DL なし。
///   - カスタム: 選んだ書体が CJK を内包しない場合だけ付与 (内包書体なら不要で
///     余計な DL を避ける。厳選 7 書体は全て日本語書体なので実質付与しない)。
({String? family, List<String>? fallback}) _resolveThemeFonts(Settings settings) {
  final key = settings.fontFamily;
  String? primary;
  var customCoversJp = false;
  if (key != null) {
    final font = appFontByKey(key);
    if (font != null) {
      primary = font.ensureLoadedFamily();
      customCoversJp = font.coversJapanese;
    } else {
      // 未知のキー (将来削除された書体等) はそのままファミリ名として試す。
      primary = key;
    }
  }
  final useJpFallback = key == null ? isWebOrDesktop() : !customCoversJp;
  return (
    family: primary,
    fallback: useJpFallback ? _notoSansJpFallback() : null,
  );
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);

    // 表示言語の決定。BuildContext の無い層 (services / 例外メッセージ) が
    // 参照するグローバル l10n も、ここで必ず同じ locale に同期させる。
    const appLocale = Locale('ja');
    updateGlobalL10n(appLocale);

    return MaterialApp(
      title: 'Kurage',
      navigatorKey: appNavigatorKey,
      theme: _buildTheme(settings, Brightness.light),
      darkTheme: _buildTheme(settings, Brightness.dark),
      themeMode: settings.themeMode,
      // TODO(v1.1.0): 全文言の英訳が完了したら resolveAppLocale(settings.appLocale)
      // ベースの解決に切り替え、設定画面に言語ピッカーを追加して解放する
      // (docs/i18n.md 参照)。それまでは従来どおり日本語固定。
      locale: appLocale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // ボスキー (偽装モード) のゲートを Navigator より上に被せる。これにより
      // 偽装シェルがダイアログ/ポップアップ/SnackBar も含めて全面を覆い、裏の
      // 本体は Offstage で生存する。Web/デスクトップ以外では素通し。
      builder: (context, child) =>
          BossModeGate(child: child ?? const SizedBox.shrink()),
      // Web では PC ユーザがマウスドラッグで投稿本文を選択 → コピー
      // できるよう SelectionArea で全体を包む。モバイル (Android/iOS) では
      // 既存の長押しジェスチャ (アクションバー展開・sensitive ぼかし解除等)
      // と衝突しうるので適用しない。ダイアログは Overlay 経由なのでこの
      // 範囲外、SelectionArea の影響を受けない (= 適用したい時はダイアログ
      // 個別に SelectableText 等を使う)。
      home: kIsWeb
          ? const SelectionArea(child: LockGate(child: RootPage()))
          : const LockGate(child: RootPage()),
    );
  }
  
  ThemeData _buildTheme(Settings settings, Brightness brightness) {
    final isDark = brightness == Brightness.dark;

    // デフォルトの紫色かチェック
    final isDefaultColor = settings.themeColor == const Color(0xFF6750A4);

    // ユーザー選択フォント (primary) + CJK を JP 字形に保つフォールバックを解決。
    final fonts = _resolveThemeFonts(settings);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      // ユーザーが書体を選んでいればそれを primary に (null = 端末デフォルト)。
      fontFamily: fonts.family,
      // CJK の中国語字形対策。既定は web/デスクトップのみ、カスタム時は CJK 非対応
      // 書体選択時のみ Noto Sans JP を補う (_resolveThemeFonts 参照)。
      fontFamilyFallback: fonts.fallback,
      colorSchemeSeed: isDefaultColor ? null : settings.themeColor,
      // ダークモード時の背景色をより暗く設定
      scaffoldBackgroundColor: isDark ? Colors.black : null,
      // カード等の背景色
      cardColor: isDark ? Colors.grey[900] : null,
      // AppBarの色設定
      appBarTheme: AppBarTheme(
        backgroundColor: isDark ? Colors.grey[900] : null,
        foregroundColor: isDark ? Colors.white : null,
        elevation: isDark ? 0 : null,
        // Material 3 の「scrolled under」(下にコンテンツが入った時にやや tint
        // される) を無効化。SliverAppBar を使う通知 / DM / 設定ページだけが
        // 色変化していて、scrollable_positioned_list ベースのタイムラインでは
        // 反応しなかったため、ページ間で挙動を揃えるためグローバルに OFF。
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      // BottomNavigationBarの色設定
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: isDark ? Colors.grey[900] : null,
        selectedItemColor: isDefaultColor ? null : settings.themeColor,
        unselectedItemColor: isDark ? Colors.grey[400] : null,
      ),
      // カスタムカラーが設定されている場合のみ、個別の色設定を適用
      progressIndicatorTheme: isDefaultColor ? null : ProgressIndicatorThemeData(
        color: settings.themeColor,
        circularTrackColor: settings.themeColor.withValues(alpha: 0.2),
        linearTrackColor: settings.themeColor.withValues(alpha: 0.2),
      ),
      // スイッチの色設定
      switchTheme: isDefaultColor ? null : SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return settings.themeColor;
          }
          return null;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return settings.themeColor.withValues(alpha: 0.5);
          }
          return null;
        }),
      ),
      // チェックボックスの色設定
      checkboxTheme: isDefaultColor ? null : CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return settings.themeColor;
          }
          return null;
        }),
      ),
      // テキストフィールドの色設定
      inputDecorationTheme: isDefaultColor ? null : InputDecorationTheme(
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: settings.themeColor, width: 2),
        ),
        focusColor: settings.themeColor,
      ),
      // Web ではスクロールバーを常時表示 + 少し太め。デスクトップユーザは
      // 「コンテンツの長さを視覚的に把握できる」ことを期待するため、
      // モバイル流の auto-hide ではなく TweetDeck / 一般的な Web アプリと
      // 同じ常時可視に揃える。ネイティブ (mobile/desktop) は OS 慣習に従う。
      scrollbarTheme: kIsWeb
          ? const ScrollbarThemeData(
              thumbVisibility: WidgetStatePropertyAll(true),
              thickness: WidgetStatePropertyAll(8),
              radius: Radius.circular(4),
            )
          : null,
    );
  }
}

/// アプリロック有効時に、ロック状態に応じて子 widget または `AppLockScreen` を出す。
///
/// ライフサイクル監視は `_RootPageState` 側でも別目的 (Wake Lock 等) でやっているが、
/// ロック判定はロック中であろうと無かろうと走る必要があるので、
/// ロック判定専用の Observer をここに置いている (より上位)。
class LockGate extends ConsumerStatefulWidget {
  final Widget child;
  const LockGate({super.key, required this.child});

  @override
  ConsumerState<LockGate> createState() => _LockGateState();
}

class _LockGateState extends ConsumerState<LockGate>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    final notifier = ref.read(appLockProvider.notifier);
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        notifier.onAppPaused();
        break;
      case AppLifecycleState.resumed:
        notifier.onAppResumed();
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final locked = ref.watch(appLockProvider).locked;
    // 子を Offstage で残しておくことで、ロック解除後に State (スクロール位置・
    // タイムラインキャッシュ・SSE 接続等) が破棄されない。
    return Stack(
      children: [
        Offstage(offstage: locked, child: TickerMode(enabled: !locked, child: widget.child)),
        if (locked) const AppLockScreen(),
      ],
    );
  }
}

class RootPage extends ConsumerStatefulWidget {
  const RootPage({super.key});

  @override
  ConsumerState<RootPage> createState() => _RootPageState();
}

class _RootPageState extends ConsumerState<RootPage> with WidgetsBindingObserver {
  // 現在タブは tabStateProvider が真実のソース。プッシュ通知タップ等から
  // Widget ツリー外で書き換えられるよう Riverpod 経由にしてある。
  static const List<Widget> _pages = [
    MainPage(),             // メインタイムライン
    NotificationsPage(),    // 通知
    SearchPage(),           // 検索
    DmPage(),               // DM
    MyProfilePage(),        // マイプロフィール
    SettingsPage(),         // 設定
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 初期状態でWake Lockを設定
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final settings = ref.read(settingsProvider);
      WakeLockService.updateFromSettings(settings.keepScreenOn);
      // 「他アプリの共有」経由で起動された場合、ネイティブ側に貯まっている
      // テキストを取り出して投稿画面に流し込む。コールドスタート時もここで
      // 拾える (MainActivity.onCreate でテキストはすでに captured 済み)。
      _consumeSharedTextIfReady();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WakeLockService.disable(); // アプリ終了時にWake Lockを無効化
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    final settings = ref.read(settingsProvider);
    
    switch (state) {
      case AppLifecycleState.resumed:
        // アプリがフォアグラウンドに戻った時、設定に応じてWake Lockを適用
        if (settings.keepScreenOn) {
          WakeLockService.enable();
        }
        // 別アプリから共有されて切り替わって戻ってきた可能性があるので、
        // 共有テキストの取り込みを再試行する (空ならネイティブ側で no-op)。
        _consumeSharedTextIfReady();
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        // アプリがバックグラウンドに移った時、Wake Lockを無効化
        WakeLockService.disable();
        break;
      case AppLifecycleState.inactive:
        // 特に何もしない（一時的な状態）
        break;
      case AppLifecycleState.hidden:
        // 特に何もしない
        break;
    }
  }

  /// 「他アプリの共有」経由で渡された text/plain があれば PostPage を開く。
  ///
  /// - ネイティブ側 (MainActivity) は ACTION_SEND の Intent を捕捉して
  ///   pendingSharedText に保持しており、最初にここで取り出すと同時に
  ///   クリアされる仕組み。何度呼んでも 2 回目以降は no-op になる。
  /// - アプリロック中は PostPage を出さない。ロック解除後の resumed で
  ///   再試行されるか、ロック画面が消えた直後の build → ref.listen でも
  ///   再試行する (下の build 内 ref.listen 参照)。
  /// - アカウント未登録時は投稿先がないので SnackBar で案内のみ。
  bool _isHandlingSharedText = false; // 二重起動防止
  Future<void> _consumeSharedTextIfReady() async {
    if (_isHandlingSharedText) return;
    if (!mounted) return;

    // ロック中はスキップ。ロック解除時に再度呼ばれるパスがある。
    final locked = ref.read(appLockProvider).locked;
    if (locked) return;

    _isHandlingSharedText = true;
    try {
      final text =
          await ShareIntakeService.instance.consumePendingSharedText();
      if (text == null || text.isEmpty || !mounted) return;

      // アカウント未登録の場合は投稿できない旨を案内して終了
      final accounts = ref.read(authProvider).accounts;
      if (accounts.isEmpty) {
        showErrorSnackBar(context, context.l10n.shareNoAccountError);
        return;
      }

      // 投稿画面を上に push する (現在地が他のページでも構わない)。
      // タブを 0 (メイン) に戻すと既存の遷移を破壊するので、現状維持で開く。
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PostPage(initialText: text),
        ),
      );
    } finally {
      _isHandlingSharedText = false;
    }
  }

  // バッジ付きアイコンを作成するヘルパーメソッド
  Widget _buildNavIcon(IconData icon, int badgeCount) {
    if (badgeCount > 0) {
      return Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(icon),
          Positioned(
            right: -8,
            top: -4,
            child: Container(
              padding: const EdgeInsets.all(2),
              constraints: const BoxConstraints(
                minWidth: 16,
                minHeight: 16,
              ),
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                badgeCount > 99 ? '99+' : badgeCount.toString(),
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
    }
    return Icon(icon);
  }

  /// アプリ終了確認ダイアログ
  Future<bool> _showExitConfirmationDialog(BuildContext context) async {
    debugPrint('RootPage showing exit confirmation dialog');
    
    bool dontShowAgain = false;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(context.l10n.exitConfirmTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.l10n.exitConfirmMessage),
              const SizedBox(height: 16),
              Row(
                children: [
                  Checkbox(
                    value: dontShowAgain,
                    onChanged: (value) {
                      setState(() {
                        dontShowAgain = value ?? false;
                      });
                    },
                  ),
                  Expanded(
                    child: Text(context.l10n.dontShowThisConfirmationAgain),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(context.l10n.cancel),
            ),
            TextButton(
              onPressed: () async {
                // チェックボックスがオンの場合は設定を更新
                if (dontShowAgain) {
                  await ref.read(settingsProvider.notifier).setConfirmAppExit(false);
                }
                if (context.mounted) {
                  Navigator.of(context).pop(true);
                }
              },
              child: Text(context.l10n.exit),
            ),
          ],
        ),
      ),
    );

    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final currentIndex = ref.watch(tabStateProvider);

    // ロック解除の瞬間に共有テキストの取り込みを再試行する。
    // (initState / resumed のパスではロック中スキップしているため、
    //  ロック中に共有起動された場合はここで拾う)
    ref.listen(appLockProvider, (prev, next) {
      if (prev != null && prev.locked && !next.locked) {
        _consumeSharedTextIfReady();
      }
    });

    // タブ遷移を Analytics の screen_view として送る。初期タブ (起動直後) は
    // _initDeferredServices 側で 1 回送るので、ここは変化時のみ (重複回避)。
    ref.listen(tabStateProvider, (prev, next) {
      if (prev != next) {
        AnalyticsService.instance.logScreenView(tabScreenName(next));
      }
    });

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        debugPrint('=== RootPage PopScope START ===');
        debugPrint('didPop: $didPop, currentIndex: $currentIndex');

        if (didPop) {
          debugPrint('Already popped, returning');
          return;
        }

        if (currentIndex == 0) {
          debugPrint('On MainPage (index 0) - checking exit confirmation');
          final settings = ref.read(settingsProvider);
          debugPrint('confirmAppExit setting: ${settings.confirmAppExit}');

          if (settings.confirmAppExit) {
            debugPrint('Showing exit confirmation dialog');
            final shouldPop = await _showExitConfirmationDialog(context);
            debugPrint('Exit confirmation result: $shouldPop');
            if (shouldPop) {
              debugPrint('User confirmed exit - calling SystemNavigator.pop()');
              SystemNavigator.pop();
            } else {
              debugPrint('User cancelled exit');
            }
          } else {
            debugPrint('Exit confirmation disabled - calling SystemNavigator.pop()');
            SystemNavigator.pop();
          }
        } else {
          debugPrint('On other page (index $currentIndex) - returning to MainPage');
          ref.read(tabStateProvider.notifier).setTabIndex(0);
          debugPrint('Successfully switched to MainPage');
        }
        debugPrint('=== RootPage PopScope END ===');
      },
      child: kIsWeb
          ? _wrapWithKeyboardShortcuts(
              context, _buildScaffold(context, currentIndex))
          : _buildScaffold(context, currentIndex),
    );
  }

  /// Web (デスクトップ) 用のグローバルキーボードショートカット。
  /// - `n` : 新規投稿
  /// - `/` : 検索タブへ
  /// - `j` / `k` : メインタブでアクティブなタイムラインを 1 件下 / 上へ
  ///
  /// 何もフォーカスされていない時でもキーを拾えるよう Focus(autofocus) で
  /// 既定のフォーカス保持者を用意する (メインタブにはテキスト入力欄が無いので
  /// 起動時の autofocus 競合は起きない)。
  ///
  /// **テキスト入力中はショートカットを一切横取りしない**: web では TextField
  /// への文字入力はブラウザの入力経路 (composing/beforeinput) で行われ、keydown
  /// 自体は EditableText に消費されず `ignored` のまま祖先のこのハンドラまで
  /// 伝播してくる。ここで `handled` を返すと Flutter web が元の keydown に
  /// preventDefault をかけ、ショートかットと衝突する文字 (j/k/n/`/`) が入力欄に
  /// 入らなくなる (ワイドのインライン投稿ペインや検索欄で「k が打てない」等の
  /// 症状になる)。そのため primaryFocus が EditableText の時は明示的に
  /// `ignored` を返してブラウザ側の入力に委ねる。
  ///
  /// Esc でのダイアログ閉じは Flutter の ModalBarrier (barrierDismissible) が
  /// 既定で処理するため、ここでは扱わない。
  Widget _wrapWithKeyboardShortcuts(BuildContext context, Widget child) {
    void jump(int delta) {
      // j/k はメインタブ (タイムライン) でのみ有効。
      if (ref.read(tabStateProvider) != 0) return;
      ref.read(timelineJumpProvider)?.call(delta);
    }

    void openNew() {
      // ワイドは横ペインをトグル、ナローはフルスクリーン push。
      if (isWideLayout(context)) {
        _onComposeButtonPressed();
      } else {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const PostPage()),
        );
      }
    }

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        // 押下のみ反応 (j/k はリピートでの連続スクロールを許可)。
        final isDown = event is KeyDownEvent;
        final isRepeat = event is KeyRepeatEvent;
        if (!isDown && !isRepeat) return KeyEventResult.ignored;

        // テキスト入力中は横取りしない (上記コメント参照)。
        // primaryFocus の context が指す widget は EditableText 本体ではなく
        // EditableText が内部生成する子の Focus なので、`is EditableText` では
        // 判定できない。祖先方向に EditableText を探す。
        final focusedContext = FocusManager.instance.primaryFocus?.context;
        if (focusedContext != null &&
            (focusedContext.widget is EditableText ||
                focusedContext.findAncestorWidgetOfExactType<EditableText>() !=
                    null)) {
          return KeyEventResult.ignored;
        }

        // 修飾キー併用 (Ctrl/Cmd/Alt + key) はブラウザ/OS に委ねる。
        final keyboard = HardwareKeyboard.instance;
        if (keyboard.isControlPressed ||
            keyboard.isMetaPressed ||
            keyboard.isAltPressed) {
          return KeyEventResult.ignored;
        }

        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.keyJ) {
          jump(1);
        } else if (key == LogicalKeyboardKey.keyK) {
          jump(-1);
        } else if (isDown && key == LogicalKeyboardKey.keyN) {
          openNew();
        } else if (isDown && key == LogicalKeyboardKey.slash) {
          ref.read(tabStateProvider.notifier).setTabIndex(2);
        } else {
          return KeyEventResult.ignored;
        }
        return KeyEventResult.handled;
      },
      child: child,
    );
  }

  /// Deck (ワイド) でホーム (タイムライン) の上に重ねるポップアップ群を、
  /// 画面全体に広がる overlay のリストとして返す。呼び出し側 (Scaffold body の
  /// Stack) でレール + 投稿ペイン + タイムラインの Row の「上」に重ねることで、
  /// 通知/検索/DM/プロフィール/設定や各種ポップアップを、レール / 投稿ペインも
  /// 含めた画面全体に対して中央寄せ + 暗幕で覆って表示する (通知フィルターの
  /// showDialog と同じ挙動)。大画面でページが横に広がりすぎる問題は
  /// [_deckPopupFrame] の幅制限で引き続き解消される。
  ///
  /// バッジ/SSE は provider 寿命で動く (NavigationRail が unread 系を watch して
  /// 生かし続ける) ため、ページ未表示時にアンマウントしても背景動作は壊れない。
  List<Widget> _buildDeckOverlays(int currentIndex) {
    final profileReq = ref.watch(deckProfileProvider);
    final popupReq = ref.watch(deckPopupProvider);
    final columnSettingsOpen = ref.watch(deckColumnSettingsProvider);
    return [
      // プロフィール / 汎用ページ (ハッシュタグ・スレッド等) ポップアップが
      // 開いていれば最優先で表示し、ナビのページポップアップは隠す (閉じれば
      // 下のナビポップアップ/ホームに戻る)。プロフィールと汎用はルートから
      // 同時に開かない (ポップアップ内からはその nested Navigator に push)。
      if (profileReq != null)
        _buildDeckProfilePopup(profileReq)
      else if (popupReq != null)
        _buildDeckGenericPopup(popupReq)
      else if (currentIndex > 0 && currentIndex < _pages.length)
        _buildDeckPopup(currentIndex),
      // カラム設定ポップアップ。ホームのカラムヘッダーから開く専用なので、
      // ホーム (currentIndex 0) のとき以外は出てこない。最前面に重ねる。
      if (columnSettingsOpen) _buildDeckColumnSettingsPopup(),
    ];
  }

  /// ホームに重ねる「プロフィール」ポップアップ。中身は nested Navigator なので、
  /// ポップアップ内で別ユーザー/フォロワー/フォロー中などを開くとその中で
  /// スタックされ (自動の戻る矢印で 1 つ戻る)、最初のプロフィールの戻る (←) /
  /// 背景タップでポップアップ全体を閉じる。
  Widget _buildDeckProfilePopup(DeckProfileRequest req) {
    void close() => ref.read(deckProfileProvider.notifier).close();
    return _deckPopupFrame(
      onBarrierTap: close,
      child: DeckPopupScope(
        child: Navigator(
          key: ValueKey('deck_profile_nav_${req.seq}'),
          onGenerateInitialRoutes: (navigator, initialRoute) => [
            MaterialPageRoute(
              builder: (_) => ProfilePage(
                user: req.user,
                targetAccountId: req.targetAccountId,
                targetUsername: req.targetUsername,
                targetInstanceUrl: req.targetInstanceUrl,
                onDeckBack: close,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// ホームに重ねる汎用ページポップアップ (ハッシュタグ / スレッド / 編集履歴 /
  /// リアクション一覧 / 通報 など、タイムラインや投稿から開くページ)。中身は
  /// nested Navigator なので、ポップアップ内で別ページを開くとその中でスタック
  /// され (自動の戻る矢印で 1 つ戻る)、最初のページの戻る (←) / 背景タップで
  /// ポップアップ全体を閉じる。プロフィール ([deckProfileProvider]) と同じ仕組み。
  Widget _buildDeckGenericPopup(DeckPopupRequest req) {
    void close() => ref.read(deckPopupProvider.notifier).close();
    return _deckPopupFrame(
      onBarrierTap: close,
      child: DeckPopupScope(
        child: Navigator(
          key: ValueKey('deck_popup_nav_${req.seq}'),
          onGenerateInitialRoutes: (navigator, initialRoute) => [
            MaterialPageRoute(builder: (_) => req.builder(close)),
          ],
        ),
      ),
    );
  }

  /// ホームのカラムヘッダー (⋮ → カラムを編集) から開くカラム設定ポップアップ。
  /// 背景バリアのタップ / AppBar の戻る (←) で閉じる。中身は nested Navigator
  /// なので、カラム設定内の `Navigator.push` もポップアップ内でスタックされる。
  Widget _buildDeckColumnSettingsPopup() {
    void close() => ref.read(deckColumnSettingsProvider.notifier).close();
    return _deckPopupFrame(
      onBarrierTap: close,
      child: DeckPopupScope(
        child: Navigator(
          key: const ValueKey('deck_column_settings_nav'),
          onGenerateInitialRoutes: (navigator, initialRoute) => [
            MaterialPageRoute(
              builder: (_) => ColumnSettingsPage(onDeckBack: close),
            ),
          ],
        ),
      ),
    );
  }

  /// ホームに重ねるページポップアップ。背景バリアのタップ / AppBar の戻る (←) で
  /// 閉じる (= tabState をホーム 0 に戻す)。NavigationRail は本 Stack の外なので、
  /// 開いたまま別ページのアイコンを押せば直接切り替わる。
  Widget _buildDeckPopup(int index) {
    void closeToHome() => ref.read(tabStateProvider.notifier).setTabIndex(0);
    // 戻る (←) は各ページの AppBar 内に leading として出す (onDeckBack)。タイトルが
    // 自然に右へずれて重ならない。Deck のポップアップで開く時だけ渡すので、ナローや
    // 通常 push には影響なし。
    //
    // 中身は nested Navigator。これにより、ページ内の `Navigator.push` (設定の各
    // 詳細ページ / 探索→検索結果 / プロフィール等) がフルスクリーンに飛ばず、
    // ポップアップの中でスタックされる (詳細ページは自動の戻る矢印で 1 つ戻る)。
    // DeckPopupScope で「ポップアップの中」を示し、openProfile もこの Navigator に
    // push する。
    return _deckPopupFrame(
      onBarrierTap: closeToHome,
      child: DeckPopupScope(
        child: Navigator(
          key: ValueKey('deck_nav_popup_$index'),
          onGenerateInitialRoutes: (navigator, initialRoute) => [
            MaterialPageRoute(
              builder: (_) => _buildDeckPopupPage(index, closeToHome),
            ),
          ],
        ),
      ),
    );
  }

  /// Deck ポップアップ共通の枠 (背景バリア + 幅/高さを絞った中央パネル)。
  Widget _deckPopupFrame({
    required VoidCallback onBarrierTap,
    required Widget child,
  }) {
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          final panelW =
              (w - 32) < kDeckPopupMaxWidth ? (w - 32) : kDeckPopupMaxWidth;
          final panelH = h - 48;
          return Stack(
            children: [
              // 背景バリア (タップで閉じる)。
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onBarrierTap,
                  child: const ColoredBox(color: Colors.black54),
                ),
              ),
              Center(
                child: SizedBox(
                  width: panelW > 0 ? panelW : w,
                  height: panelH > 0 ? panelH : h,
                  child: Material(
                    elevation: 8,
                    borderRadius: BorderRadius.circular(12),
                    clipBehavior: Clip.antiAlias,
                    child: child,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Deck ポップアップに入れるページを、戻る (←) コールバック付きで構築する。
  /// `_pages` は const で onDeckBack を渡せないため、ここで都度生成する。
  /// 各ページは onDeckBack 非 null のとき AppBar 左に戻る矢印を出す (Deck のみ)。
  Widget _buildDeckPopupPage(int index, VoidCallback onBack) {
    switch (index) {
      case 1:
        return NotificationsPage(onDeckBack: onBack);
      case 2:
        return SearchPage(onDeckBack: onBack);
      case 3:
        return DmPage(onDeckBack: onBack);
      case 4:
        return MyProfilePage(onDeckBack: onBack);
      case 5:
        return SettingsPage(onDeckBack: onBack);
      default:
        return _pages[index];
    }
  }

  /// Scaffold 本体。ワイドレイアウト時は左 NavigationRail + body、
  /// ナロー時は body + BottomNavigationBar に分岐する。
  Widget _buildScaffold(BuildContext context, int currentIndex) {
    final isWide = isWideLayout(context);
    final pagesStack = IndexedStack(
      index: currentIndex,
      children: _pages,
    );

    if (isWide) {
      // TweetDeck 風の投稿ペイン。ピン固定 (settings) かユーザー操作 (open) の
      // どちらかで表示。NavigationRail の右、タイムラインカラムの左に出す。
      final paneOpen = ref.watch(composePaneProvider.select((s) => s.open));
      final pinned =
          ref.watch(settingsProvider.select((s) => s.composePaneFixed));
      final showPane = paneOpen || pinned;
      // ホーム (タイムライン) を下地に、レール + 投稿ペイン + タイムラインを
      // Row で並べる。プロフィール等のポップアップはこの Row の上に「画面全体」
      // で重ねる (通知フィルターの showDialog と同じく、レール / 投稿ペインも
      // 含めて暗幕で覆い、パネルは画面全体の中央に出す)。以前は body 内 (右側の
      // Expanded) に重ねていたため、投稿ペインを開くとポップアップが右に寄って
      // いた。
      return Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              // 下地の Row。Positioned.fill で tight 制約を渡し、レールが縦いっぱい
              // に伸びるようにする (Stack の loose 制約のままだと縦が縮む)。
              Positioned.fill(
                child: Row(
                  children: [
                    _buildNavigationRail(context, currentIndex),
                    const VerticalDivider(width: 1, thickness: 0.5),
                    if (showPane) ...[
                      SizedBox(
                        width: kComposePaneWidth,
                        child: _buildComposePane(pinned),
                      ),
                      const VerticalDivider(width: 1, thickness: 0.5),
                    ],
                    Expanded(child: _pages[0]),
                  ],
                ),
              ),
              // 画面全体に重ねるポップアップ群 (各 _deckPopupFrame は
              // Positioned.fill を返すので、この Stack いっぱいに広がり中央寄せ)。
              ..._buildDeckOverlays(currentIndex),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      // IndexedStack で全タブを常時ツリーに残し、State (スクロール位置・
      // TabController・キャッシュ等) をタブ切替を跨いで保持する
      body: pagesStack,
      bottomNavigationBar: _buildBottomNav(context, currentIndex),
    );
  }

  /// 新規投稿ボタン (rail の FAB / `n` キー) のワイドレイアウト共通処理。
  ///
  /// ペインが返信 / 引用 / 編集の作成中なら、黙って破棄 (または閉じる) せず
  /// 確認ダイアログで「続ける / 破棄して新規投稿」を選ばせる。破棄を選んだ
  /// ときは `freshStart` 付きで新規コンポーズを開き、破棄された旧 PostPage の
  /// dispose が退避下書きへ書いた本文 (返信の @メンション等) も復元させない。
  Future<void> _onComposeButtonPressed() async {
    final paneState = ref.read(composePaneProvider);
    final pinned = ref.read(settingsProvider).composePaneFixed;
    final notifier = ref.read(composePaneProvider.notifier);
    final req = paneState.request;
    final paneVisible = paneState.open || pinned;

    if (paneVisible && req.isReplyOrQuoteOrEdit) {
      // .arb 側の ICU select ('edit' / 'reply' / 'quote') に渡すモードコード
      final mode = req.editStatusId != null
          ? 'edit'
          : req.replyToStatusId != null
              ? 'reply'
              : 'quote';
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(ctx.l10n.composeInProgressTitle(mode)),
          content: Text(ctx.l10n.composeDiscardAndStartNewMessage),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(ctx.l10n.composeContinue(mode)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(ctx.l10n.composeDiscardAndStartNew),
            ),
          ],
        ),
      );
      if (discard == true) {
        notifier.openNew(freshStart: true);
      }
      return;
    }

    // 従来動作: ピン固定中は新規コンポーズへ、非固定はトグル開閉。
    if (pinned) {
      notifier.openNew();
    } else {
      notifier.toggleNew();
    }
  }

  /// 横ペインに埋め込む投稿欄。`composePaneProvider` の現在のリクエストを
  /// `PostPage` (embedded) として描画する。リクエスト (新規/返信/引用) が
  /// 切り替わると seq が変わり、ValueKey 経由で PostPage が作り直されて
  /// 新しい初期パラメタ (initState で読まれる) が反映される。
  Widget _buildComposePane(bool pinned) {
    final req = ref.watch(composePaneProvider.select((s) => s.request));
    final notifier = ref.read(composePaneProvider.notifier);
    return PostPage(
      key: ValueKey('compose_pane_${req.seq}'),
      embedded: true,
      pinned: pinned,
      onTogglePin: () =>
          ref.read(settingsProvider.notifier).setComposePaneFixed(!pinned),
      // 編集をやめて新規コンポーズに戻す (ピン固定中でもペインは維持される)。
      onCancelEdit: () => notifier.openNew(),
      onPosted: () {
        if (!pinned) {
          notifier.close();
          return;
        }
        // ピン固定中: 返信 / 引用 / 編集はコンテキストが 1 回限りの操作なので
        // 新規コンポーズへ戻す (seq 更新で PostPage を作り直し)。返信モードを
        // 残すと、続けて書いた次の投稿も同じ相手への返信として送られてしまう。
        // 素の新規投稿はフォームがその場クリア済みなのでペインを維持して連投。
        if (req.isReplyOrQuoteOrEdit) notifier.openNew();
      },
      replyToStatusId: req.replyToStatusId,
      replyToUsername: req.replyToUsername,
      replyToVisibility: req.replyToVisibility,
      initialText: req.initialText,
      initialVisibility: req.initialVisibility,
      quotedStatus: req.quotedStatus,
      initialAccountIds: req.initialAccountIds,
      editStatusId: req.editStatusId,
      editTargetStatus: req.editTargetStatus,
      editAccountId: req.editAccountId,
      discardTempDraft: req.freshStart,
    );
  }

  /// ワイドレイアウト時の左サイドレール。
  ///
  /// - leading: 投稿コンポーズ (FAB 風アイコン)
  /// - destinations: BottomNav と同じ 6 タブ
  /// - trailing: お知らせベル + ストリーミングトグル (旧 MainPage AppBar
  ///   から移設したグローバル操作)
  ///
  /// MainPage AppBar の bell / streaming はワイドレイアウトでは消える
  /// (`main_page.dart` 側で wide 判定の分岐済み)。
  Widget _buildNavigationRail(BuildContext context, int currentIndex) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    return NavigationRail(
      selectedIndex: currentIndex,
      onDestinationSelected: (idx) {
        // ナビ切替時はプロフィール / 汎用 / カラム設定ポップアップを閉じてから移動する。
        ref.read(deckProfileProvider.notifier).close();
        ref.read(deckPopupProvider.notifier).close();
        ref.read(deckColumnSettingsProvider.notifier).close();
        ref.read(tabStateProvider.notifier).setTabIndex(idx);
      },
      labelType: NavigationRailLabelType.none,
      selectedIconTheme: IconThemeData(size: 28, color: primary),
      unselectedIconTheme: const IconThemeData(size: 24, color: Colors.grey),
      leading: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: FloatingActionButton.small(
          tooltip: context.l10n.newPost,
          heroTag: 'rail_compose_fab',
          onPressed: _onComposeButtonPressed,
          child: const Icon(Icons.edit),
        ),
      ),
      destinations: [
        NavigationRailDestination(
          icon: Consumer(builder: (context, ref, _) {
            final unread = ref.watch(unreadAnnouncementCountProvider);
            return _buildNavIcon(Icons.home_outlined, unread);
          }),
          selectedIcon: Consumer(builder: (context, ref, _) {
            final unread = ref.watch(unreadAnnouncementCountProvider);
            return _buildNavIcon(Icons.home, unread);
          }),
          label: Text(context.l10n.navHome),
        ),
        NavigationRailDestination(
          icon: Consumer(builder: (context, ref, _) {
            final n = ref.watch(unreadNotificationCountProvider);
            return _buildNavIcon(Icons.notifications_outlined, n);
          }),
          selectedIcon: Consumer(builder: (context, ref, _) {
            final n = ref.watch(unreadNotificationCountProvider);
            return _buildNavIcon(Icons.notifications, n);
          }),
          label: Text(context.l10n.navNotifications),
        ),
        NavigationRailDestination(
          icon: const Icon(Icons.search_outlined),
          selectedIcon: const Icon(Icons.search),
          label: Text(context.l10n.navSearch),
        ),
        NavigationRailDestination(
          icon: const Icon(Icons.mail_outline),
          selectedIcon: const Icon(Icons.mail),
          label: Text(context.l10n.navDm),
        ),
        NavigationRailDestination(
          icon: const Icon(Icons.person_outline),
          selectedIcon: const Icon(Icons.person),
          label: Text(context.l10n.navProfile),
        ),
        NavigationRailDestination(
          icon: const Icon(Icons.settings_outlined),
          selectedIcon: const Icon(Icons.settings),
          label: Text(context.l10n.navSettings),
        ),
      ],
      trailing: Expanded(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            // お知らせベル (未読数バッジ付き)
            Consumer(builder: (context, ref, _) {
              final unread = ref.watch(unreadAnnouncementCountProvider);
              return IconButton(
                tooltip: context.l10n.announcementsTooltip,
                icon: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const Icon(Icons.campaign_outlined),
                    if (unread > 0)
                      Positioned(
                        right: -4,
                        top: -2,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.error,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          constraints: const BoxConstraints(
                            minWidth: 14,
                            minHeight: 14,
                          ),
                          child: Text(
                            unread > 99 ? '99+' : unread.toString(),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                onPressed: () {
                  // Deck (ワイド) ではホームに重ねるポップアップで表示する
                  // (プロフィール等と同じく画面全体の中央)。ナローへは
                  // openDeckPage が従来のフルスクリーン push にフォールバック。
                  openDeckPage(
                    context,
                    (onDeckBack) =>
                        AnnouncementsPage(onDeckBack: onDeckBack),
                  );
                },
              );
            }),
            // ストリーミング ON/OFF
            Consumer(builder: (context, ref, _) {
              final enabled = ref.watch(
                  settingsProvider.select((s) => s.streamingEnabled));
              return IconButton(
                tooltip:
                    context.l10n.streamingTooltip(enabled ? 'ON' : 'OFF'),
                icon: Icon(
                  enabled ? Icons.podcasts : Icons.podcasts_outlined,
                  color: enabled ? primary : null,
                ),
                onPressed: () {
                  ref
                      .read(settingsProvider.notifier)
                      .setStreamingEnabled(!enabled);
                },
              );
            }),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  /// ナローレイアウト時の BottomNav (従来通り)。
  Widget _buildBottomNav(BuildContext context, int currentIndex) {
    return BottomNavigationBar(
      type: BottomNavigationBarType.fixed,
      currentIndex: currentIndex,
      // 視認性向上: 選択中はテーマプライマリ色、未選択はグレー。
      // 加えて選択中はアイコンを少し大きく + 塗りつぶし、未選択は
      // アウトライン版を使うことで形状でも区別できるようにする。
      selectedItemColor: Theme.of(context).colorScheme.primary,
      unselectedItemColor: Colors.grey,
      selectedIconTheme: const IconThemeData(size: 28),
      unselectedIconTheme: const IconThemeData(size: 24),
      items: [
            BottomNavigationBarItem(
              // ホームタブには「サーバからのお知らせ」未読バッジを出す。
              // お知らせへの導線はメインタイムラインの AppBar 内アイコンに
              // 置いているため、未読が発生したらここから気付けるよう
              // ナビアイコン側にも数を表示する。
              icon: Consumer(builder: (context, ref, _) {
                final unread =
                    ref.watch(unreadAnnouncementCountProvider);
                return _buildNavIcon(Icons.home_outlined, unread);
              }),
              activeIcon: Consumer(builder: (context, ref, _) {
                final unread =
                    ref.watch(unreadAnnouncementCountProvider);
                return _buildNavIcon(Icons.home, unread);
              }),
              label: '',
            ),
            BottomNavigationBarItem(
              icon: Consumer(builder: (context, ref, _) {
                final unreadCount = ref.watch(unreadNotificationCountProvider);
                return _buildNavIcon(Icons.notifications_outlined, unreadCount);
              }),
              activeIcon: Consumer(builder: (context, ref, _) {
                final unreadCount = ref.watch(unreadNotificationCountProvider);
                return _buildNavIcon(Icons.notifications, unreadCount);
              }),
              label: '',
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.search_outlined),
              activeIcon: Icon(Icons.search),
              label: '',
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.mail_outline),
              activeIcon: Icon(Icons.mail),
              label: '',
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.person_outline),
              activeIcon: Icon(Icons.person),
              label: '',
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.settings_outlined),
              activeIcon: Icon(Icons.settings),
              label: '',
            ),
          ],
      showSelectedLabels: false,
      showUnselectedLabels: false,
      onTap: (idx) => ref.read(tabStateProvider.notifier).setTabIndex(idx),
    );
  }
}
