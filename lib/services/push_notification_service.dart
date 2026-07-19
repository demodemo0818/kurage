// lib/services/push_notification_service.dart

import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../firebase_options.dart';
import '../l10n/l10n.dart';
import '../models/auth_account.dart';
import '../services/mastodon_api.dart';
import '../services/push_notification_style.dart';
import '../services/push_relay_config.dart';

/// バックグラウンド (アプリ未起動 / 一時停止中) で FCM data メッセージを受信した
/// 時のハンドラ。トップレベル関数である必要がある。
///
/// Worker からは notification キーなしの data only メッセージで送られてくるので、
/// OS は自動表示しない。ここで明示的に local notification を出す。
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // ここで例外が漏れると通知が「黙って消える」(OS 側には何も表示されない) ため、
  // 全体を try/catch で覆い、失敗はログ + Crashlytics に必ず残す。
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
    debugPrint('[Push] background message: ${message.data}');

    // 別 isolate で動くので FlutterLocalNotificationsPlugin を初期化し直す
    final plugin = FlutterLocalNotificationsPlugin();
    try {
      const androidInit =
          AndroidInitializationSettings('@drawable/ic_stat_kurage');
      const settings = InitializationSettings(android: androidInit);
      await plugin.initialize(settings);
    } catch (e) {
      // ic_stat_kurage が解決できない端末でも通知自体は出す
      debugPrint(
          '[Push] bg init failed with ic_stat_kurage: $e — launcher icon で再試行');
      const fallbackInit =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      const fallbackSettings = InitializationSettings(android: fallbackInit);
      await plugin.initialize(fallbackSettings);
    }
    await _showFromData(plugin, message);
  } catch (e, st) {
    debugPrint('[Push] background handler failed: $e\n$st');
    try {
      await FirebaseCrashlytics.instance
          .recordError(e, st, reason: 'push background handler');
    } catch (_) {
      // Crashlytics 自体が使えない状況 (初期化前等) は握り潰す
    }
  }
}

/// data only メッセージから local notification を発行する共通処理
Future<void> _showFromData(
  FlutterLocalNotificationsPlugin plugin,
  RemoteMessage message,
) async {
  final data = message.data;
  // notification_type (favourite/reblog/follow 等) から種別絵文字・チャンネル・
  // アクセント色を決める。未知の種別は「その他」+ 絵文字なしに落ちる。
  final style = pushStyleForType(data['notification_type']);
  final rawTitle = data['title'] ?? l10n.pushNewNotificationTitle;
  final title =
      style.emoji == null ? rawTitle : '${style.emoji} $rawTitle';
  final body = data['body'] ?? '';

  // payload の icon (リアクションした人のアバター URL) を largeIcon に表示。
  // ダウンロード/デコードのどこで失敗しても null (largeIcon なし) で通知自体は
  // 必ず出す。
  final avatar = await _fetchAvatarBitmap(data['icon']);

  final androidDetails = AndroidNotificationDetails(
    style.channel.id,
    style.channel.name,
    channelDescription: style.channel.description,
    importance: Importance.high,
    priority: Priority.high,
    // small icon はアルファのみがマスクとして使われるため、白モノクロ透過の
    // 専用 drawable を指定する (ic_launcher だと全面ベタ塗り = 白い四角になる)。
    // 素材の再生成は tool/gen_notification_icon.dart。
    icon: 'ic_stat_kurage',
    color: style.color,
    largeIcon: avatar,
  );
  const iosDetails = DarwinNotificationDetails();
  final details = NotificationDetails(
    android: androidDetails,
    iOS: iosDetails,
  );

  try {
    await plugin.show(
      message.hashCode,
      title,
      body,
      details,
      payload: jsonEncode(data),
    );
  } catch (e) {
    // ic_stat_kurage の解決失敗 (invalid_icon 等) で通知が黙って消えるのを防ぐ。
    // launcher icon で 1 回だけ再試行する (白い四角になるが届かないよりよい)。
    // このログが出たら ic_stat_kurage 側の問題が確定。
    debugPrint('[Push] show failed: $e — launcher icon で再試行');
    final fallbackDetails = NotificationDetails(
      android: AndroidNotificationDetails(
        style.channel.id,
        style.channel.name,
        channelDescription: style.channel.description,
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
        color: style.color,
        largeIcon: avatar,
      ),
      iOS: const DarwinNotificationDetails(),
    );
    try {
      await plugin.show(
        message.hashCode,
        title,
        body,
        fallbackDetails,
        payload: jsonEncode(data),
      );
    } catch (e2) {
      debugPrint('[Push] fallback show also failed: $e2');
    }
  }
}

/// アバター URL をダウンロードして通知の largeIcon 用ビットマップにする。
/// バックグラウンド isolate では cached_network_image のキャッシュを共有
/// できないため素の http で取得する。失敗したら null (largeIcon なし)。
Future<ByteArrayAndroidBitmap?> _fetchAvatarBitmap(String? url) async {
  if (url == null || url.isEmpty) return null;
  try {
    final resp = await http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 4));
    if (resp.statusCode != 200) return null;
    final bytes = resp.bodyBytes;
    try {
      // アプリ内のアバター表示と揃えて円形に切り抜く
      return ByteArrayAndroidBitmap(await _circleCropAvatar(bytes));
    } catch (e) {
      // デコード失敗 (未対応形式等) は四角のまま出す
      debugPrint('[Push] avatar circle crop failed: $e — 生画像で表示');
      return ByteArrayAndroidBitmap(bytes);
    }
  } catch (e) {
    debugPrint('[Push] avatar fetch failed: $e');
    return null;
  }
}

/// アバター画像を 256x256 の円形に切り抜いた PNG バイト列を返す。
/// Android の largeIcon は画像をそのまま (四角で) 表示するため、自前で
/// 円形化する。Mastodon のアバターは正方形なので歪みは実質発生しない。
Future<Uint8List> _circleCropAvatar(Uint8List bytes) async {
  const size = 256;
  final codec = await ui.instantiateImageCodec(
    bytes,
    targetWidth: size,
    targetHeight: size,
  );
  final frame = await codec.getNextFrame();
  final image = frame.image;
  try {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    const rect = ui.Rect.fromLTWH(0, 0, size * 1.0, size * 1.0);
    canvas.clipPath(ui.Path()..addOval(rect));
    canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH(
          0, 0, image.width.toDouble(), image.height.toDouble()),
      rect,
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    final rendered = await recorder.endRecording().toImage(size, size);
    try {
      final png = await rendered.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) {
        throw StateError(l10n.pushPngEncodeFailed);
      }
      return png.buffer.asUint8List();
    } finally {
      rendered.dispose();
    }
  } finally {
    image.dispose();
  }
}

class PushNotificationService {
  static final PushNotificationService _instance =
      PushNotificationService._internal();
  factory PushNotificationService() => _instance;
  PushNotificationService._internal();

  /// Firebase.initializeApp() より前にアクセスすると `[core/no-app]` で死ぬので
  /// late final で遅延初期化する。
  late final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  static const String _pushEndpointKey = 'push_endpoint_';
  static const String _pushServerKeyKey = 'push_server_key_';
  static const String _pushAuthKey = 'push_auth_';
  static const String _pushLastResultKey = 'push_last_register_result_';

  // リレーから取得した公開鍵 / auth_secret のセッションキャッシュ
  String? _cachedRelayPubkey;
  String? _cachedRelayAuth;

  // onTokenRefresh の購読 (initialize は起動時 1 回だが多重購読を防御)
  StreamSubscription<String>? _tokenRefreshSub;

  /// 設定「プッシュ通知」の値を SharedPreferences の `appearanceSettings` JSON
  /// から直接読む。デフォルト (未設定・読取失敗) は true。
  ///
  /// settingsProvider の `_load()` 完了を待てないコンテキスト (起動直後の
  /// initialize、onTokenRefresh、ログイン直後) から使うため、アプリロックの
  /// `shouldStartLocked()` と同じ prefs 直読みパターンで統一している。
  static Future<bool> readPushEnabledFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString('appearanceSettings');
      if (jsonStr == null) return true;
      final m = jsonDecode(jsonStr) as Map<String, dynamic>;
      return m['pushNotificationsEnabled'] as bool? ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 通知タップ時に呼ばれるコールバック。
  /// Widget ツリー外から Riverpod を操作するため、main.dart で注入する。
  void Function()? onTapNotification;

  /// 初期化
  ///
  /// [onTapNotification] が指定されると、システム通知 / FCM 通知のタップで
  /// 呼び出される (フォアグラウンド/バックグラウンド/コールドスタート全て)。
  ///
  /// [autoRegister] が false のときは、保存済みアカウントの自動購読登録
  /// (`_autoRegisterForSavedAccounts`) をスキップする。設定でプッシュ通知を
  /// OFF にしているユーザー向け。FCM ハンドラ登録などの他の初期化は行う
  /// (購読が無い限りサーバから通知は飛んでこない)。
  Future<void> initialize({
    void Function()? onTapNotification,
    bool autoRegister = true,
  }) async {
    this.onTapNotification = onTapNotification;
    debugPrint('[Push] initialize() start');

    if (Firebase.apps.isEmpty) {
      debugPrint('[Push] calling Firebase.initializeApp()...');
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      debugPrint('[Push] Firebase.initializeApp() done');
    } else {
      debugPrint('[Push] Firebase already initialized');
    }

    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    const androidSettings =
        AndroidInitializationSettings('@drawable/ic_stat_kurage');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _localNotifications.initialize(
      settings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    final androidPlugin = _localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    // 種別ごとのチャンネルを作成する (Android のシステム設定で「お気に入りは
    // 無音、メンションだけ音を鳴らす」のような個別制御を可能にするため)。
    for (final c in allPushChannels) {
      await androidPlugin?.createNotificationChannel(
        AndroidNotificationChannel(
          c.id,
          c.name,
          description: c.description,
          importance: Importance.high,
        ),
      );
    }
    // 旧単一チャンネルは設定画面に残骸が残らないよう削除する
    await androidPlugin?.deleteNotificationChannel('mastodon_notifications');
    debugPrint('[Push] notification channels created');

    final granted =
        await androidPlugin?.requestNotificationsPermission() ?? true;
    debugPrint('[Push] POST_NOTIFICATIONS permission granted: $granted');

    final fcmSettings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    debugPrint(
        '[Push] FCM authorization status: ${fcmSettings.authorizationStatus}');

    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);
    FirebaseMessaging.onMessageOpenedApp.listen(_handleMessageOpenedApp);

    final initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      _handleMessageOpenedApp(initialMessage);
    }

    try {
      final token = await _messaging.getToken();
      debugPrint('===== FCM Token =====');
      debugPrint(token);
      debugPrint('=====================');
    } catch (e) {
      debugPrint('FCM トークン取得失敗: $e');
    }

    // FCM トークンはアプリ更新・データ復元・GMS の都合等で予告なくローテート
    // される。endpoint URL にトークンを埋め込む方式のため、旧トークンのままの
    // Mastodon 購読には二度と届かない。ローテートを検知したら全アカウントを
    // 新トークンで再登録する (従来はアプリ再起動まで通知が止まっていた)。
    _tokenRefreshSub ??= _messaging.onTokenRefresh.listen(
      (newToken) async {
        debugPrint('[Push] FCM token refreshed — 全アカウントを再登録します');
        try {
          // 設定はイベント発生時点の値を読む (起動時の autoRegister とは独立)
          if (!await readPushEnabledFromPrefs()) return;
          await _autoRegisterForSavedAccounts();
        } catch (e) {
          debugPrint('[Push] onTokenRefresh 再登録失敗: $e');
        }
      },
      onError: (Object e) =>
          debugPrint('[Push] onTokenRefresh stream error: $e'),
    );

    // 保存済みアカウントを自動で購読登録（端末トークンが変わっている可能性も
    // あるので毎回上書き登録する。Mastodon は同一 access_token に対して 1 購読のみ）
    // 設定でプッシュ通知 OFF の場合は登録しない。
    if (autoRegister) {
      await _autoRegisterForSavedAccounts();
    }
  }

  /// 通知権限のリクエスト
  Future<bool> requestPermission() async {
    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );
    return settings.authorizationStatus == AuthorizationStatus.authorized;
  }

  /// SharedPreferences に保存済みのアカウント全てを Worker 経由で購読登録
  Future<void> _autoRegisterForSavedAccounts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString('accounts');
      if (jsonStr == null) {
        debugPrint('[Push] no saved accounts to register');
        return;
      }
      final list = (jsonDecode(jsonStr) as List).cast<Map<String, dynamic>>();
      for (final m in list) {
        final account = AuthAccount.fromJson(m);
        final ok = await registerPushNotification(account);
        debugPrint(
            '[Push] register ${account.username}@${account.instanceUrl}: $ok');
      }
    } catch (e) {
      debugPrint('[Push] _autoRegisterForSavedAccounts failed: $e');
    }
  }

  /// 設定でプッシュ通知を ON にしたときに呼ぶ。保存済み全アカウントを
  /// 購読登録する (`_autoRegisterForSavedAccounts` の public ラッパー)。
  Future<void> registerAllSavedAccounts() => _autoRegisterForSavedAccounts();

  /// 設定ページの「プッシュ通知の状態を確認」用。通知権限 / FCM トークン /
  /// リレー到達性を実測し、保存済み全アカウントの購読を再登録した上で、
  /// 結果を表示用の行リストで返す (自己修復手段を兼ねる)。
  Future<List<String>> runDiagnostics() async {
    final lines = <String>[];

    try {
      final androidPlugin = _localNotifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      final enabled = await androidPlugin?.areNotificationsEnabled();
      lines.add(l10n.pushDiagPermission(enabled == true
          ? l10n.pushDiagAllowed
          : enabled == false
              ? l10n.pushDiagDenied
              : l10n.pushDiagUnknown));
    } catch (e) {
      lines.add(l10n.pushDiagPermissionCheckFailed('$e'));
    }

    try {
      final token = await _messaging.getToken();
      if (token == null) {
        lines.add(l10n.pushDiagTokenNull);
      } else {
        // トークンは秘匿情報なので先頭 8 文字のみ表示する
        final head = token.length > 8 ? token.substring(0, 8) : token;
        lines.add(l10n.pushDiagTokenOk(head, token.length));
      }
    } catch (e) {
      lines.add(l10n.pushDiagTokenFailed('$e'));
    }

    // キャッシュを捨てて到達性を実測する
    _cachedRelayPubkey = null;
    _cachedRelayAuth = null;
    final keys = await _fetchRelayKeys();
    lines.add(keys == null ? l10n.pushDiagRelayUnreachable : l10n.pushDiagRelayOk);

    // 専用アイコン (ic_stat_kurage) でテスト通知を実際に表示してみる。
    // アイコンリソースが端末で解決できない状態 (release の resource shrinker
    // による削除が典型。res/raw/keep.xml で保護済み) を遠隔で切り分けるため
    // (失敗するとフォールバックの ic_launcher = 白い四角になる)。
    try {
      final testChannel = pushStyleForType(null).channel; // notif_other
      final testDetails = NotificationDetails(
        android: AndroidNotificationDetails(
          testChannel.id,
          testChannel.name,
          channelDescription: testChannel.description,
          importance: Importance.high,
          priority: Priority.high,
          icon: 'ic_stat_kurage',
          color: const ui.Color(0xFF6750A4),
        ),
      );
      await _localNotifications.show(
        999999,
        l10n.pushDiagTestNotifTitle,
        l10n.pushDiagTestNotifBody,
        testDetails,
      );
      lines.add(l10n.pushDiagTestShown);
    } catch (e) {
      lines.add(l10n.pushDiagTestFailed('$e'));
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString('accounts');
      if (jsonStr == null) {
        lines.add(l10n.pushDiagNoAccounts);
        return lines;
      }
      final list = (jsonDecode(jsonStr) as List).cast<Map<String, dynamic>>();
      for (final m in list) {
        final account = AuthAccount.fromJson(m);
        final ok = await registerPushNotification(account);
        final host = Uri.tryParse(account.instanceUrl)?.host ??
            account.instanceUrl;
        final detail = await lastRegisterResult(account.id);
        lines.add(
            '${account.username}@$host: ${ok ? l10n.pushDiagRegOk : l10n.pushDiagRegFailed}${detail != null ? '\n  $detail' : ''}');
      }
    } catch (e) {
      lines.add(l10n.pushDiagAccountsError('$e'));
    }
    return lines;
  }

  /// 設定でプッシュ通知を OFF にしたときに呼ぶ。保存済み全アカウントの
  /// 購読をサーバ側から解除する。
  Future<void> unregisterAllSavedAccounts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString('accounts');
      if (jsonStr == null) return;
      final list = (jsonDecode(jsonStr) as List).cast<Map<String, dynamic>>();
      for (final m in list) {
        await unregisterPushNotification(AuthAccount.fromJson(m));
      }
    } catch (e) {
      debugPrint('[Push] unregisterAllSavedAccounts failed: $e');
    }
  }

  /// リレーの公開鍵と auth_secret を取得 (セッションキャッシュ付き)
  Future<({String pubkey, String auth})?> _fetchRelayKeys() async {
    if (_cachedRelayPubkey != null && _cachedRelayAuth != null) {
      return (pubkey: _cachedRelayPubkey!, auth: _cachedRelayAuth!);
    }
    try {
      final pubResp = await http.get(Uri.parse('$pushRelayBaseUrl/pubkey'));
      final authResp = await http.get(Uri.parse('$pushRelayBaseUrl/auth'));
      if (pubResp.statusCode != 200 || authResp.statusCode != 200) {
        debugPrint(
            '[Push] relay keys fetch failed: ${pubResp.statusCode}/${authResp.statusCode}');
        return null;
      }
      _cachedRelayPubkey = pubResp.body.trim();
      _cachedRelayAuth = authResp.body.trim();
      return (pubkey: _cachedRelayPubkey!, auth: _cachedRelayAuth!);
    } catch (e) {
      debugPrint('[Push] relay keys fetch exception: $e');
      return null;
    }
  }

  /// 直近の購読登録結果 (成功/失敗理由) を prefs に記録する。
  /// 従来は失敗が debugPrint で黙殺され原因を後から追えなかったため、
  /// 設定ページの「プッシュ通知の状態を確認」で表示できるよう残す。
  Future<void> _recordRegisterResult(String accountId, String result) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pushLastResultKey + accountId,
          '$result (${DateTime.now().toIso8601String()})');
    } catch (_) {}
  }

  /// 指定アカウントの直近の購読登録結果を返す (未登録なら null)
  Future<String?> lastRegisterResult(String accountId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_pushLastResultKey + accountId);
    } catch (_) {
      return null;
    }
  }

  /// 指定アカウントのプッシュ通知を Mastodon サーバに購読登録する
  Future<bool> registerPushNotification(AuthAccount account) async {
    try {
      String? fcmToken;
      try {
        fcmToken = await _messaging.getToken();
      } catch (e) {
        await _recordRegisterResult(
            account.id, l10n.pushRegFcmTokenFailedError('$e'));
        return false;
      }
      if (fcmToken == null) {
        await _recordRegisterResult(account.id, l10n.pushRegFcmTokenNull);
        return false;
      }

      final keys = await _fetchRelayKeys();
      if (keys == null) {
        await _recordRegisterResult(account.id, l10n.pushRegRelayKeyFailed);
        return false;
      }

      // 端末ごとに一意な FCM トークンを URL に埋め込む
      final endpoint =
          '$pushRelayBaseUrl/relay/${Uri.encodeComponent(fcmToken)}';

      final response = await createPushSubscription(
        instanceUrl: account.instanceUrl,
        accessToken: account.accessToken,
        endpoint: endpoint,
        p256dh: keys.pubkey,
        auth: keys.auth,
        alerts: const {
          'follow': true,
          'favourite': true,
          'reblog': true,
          'mention': true,
          'poll': true,
          'follow_request': true,
          'status': true,
          'update': true,
        },
      );

      if (response != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
            _pushEndpointKey + account.id, response['endpoint'] as String);
        await prefs.setString(_pushServerKeyKey + account.id, keys.pubkey);
        await prefs.setString(_pushAuthKey + account.id, keys.auth);
        await _recordRegisterResult(account.id, 'OK');
        return true;
      }
      await _recordRegisterResult(account.id, l10n.pushRegServerFailed);
    } catch (e) {
      debugPrint('プッシュ通知の登録に失敗: $e');
      await _recordRegisterResult(account.id, l10n.pushRegException('$e'));
    }
    return false;
  }

  /// プッシュ通知の登録解除
  Future<void> unregisterPushNotification(AuthAccount account) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // このアカウントで購読登録した記録が無ければ何もしない。
      // (Web/デスクトップや push 未登録アカウントで無駄な解除 API を叩かない。)
      if (prefs.getString(_pushEndpointKey + account.id) == null) return;
      await deletePushSubscription(
        instanceUrl: account.instanceUrl,
        accessToken: account.accessToken,
      );
      await prefs.remove(_pushEndpointKey + account.id);
      await prefs.remove(_pushServerKeyKey + account.id);
      await prefs.remove(_pushAuthKey + account.id);
    } catch (e) {
      debugPrint('プッシュ通知の登録解除に失敗: $e');
    }
  }

  /// フォアグラウンドでメッセージを受信
  void _handleForegroundMessage(RemoteMessage message) {
    debugPrint('[Push] foreground message: ${message.data}');
    unawaited(_showFromData(_localNotifications, message).catchError(
        (Object e) => debugPrint('[Push] foreground show failed: $e')));
  }

  /// 通知タップでアプリが開かれた時 (バックグラウンド -> フォアグラウンド)
  void _handleMessageOpenedApp(RemoteMessage message) {
    debugPrint('[Push] notification opened app: ${message.data}');
    onTapNotification?.call();
  }

  /// ローカル通知 (フォアグラウンド時) がタップされた時
  void _onNotificationTapped(NotificationResponse response) {
    debugPrint('[Push] local notification tapped: ${response.payload}');
    onTapNotification?.call();
  }
}
