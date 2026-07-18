// NotificationsNotifier.updateSelectedAccounts の冪等化テスト。
//
// NotificationsPage は State 再生成のたびに初期化パスから同一選択で
// updateSelectedAccounts を呼び直す (Deck の投稿ペイン開閉・モバイルの
// タブ往復等)。冪等化前はそのたびに AsyncValue.loading() + 全再フェッチが
// 走り、通知カラムがスピナー付きで全リロードされていた。
//
// 検証内容:
// - 同一選択の再呼び出しは HTTP リクエストを発行せず loading にも遷移しない
// - force: true は従来どおり再フェッチする (グルーピング設定変更経路)
// - 選択集合が変わる呼び出しは従来どおりフェッチする
// - 全解除 → 再選択は skip されずフェッチする
//
// テスト基盤は notifications_provider_race_test.dart と同じ
// (httpClient seam を MockClient に差し替え + SharedPreferences モック)。

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kurage/providers/auth_provider.dart';
import 'package:kurage/providers/notifications_provider.dart';
import 'package:kurage/services/mastodon_api.dart' as api;

const _accountJson1 = {
  'id': 'acct-1',
  'instanceUrl': 'https://example.test',
  'accessToken': 'token-1',
  'username': 'alice',
  'displayName': 'Alice',
  'avatarUrl': '',
};

const _accountJson2 = {
  'id': 'acct-2',
  'instanceUrl': 'https://example2.test',
  'accessToken': 'token-2',
  'username': 'bob',
  'displayName': 'Bob',
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late int notifRequestCount;
  late int notifSeq;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'accounts': jsonEncode([_accountJson1, _accountJson2]),
      // static な保存選択を確実に「選択なし」へリセットする
      // (キー欠落だと loadSavedSettings が前テストの値を温存するため)。
      'notification_selected_accounts': <String>[],
    });
    await NotificationsNotifier.loadSavedSettings();

    notifRequestCount = 0;
    notifSeq = 0;

    api.httpClient = MockClient((request) {
      final path = request.url.path;
      if (path.contains('/api/v2/notifications')) {
        // v2 未対応サーバとして振る舞い、常に v1 へフォールバックさせる
        return Future.value(http.Response('', 404));
      }
      if (path.contains('/api/v1/notifications')) {
        notifRequestCount++;
        return Future.value(_ok(_notifBody('n${++notifSeq}')));
      }
      return Future.value(http.Response('', 404));
    });
  });

  tearDown(() {
    api.httpClient = http.Client();
  });

  /// accounts ロード済みの container を作り、notifier の _init 完了
  /// (フォールバックフェッチの反映) まで進める。
  Future<(ProviderContainer, NotificationsNotifier)> createReady() async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(authProvider);
    await _pumpUntil(
      () => container.read(authProvider).accounts.isNotEmpty,
      reason: 'authProvider のアカウント読み込み',
    );
    final notifier = container.read(notificationsProvider.notifier);
    await _pumpUntil(
      () => container.read(notificationsProvider).hasValue,
      reason: '_init の完了',
    );
    return (container, notifier);
  }

  test('同一選択の再呼び出しはフェッチも loading 遷移もしない', () async {
    final (container, notifier) = await createReady();

    await notifier.updateSelectedAccounts(['acct-1']);
    expect(container.read(notificationsProvider).hasValue, isTrue);
    final requestsAfterFirst = notifRequestCount;
    expect(requestsAfterFirst, greaterThan(0));

    // loading 遷移の観測を開始
    var sawLoading = false;
    container.listen(notificationsProvider, (prev, next) {
      if (next.isLoading) sawLoading = true;
    });

    // NotificationsPage の State 再生成 (Deck ペイン開閉等) に相当する再突入
    await notifier.updateSelectedAccounts(['acct-1']);

    expect(notifRequestCount, requestsAfterFirst,
        reason: '同一選択の再呼び出しが再フェッチした');
    expect(sawLoading, isFalse,
        reason: '同一選択の再呼び出しで loading (スピナー) に遷移した');
    expect(container.read(notificationsProvider).hasValue, isTrue);
  });

  test('force: true は同一選択でも再フェッチする (グルーピング設定変更経路)', () async {
    final (_, notifier) = await createReady();

    await notifier.updateSelectedAccounts(['acct-1']);
    final requestsAfterFirst = notifRequestCount;

    await notifier.updateSelectedAccounts(['acct-1'], force: true);

    expect(notifRequestCount, greaterThan(requestsAfterFirst),
        reason: 'force: true なのに再フェッチされなかった');
  });

  test('選択集合が変わる呼び出しは従来どおりフェッチする', () async {
    final (_, notifier) = await createReady();

    await notifier.updateSelectedAccounts(['acct-1']);
    final requestsAfterFirst = notifRequestCount;

    // 順序違いの同一集合は skip される
    await notifier.updateSelectedAccounts(['acct-1']);
    expect(notifRequestCount, requestsAfterFirst);

    // 集合が変わればフェッチされる
    await notifier.updateSelectedAccounts(['acct-1', 'acct-2']);
    expect(notifRequestCount, greaterThan(requestsAfterFirst),
        reason: '選択集合の変更なのに再フェッチされなかった');
  });

  test('全解除 → 同一アカウント再選択は skip されずフェッチする', () async {
    final (container, notifier) = await createReady();

    await notifier.updateSelectedAccounts(['acct-1']);
    final requestsAfterFirst = notifRequestCount;

    await notifier.clearNotifications();
    expect(container.read(notificationsProvider).value, isEmpty);

    await notifier.updateSelectedAccounts(['acct-1']);
    expect(notifRequestCount, greaterThan(requestsAfterFirst),
        reason: '全解除からの再選択が skip された');
    expect(container.read(notificationsProvider).value, isNotEmpty,
        reason: '再選択後に通知が表示されていない');
  });
}
