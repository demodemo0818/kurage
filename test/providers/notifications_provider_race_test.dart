// NotificationsNotifier のアカウント選択まわりの非同期競合テスト。
//
// `mastodon_api.dart` の `httpClient` (テスト用 seam) を MockClient に
// 差し替え、通知フェッチの完了タイミングを Completer で制御することで
// 「フェッチ in-flight 中に選択が変わる」状況を決定的に再現する。
//
// 対象の回帰:
// - eb98c3a: updateSelectedAccounts 中の clear で stale write
//   (未選択なのに通知が表示される)
// - 62cb595: _init フォールバックフェッチの stale write / 全解除後の
//   refresh・loadMore による内容復活
//
// SharedPreferences はモック、SSE 接続は flutter_test の HTTP 遮断で
// 失敗→再接続待ちになるだけなので、テスト終了時の container.dispose で
// 後始末される。

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kurage/providers/auth_provider.dart';
import 'package:kurage/providers/notifications_provider.dart';
import 'package:kurage/services/mastodon_api.dart' as api;

const _accountJson = {
  'id': 'acct-1',
  'instanceUrl': 'https://example.test',
  'accessToken': 'token-1',
  'username': 'alice',
  'displayName': 'Alice',
  'avatarUrl': '',
};

/// v1 通知レスポンス 1 件分 (favourite、status 無しの最小形)。
String _notifBody(String id) => jsonEncode([
      {
        'id': id,
        'type': 'favourite',
        'created_at': '2026-06-01T00:00:00.000Z',
        'account': {'id': 'u1', 'username': 'alice'},
      }
    ]);

http.Response _ok(String body) => http.Response(
      body,
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

/// 条件が満たされるまでイベントループを回す (実時間タイマーは使わない)。
Future<void> _pumpUntil(bool Function() cond, {String? reason}) async {
  for (var i = 0; i < 500; i++) {
    if (cond()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('pumpUntil: 条件が満たされませんでした${reason == null ? '' : ' ($reason)'}');
}

/// 条件に関わらずイベントループを数回回す (「何も起きないこと」の確認用)。
Future<void> _settle() async {
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ゲート中の v1 通知リクエスト。テスト側が complete するまで応答しない。
  late List<Completer<http.Response>> pending;
  // v1 通知エンドポイントに届いたリクエスト数。
  late int notifRequestCount;
  // false にすると v1 通知へ即時応答する (ゲート無し)。
  late bool gateEnabled;
  late int notifSeq;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'accounts': jsonEncode([_accountJson]),
      // static な保存選択を確実に「選択なし」へリセットする
      // (キー欠落だと loadSavedSettings が前テストの値を温存するため)。
      'notification_selected_accounts': <String>[],
    });
    await NotificationsNotifier.loadSavedSettings();

    pending = [];
    notifRequestCount = 0;
    gateEnabled = true;
    notifSeq = 0;

    api.httpClient = MockClient((request) {
      final path = request.url.path;
      if (path.contains('/api/v2/notifications')) {
        // v2 未対応サーバとして振る舞い、常に v1 へフォールバックさせる
        // (groupedNotifications 設定のデフォルト値に依存しないため)。
        return Future.value(http.Response('', 404));
      }
      if (path.contains('/api/v1/notifications')) {
        notifRequestCount++;
        if (!gateEnabled) {
          return Future.value(_ok(_notifBody('n${++notifSeq}')));
        }
        final c = Completer<http.Response>();
        pending.add(c);
        return c.future;
      }
      return Future.value(http.Response('', 404));
    });
  });

  tearDown(() {
    api.httpClient = http.Client();
  });

  /// accounts ロード済みの container を作る。notificationsProvider は
  /// まだ読まない (読んだ瞬間に _init が走るため、タイミングはテスト側で制御)。
  Future<ProviderContainer> createContainer() async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(authProvider);
    await _pumpUntil(
      () => container.read(authProvider).accounts.isNotEmpty,
      reason: 'authProvider のアカウント読み込み',
    );
    return container;
  }

  test('対照実験: _init フォールバックフェッチが完了すると通知が表示される', () async {
    final container = await createContainer();
    container.read(notificationsProvider.notifier);

    // _init が accounts.first のフェッチに到達するまで待つ
    await _pumpUntil(() => pending.length == 1, reason: '_init のフェッチ開始');
    pending.removeAt(0).complete(_ok(_notifBody('n1')));

    await _pumpUntil(
      () => (container.read(notificationsProvider).value?.length ?? 0) == 1,
      reason: '_init の結果反映',
    );
  });

  test('_init のフェッチ完了前に clear すると、完了後も未選択のまま空を維持する', () async {
    final container = await createContainer();
    final notifier = container.read(notificationsProvider.notifier);

    await _pumpUntil(() => pending.length == 1, reason: '_init のフェッチ開始');

    // フェッチ in-flight のまま全解除 (素早いタップ操作に相当)
    await notifier.clearNotifications();
    expect(container.read(notificationsProvider).value, isEmpty);

    // 遅れて _init のフェッチが完了 → stale write してはいけない
    pending.removeAt(0).complete(_ok(_notifBody('n1')));
    await _settle();

    expect(container.read(notificationsProvider).value, isEmpty,
        reason: '_init の古いフェッチ結果が clear 後の state を上書きした');
  });

  test('updateSelectedAccounts のフェッチ完了前に clear すると空を維持する (eb98c3a)', () async {
    final container = await createContainer();
    final notifier = container.read(notificationsProvider.notifier);

    // まず _init を完了させて平常状態にする
    await _pumpUntil(() => pending.length == 1, reason: '_init のフェッチ開始');
    pending.removeAt(0).complete(_ok(_notifBody('n1')));
    await _pumpUntil(
      () => (container.read(notificationsProvider).value?.length ?? 0) == 1,
      reason: '_init の結果反映',
    );

    // 選択 ON (フェッチはゲートで in-flight のまま)
    unawaited(notifier.updateSelectedAccounts(['acct-1']));
    await _pumpUntil(() => pending.length == 1,
        reason: 'updateSelectedAccounts のフェッチ開始');

    // 選択 OFF (素早い 2 連続タップの 2 タップ目に相当)
    await notifier.clearNotifications();
    expect(container.read(notificationsProvider).value, isEmpty);

    // 遅れて update のフェッチが完了 → stale write してはいけない
    pending.removeAt(0).complete(_ok(_notifBody('n2')));
    await _settle();

    expect(container.read(notificationsProvider).value, isEmpty,
        reason: 'update の古いフェッチ結果が clear 後の state を上書きした');
  });

  test('全解除後の refresh / loadMore は何も取得せず空を維持する (62cb595)', () async {
    final container = await createContainer();
    final notifier = container.read(notificationsProvider.notifier);

    // _init を完了させて instanceUrl / _maxId が立った状態を作る
    // (全解除後の復活バグはこの状態が前提条件だった)
    await _pumpUntil(() => pending.length == 1, reason: '_init のフェッチ開始');
    pending.removeAt(0).complete(_ok(_notifBody('n1')));
    await _pumpUntil(
      () => (container.read(notificationsProvider).value?.length ?? 0) == 1,
      reason: '_init の結果反映',
    );

    await notifier.clearNotifications();
    expect(container.read(notificationsProvider).value, isEmpty);

    // ここからは即時応答にする (ガード欠落の regression 時にテストが
    // ゲート待ちでハングせず、アサーション失敗として現れるように)
    gateEnabled = false;
    final requestsAfterClear = notifRequestCount;

    await notifier.refresh();
    expect(notifRequestCount, requestsAfterClear,
        reason: '全解除中の refresh が通知を再取得した');
    expect(container.read(notificationsProvider).value, isEmpty,
        reason: '全解除中の refresh で通知が復活した');

    await notifier.loadMore();
    expect(notifRequestCount, requestsAfterClear,
        reason: '全解除中の loadMore が通知を再取得した');
    expect(container.read(notificationsProvider).value, isEmpty,
        reason: '全解除中の loadMore で通知が復活した');
  });
}
