// NotificationsNotifier の SSE 接続まわりの競合・重複テスト。
//
// `mastodon_api.dart` の `subscribeNotifications` (テスト用 seam) を
// フェイクに差し替え、接続確立 (Future) の完了タイミングを Completer で
// 制御することで「接続確立の await 中に再接続トリガーが重なる」状況を
// 決定的に再現する。
//
// 対象の回帰:
// - _connectStream の in-flight ガード欠如: アプリ復帰 (resumed) の
//   _forceReconnectAllStreams が接続確立中に重なると同一アカウントに
//   SSE リスナーが 2 本張られ、以後すべての通知が二重表示になる
// - _onConnEvent の通知 ID dedup (防御層)
// - conn 破棄後に接続が確立したケースの listen → 即 cancel (接続リーク防止)
//
// HTTP フェッチ側は race_test と同じく MockClient で即時応答させる。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kurage/models/notification_item.dart';
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

/// SSE から流す通知 (mention は canMerge 対象外なので必ず新規 prepend
/// される = 二重配信がそのまま件数に現れる)。
NotificationItem _mention(String id) => NotificationItem.fromJson({
      'id': id,
      'type': 'mention',
      'created_at': '2026-06-01T00:00:00.000Z',
      'account': {'id': 'u1', 'username': 'alice'},
    });

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
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final originalSubscribeNotifications = api.subscribeNotifications;

  // subscribeNotifications の呼び出し回数と、ゲート中の接続確立 Future。
  late int subscribeCount;
  late List<Completer<Stream<NotificationItem>>> pendingSubscribes;
  // フェイク SSE 本体。broadcast controller の listener 増減を数えて
  // 「listen されたか / cancel されたか」を検証する。
  late StreamController<NotificationItem> sseController;
  late int sseListenCount;
  late int sseCancelCount;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'accounts': jsonEncode([_accountJson]),
      'notification_selected_accounts': <String>[],
    });
    await NotificationsNotifier.loadSavedSettings();

    subscribeCount = 0;
    pendingSubscribes = [];
    sseListenCount = 0;
    sseCancelCount = 0;
    sseController = StreamController<NotificationItem>.broadcast(
      onListen: () => sseListenCount++,
      onCancel: () => sseCancelCount++,
    );
    addTearDown(sseController.close);

    api.subscribeNotifications = ({
      required String instanceUrl,
      required String accessToken,
    }) {
      subscribeCount++;
      final c = Completer<Stream<NotificationItem>>();
      pendingSubscribes.add(c);
      return c.future;
    };

    // 通知フェッチは常に即時の空応答 (このテストの関心は SSE のみ)。
    api.httpClient = MockClient((request) {
      final path = request.url.path;
      if (path.contains('/api/v2/notifications')) {
        return Future.value(http.Response('', 404));
      }
      if (path.contains('/api/v1/notifications')) {
        return Future.value(http.Response(
          '[]',
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ));
      }
      return Future.value(http.Response('', 404));
    });
  });

  tearDown(() {
    api.httpClient = http.Client();
    api.subscribeNotifications = originalSubscribeNotifications;
  });

  /// accounts ロード済みの container を作り、notifier を起動して
  /// _init の SSE 接続開始 (subscribe 呼び出し) まで進める。
  Future<ProviderContainer> createContainerWithPendingSubscribe() async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(authProvider);
    await _pumpUntil(
      () => container.read(authProvider).accounts.isNotEmpty,
      reason: 'authProvider のアカウント読み込み',
    );
    container.read(notificationsProvider.notifier);
    await _pumpUntil(() => subscribeCount == 1, reason: '_init の SSE 接続開始');
    return container;
  }

  test('接続確立中にアプリ復帰が重なっても SSE リスナーは 1 本のまま', () async {
    final container = await createContainerWithPendingSubscribe();

    // 接続確立 (await subscribeNotifications) が in-flight のままアプリ復帰
    // → _forceReconnectAllStreams が同じ conn へ _connectStream を再突入させる。
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle();

    expect(subscribeCount, 1,
        reason: 'in-flight の接続確立に合流せず二重に subscribe した');

    // 接続確立を完了させ、通知を 1 件流す
    for (final c in pendingSubscribes) {
      c.complete(sseController.stream);
    }
    await _pumpUntil(() => sseListenCount >= 1, reason: 'SSE の listen 開始');

    sseController.add(_mention('n-sse-1'));
    await _pumpUntil(
      () => (container.read(notificationsProvider).value?.length ?? 0) >= 1,
      reason: 'SSE 通知の反映',
    );
    await _settle();

    expect(sseListenCount, 1, reason: 'SSE リスナーが二重に張られた');
    expect(container.read(notificationsProvider).value?.length, 1,
        reason: '同じ通知が二重表示された');
  });

  test('同じ通知 ID が二重配信されても 1 件しか表示しない (防御的 dedup)', () async {
    final container = await createContainerWithPendingSubscribe();
    pendingSubscribes.removeAt(0).complete(sseController.stream);
    await _pumpUntil(() => sseListenCount == 1, reason: 'SSE の listen 開始');

    sseController.add(_mention('n-dup'));
    sseController.add(_mention('n-dup'));
    sseController.add(_mention('n-other'));
    await _pumpUntil(
      () => (container.read(notificationsProvider).value?.length ?? 0) >= 2,
      reason: 'SSE 通知の反映',
    );
    await _settle();

    expect(container.read(notificationsProvider).value?.length, 2,
        reason: '同一 ID の通知が dedup されなかった');
  });

  test('dispose 後に接続が確立したら listen → 即 cancel で接続を閉じる', () async {
    final container = await createContainerWithPendingSubscribe();

    // 接続確立の in-flight 中に notifier ごと破棄
    container.dispose();
    await _settle();

    // 遅れて接続が確立 → 誰も使わない stream は listen → 即 cancel で
    // broadcast controller の onCancel (= 底の接続 close) を発火させること
    pendingSubscribes.removeAt(0).complete(sseController.stream);
    await _pumpUntil(() => sseCancelCount == 1,
        reason: '破棄済み conn の stream が close されなかった (接続リーク)');
    expect(sseListenCount, 1);
  });
}
