// lib/providers/notifications_provider.dart

import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/auth_account.dart';
import '../models/notification_item.dart';
import '../models/notification_group.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/tab_state_provider.dart';
import '../services/mastodon_api.dart';
import '../services/sound_service.dart';

class NotificationsNotifier
    extends StateNotifier<AsyncValue<List<NotificationGroup>>> {
  NotificationsNotifier(this._ref) : super(const AsyncValue.loading()) {
    WidgetsBinding.instance.addObserver(_lifecycleObserver);
    // グルーピング設定の ON/OFF 切替を監視して即時リロード。
    // 旧データのキャッシュ (v1 wrap / v2 集約) が混ざらないよう全クリア
    // → 設定に応じた経路で再フェッチする (updateSelectedAccounts 経由)。
    _ref.listen<Settings>(settingsProvider, (prev, next) {
      if (prev != null &&
          prev.groupedNotifications != next.groupedNotifications) {
        debugPrint(
            '[Notifs] groupedNotifications changed: '
            '${prev.groupedNotifications} → ${next.groupedNotifications}, reloading');
        _reloadAfterSettingChange();
      }
    });
    _init();
  }

  /// グルーピング設定変更時の全リロード。既存の選択アカウントで
  /// `updateSelectedAccounts` を再実行する (=state を一旦 loading にして
  /// `_accountMaxIds` 等をクリア → 新しい経路で再フェッチ)。
  /// `_init` を呼び直さないのは late final (`instanceUrl` / `accessToken`)
  /// の再代入で死ぬため。`_selectedAccountIds` が空の場合は全アカウントを
  /// 対象にフォールバックする。
  Future<void> _reloadAfterSettingChange() async {
    // 明示的に全解除されている間は「空 = 全アカウント」フォールバックを
    // 使わない (未選択なのに通知が復活するため)。
    if (_selectionCleared) return;
    final ids = _selectedAccountIds.isNotEmpty
        ? _selectedAccountIds.toList()
        : _ref.read(authProvider).accounts.map((a) => a.id).toList();
    if (ids.isEmpty) return;
    // 同一選択でも v1/v2 経路を切り替えて再フェッチしたいので force。
    await updateSelectedAccounts(ids, force: true);
  }

  final Ref _ref;

  late final String instanceUrl;
  late final String accessToken;

  /// SSE 接続をアカウントごとに管理する。タイムライン側
  /// (`_StreamConnection` in [timeline_view.dart]) と同じ構造で、
  /// 指数バックオフ再接続 + サイレント切断 watchdog を備える。
  /// 旧実装は単に `stream.listen` するだけだったので、`onError` /
  /// `onDone` ハンドラ無し → 接続が黙って死ぬとずっと死んだまま、
  /// アプリ復帰時の強制再接続も無し、という穴があった。
  final List<_NotifStreamConnection> _streamConns = [];
  Timer? _livenessCheckTimer;
  static const _livenessCheckInterval = Duration(seconds: 60);
  // 5 分以上イベント無音なら死亡判定。タイムライン側 (10 分) より
  // 短めにしているのは、通知のほうが頻度が低くユーザーが気にしやすい
  // (= 古いままだと「来てないのか?」となる) ため。
  static const _livenessTimeoutSeconds = 300;
  static const _backoffSeconds = [1, 2, 5, 10, 20, 30];
  // 再接続検知時 refresh のデバウンス。複数アカウントが同時に
  // 再接続しても 1 回しか HTTP を叩かない。
  DateTime? _lastReconnectRefreshAt;

  /// SSE で受信済みの通知キー (`accountId:notificationId`) の直近 N 件。
  /// 接続の張り直しやサーバ側の再送で同じ通知が複数回流れてきても
  /// 二重表示 (+未読二重加算・通知音二重再生) しないための防御的 dedup。
  /// state 全走査は避け、挿入順 Set の O(1) 判定で済ませる。
  final Set<String> _recentSseKeys = <String>{};
  static const _recentSseKeysCap = 128;

  /// アプリ復帰 (resumed) を捕捉して全 SSE 接続を強制再接続する。
  /// `WidgetsBindingObserver` を mixin する代わりに小さな delegate
  /// オブジェクトを持って addObserver する形にしている。StateNotifier
  /// と Observer の責務をクラス本体で混ぜないため。
  late final _NotifLifecycleObserver _lifecycleObserver =
      _NotifLifecycleObserver(onResumed: _forceReconnectAllStreams);

  final List<String> _selectedAccountIds = [];
  static List<String> _savedSelectedAccountIds = [];
  static Map<String, bool> _savedFilters = {};

  /// アカウント選択の世代カウンタ。`_init` / `updateSelectedAccounts` /
  /// `clearNotifications` を呼ぶたびに更新し、非同期フェッチの完了時に
  /// 「自分の世代がまだ最新か」を確認する。素早い 2 連続タップで、古い
  /// フェッチが後から `state` を上書きして「未選択なのに通知が出る」状態に
  /// なるのを防ぐ。
  int _selectionRequestId = 0;

  /// ユーザーが明示的にアカウント選択を全解除した状態か。
  /// `refresh()` / `loadMore()` / `_reloadAfterSettingChange` には選択が空の
  /// ときのフォールバック分岐 (レガシー単一アカウントモード / 全アカウント)
  /// があり、全解除直後にこれらが走ると「未選択なのに内容が復活する」ため、
  /// このフラグが true の間はフォールバックを止める。
  bool _selectionCleared = false;

  // キャッシュ用 (v1 NotificationItem ではなく内部表現の NotificationGroup を保持)
  static final Map<String, List<NotificationGroup>> _cachedNotifications = {};
  static final Map<String, DateTime> _lastFetchTime = {};

  /// 設定の groupedNotifications を読む。設定 _load 完了前は false 扱い。
  bool get _groupedEnabled {
    try {
      return _ref.read(settingsProvider).groupedNotifications;
    } catch (_) {
      return false;
    }
  }

  /// アカウント 1 件分の通知取得。設定 ON のときは /api/v2/notifications を
  /// 試し、404 (= 4.3 未満 / 派生実装) なら v1 にフォールバックして単体グループに
  /// ラップする。両経路で sourceAccountId を埋めて返す。
  ///
  /// この関数を介すことで _init / loadMore / refresh / updateSelectedAccounts
  /// すべてが「グループとして揃った List」を扱える。
  Future<List<NotificationGroup>> _fetchForAccount(
    AuthAccount account, {
    required int limit,
    String? maxId,
    String? sinceId,
  }) async {
    if (_groupedEnabled) {
      try {
        final groups = await fetchNotificationGroups(
          instanceUrl: account.instanceUrl,
          accessToken: account.accessToken,
          limit: limit,
          maxId: maxId,
          sinceId: sinceId,
        );
        for (final g in groups) {
          g.sourceAccountId = account.id;
        }
        // 初回フェッチ (maxId/sinceId なし) で v2 が 0 件返した場合は v1 にも
        // 当ててみる。v2 エンドポイントが期待外のレスポンス形式 (例: 派生実装、
        // 一部 Mastodon バージョン) で 0 件と判定されるケースを救う。
        // 結果として `_accountMaxIds` がいつまでも空のまま「通知が遡れない」
        // 状態になるのを防ぐ。ページング (maxId/sinceId あり) のときは
        // 「末尾到達」と解釈してそのまま空を返す。
        if (groups.isEmpty && maxId == null && sinceId == null) {
          debugPrint(
              '[Notifs] v2 returned 0 on initial fetch, falling back to v1');
        } else {
          return groups;
        }
      } on NotificationsV2NotSupportedException catch (_) {
        // 黙って v1 にフォールバック
      } on NotificationsAuthException {
        // トークン失効等の認証エラーは v1 でも同じ失敗をするだけなので、
        // フォールバックせず (無駄なリクエストとエラー原因のすり替わりを
        // 避けるため) そのまま上へ流す。
        rethrow;
      } catch (e) {
        debugPrint('[Notifs v2] 失敗、v1 にフォールバック: $e');
      }
    }
    final items = await fetchNotifications(
      instanceUrl: account.instanceUrl,
      accessToken: account.accessToken,
      limit: limit,
      maxId: maxId,
      sinceId: sinceId,
    );
    for (final i in items) {
      i.sourceAccountId = account.id;
    }
    return NotificationGroup.singlesFrom(items);
  }

  // ページング用
  String? _maxId;
  final Map<String, String> _accountMaxIds = {}; // アカウントごとのmaxId
  final Map<String, DateTime> _accountOldestTimes = {}; // アカウントごとの最古表示時刻
  bool   _loadingMore = false;
  // pull-to-refresh と SSE 再接続由来の refresh が同時に走らないようにする。
  // 通知 SSE は再接続時に取り逃した分を refresh で回収する設計なので、
  // 連続再接続でもガードで 1 回に収束。
  bool   _refreshing = false;

  // 未読数管理用
  int _unreadCount = 0;
  String? _lastReadNotificationId;
  static const _prefsKeyLastReadId = 'last_read_notification_id';

  /// いま画面に表示されている通知カラム (embedded [NotificationsPage]) の数。
  /// 通知をカラムとして常設表示している場合 (方針A)、ユーザーは通知タブを
  /// 開いていなくても新着を見えているので、通知タブを開いているのと同様に
  /// 「未読バッジを増やさない / 表示開始時に既読化する」扱いにする。
  /// 複数の通知カラムを開くこともあるのでカウンタで管理する。
  int _activeNotificationViewers = 0;

  /// 通知がいまユーザーに見えているか (通知タブを開いている or 通知カラムが
  /// 1 つ以上表示中)。見えているなら新着を未読として積まない。
  bool get _notificationCurrentlyVisible =>
      _ref.read(tabStateProvider) == 1 || _activeNotificationViewers > 0;

  /// `_lastReadNotificationId` を永続化する (fire-and-forget)。
  void _persistLastReadId() {
    final id = _lastReadNotificationId;
    if (id == null) return;
    SharedPreferences.getInstance()
        .then((p) => p.setString(_prefsKeyLastReadId, id));
  }

  /// 通知カラム (embedded NotificationsPage) が表示状態になったことを登録する。
  /// 0 → 1 の遷移 (= どこも表示していなかったのが表示され始めた) ときは、
  /// それまでに溜まっていた未読をクリアする。
  void addNotificationViewer() {
    _activeNotificationViewers++;
    if (_activeNotificationViewers == 1) {
      markAsRead();
    }
  }

  /// 通知カラムが非表示になったことを登録する。
  void removeNotificationViewer() {
    if (_activeNotificationViewers > 0) _activeNotificationViewers--;
  }

  Future<void> _init() async {
    // updateSelectedAccounts と同じ世代ガード。このフォールバックフェッチは
    // 起動直後に飛ぶため、完了前にユーザーがアカウント選択を操作 (特に素早い
    // ON→OFF の clearNotifications) すると、ガード無しでは古い結果が後から
    // state を上書きし、stray な SSE 接続まで残って「未選択なのに通知が
    // 表示される」状態になる。
    final reqId = ++_selectionRequestId;
    try {
      final accounts = _ref.read(authProvider).accounts;
      if (accounts.isEmpty) {
        state = const AsyncValue.data([]);
        return;
      }

      // 保存された最後に読んだ通知IDを読み込む
      await _loadLastReadId();
      if (reqId != _selectionRequestId) return;

      // `current` 概念廃止に伴い、初期は「前回通知ページで選択したアカウント
      // (有効なものだけ)」を使う。なければ accounts.first にフォールバック。
      final savedIds = _savedSelectedAccountIds
          .where((id) => accounts.any((a) => a.id == id))
          .toList();
      if (savedIds.isNotEmpty) {
        await updateSelectedAccounts(savedIds);
        return;
      }

      final account = accounts.first;
      instanceUrl = account.instanceUrl;
      accessToken = account.accessToken;

      // 初回 20 件取得 (グループ表現で受ける)
      final initial = await _fetchForAccount(account, limit: 20);
      if (reqId != _selectionRequestId) return;

      _calculateUnreadCount(initial);

      state = AsyncValue.data(initial);
      if (initial.isNotEmpty) {
        _maxId = initial.last.mostRecentNotificationId;
      }

      _setupConnectionFor(
        accountId: account.id,
        instanceUrl: instanceUrl,
        accessToken: accessToken,
      );
    } catch (e, st) {
      if (reqId != _selectionRequestId) return;
      state = AsyncValue.error(e, st);
    }
  }

  /// 無限スクロールで過去の通知を取得 (グループ表現)
  Future<void> loadMore() async {
    if (_loadingMore) return;
    // 全解除中は「選択が空 = レガシー単一アカウントモード」分岐に入れない
    // (stale な _maxId / instanceUrl で未選択なのに内容が復活するため)。
    if (_selectionCleared) return;
    _loadingMore = true;
    try {
      if (_selectedAccountIds.isEmpty) {
        // 単一アカウントの場合
        if (_maxId == null) return;
        final account = _ref.read(authProvider).accounts.firstWhere(
              (a) => a.instanceUrl == instanceUrl,
              orElse: () => _ref.read(authProvider).accounts.first,
            );
        final older = await _fetchForAccount(account, limit: 20, maxId: _maxId);
        if (older.isNotEmpty) {
          final current = state.value ?? [];
          final existingKeys = current.map((g) => g.groupKey).toSet();
          final deduped = older
              .where((g) => !existingKeys.contains(g.groupKey))
              .toList();
          state = AsyncValue.data([...current, ...deduped]);
          _maxId = older.last.mostRecentNotificationId;
        }
      } else {
        // 複数アカウントの場合
        final authState = _ref.read(authProvider);
        final accounts = authState.accounts
            .where((a) => _selectedAccountIds.contains(a.id))
            .toList();

        final allOlder = <NotificationGroup>[];

        for (final account in accounts) {
          final accountMaxId = _accountMaxIds[account.id];
          if (accountMaxId == null) continue;

          try {
            final older = await _fetchForAccount(account,
                limit: 20, maxId: accountMaxId);
            if (older.isNotEmpty) {
              _accountMaxIds[account.id] = older.last.mostRecentNotificationId;
            }
            allOlder.addAll(older);
          } catch (e) {
            debugPrint('[Notifs] loadMore ${account.id} error: $e');
          }
        }

        if (allOlder.isNotEmpty) {
          final current = state.value ?? [];

          // アカウントごとに、そのアカウントの最古表示時刻以下のもののみフィルタ。
          // 等号 (==) は弾かない (境界グループが同 latestAt を持つケースで
          // 新しい older が誤って rejected されるのを避ける。重複は groupKey
          // dedup 側で排除されるので二重表示にはならない)。
          final filtered = <NotificationGroup>[];
          for (final g in allOlder) {
            final oldestTime = _accountOldestTimes[g.sourceAccountId];
            if (oldestTime == null || !g.latestAt.isAfter(oldestTime)) {
              filtered.add(g);
            }
          }

          if (filtered.isNotEmpty) {
            for (final g in filtered) {
              final accountId = g.sourceAccountId;
              if (accountId == null) continue;
              final currentOldest = _accountOldestTimes[accountId];
              if (currentOldest == null || g.latestAt.isBefore(currentOldest)) {
                _accountOldestTimes[accountId] = g.latestAt;
              }
            }

            final existingKeys = current.map((g) => g.groupKey).toSet();
            final deduped = filtered
                .where((g) => !existingKeys.contains(g.groupKey))
                .toList();

            final combined = [...current, ...deduped];
            combined.sort((a, b) => b.latestAt.compareTo(a.latestAt));
            state = AsyncValue.data(combined);
          }
        }
      }
    } catch (e) {
      debugPrint('[Notifs] loadMore exception: $e');
    } finally {
      _loadingMore = false;
    }
  }

  /// Pull-to-refresh で差分取得。通知タブ自動 refresh からも同じ経路で呼ばれる。
  /// グルーピング ON のサーバから差分を取ると、既存リストに同じ group_key の
  /// グループが入っている場合は server 側のより新しい集約値に置き換える。
  Future<void> refresh() async {
    if (_refreshing) return;
    // 全解除中は何も取得しない。これがないと Deck カラムの更新ボタンや
    // SSE 再接続由来の refresh で accounts.first へフォールバックして
    // 未選択なのに内容が復活する。
    if (_selectionCleared) return;
    _refreshing = true;
    final current = state.value ?? [];
    final sinceId =
        current.isNotEmpty ? current.first.mostRecentNotificationId : null;

    try {
      if (_selectedAccountIds.isEmpty) {
        final account = _ref.read(authProvider).accounts.firstWhere(
              (a) => a.instanceUrl == instanceUrl,
              orElse: () => _ref.read(authProvider).accounts.first,
            );
        final newer =
            await _fetchForAccount(account, limit: 20, sinceId: sinceId);
        if (newer.isNotEmpty) {
          final combined = _mergeFetched(newer, current);
          state = AsyncValue.data(combined);
          _updateCache(combined);
        }
      } else {
        final authState = _ref.read(authProvider);
        final accounts = authState.accounts
            .where((a) => _selectedAccountIds.contains(a.id))
            .toList();

        final allNewer = <NotificationGroup>[];
        for (final account in accounts) {
          try {
            final newer =
                await _fetchForAccount(account, limit: 20, sinceId: sinceId);
            allNewer.addAll(newer);
          } catch (e) {
            // 個別アカウントのエラーは無視
          }
        }

        if (allNewer.isNotEmpty) {
          final combined = _mergeFetched(allNewer, current);
          state = AsyncValue.data(combined);
          _updateCache(combined);
        }
      }
    } catch (e) {
      // 必要であれば state = AsyncValue.error(e, st);
    } finally {
      _refreshing = false;
    }
  }

  /// [updateSelectedAccounts] の冪等判定用。順序を無視した集合として比較する。
  static bool _sameIdSet(List<String> a, List<String> b) =>
      a.length == b.length && a.toSet().containsAll(b);

  /// fetch で取れた最新グループを既存リストにマージ (実体はモデル側の
  /// [NotificationGroup.mergeFetched]。unit test 可能にするため移設した)。
  List<NotificationGroup> _mergeFetched(
    List<NotificationGroup> fetched,
    List<NotificationGroup> current,
  ) {
    return NotificationGroup.mergeFetched(fetched, current);
  }

  Future<void> updateSelectedAccounts(List<String> accountIds,
      {bool force = false}) async {
    // 冪等化: 選択が現状と同一で、既にデータを持っているなら何もしない。
    // NotificationsPage は State 再生成のたびに初期化パスから同一選択で
    // ここへ再突入する (Deck の投稿ペイン開閉・モバイルのタブ往復等) ため、
    // 無条件にリロードすると通知カラムがスピナー付きで全再読込されてしまう。
    // グルーピング設定変更のような「同一選択での意図的な全リロード」は
    // force: true で従来挙動を維持する。
    // 判定は reqId を進める前に行う (in-flight の正当なフェッチを無効化しない)。
    if (!force &&
        !_selectionCleared &&
        accountIds.isNotEmpty &&
        state.hasValue &&
        _sameIdSet(accountIds, _selectedAccountIds)) {
      return;
    }

    // この呼び出しを最新世代として記録。以降の await の後で世代が変わって
    // いたら (= より新しい選択操作 / clear が来ていたら) 自分の結果で state を
    // 上書きしないように早期 return する。
    final reqId = ++_selectionRequestId;

    final previousAccountIds = Set.from(_selectedAccountIds);
    final newAccountIds = Set.from(accountIds);

    _selectedAccountIds.clear();
    _selectedAccountIds.addAll(accountIds);
    _selectionCleared = accountIds.isEmpty;

    // 永続化
    await saveSelectedAccountIds(accountIds);
    if (reqId != _selectionRequestId) return;

    // 既存の SSE 接続を全部畳む (新しいアカウントセットでセットアップし直す)
    _disconnectAllStreams();

    // アカウントごとのmaxIdと最古時刻もクリア
    _accountMaxIds.clear();
    _accountOldestTimes.clear();

    if (accountIds.isEmpty) {
      _maxId = null;
      state = const AsyncValue.data([]);
      return;
    }
    
    // アカウント切り替えが発生した場合は関連キャッシュをクリア
    if (!previousAccountIds.containsAll(newAccountIds) || !newAccountIds.containsAll(previousAccountIds)) {
      debugPrint('Notifications: Account selection changed, clearing related cache');
      _clearRelatedCache(accountIds);
    }
    
    // アカウント切り替え時は常にローディング状態から開始
    state = const AsyncValue.loading();
    
    // キャッシュキーを作成（アカウントIDをソートして結合）
    final cacheKey = accountIds.toList()..sort();
    final cacheKeyStr = cacheKey.join(',');
    
    try {
      final authState = _ref.read(authProvider);
      final accounts = authState.accounts
          .where((a) => accountIds.contains(a.id))
          .toList();

      final allGroups = <NotificationGroup>[];

      for (final account in accounts) {
        try {
          final groups = await _fetchForAccount(account, limit: 20);
          // フェッチ中に選択が変わっていたら、SSE 再接続も state 反映もせず中断。
          if (reqId != _selectionRequestId) return;

          if (groups.isNotEmpty) {
            _accountMaxIds[account.id] = groups.last.mostRecentNotificationId;
            _accountOldestTimes[account.id] = groups.last.latestAt;
          }

          allGroups.addAll(groups);

          _setupConnectionFor(
            accountId: account.id,
            instanceUrl: account.instanceUrl,
            accessToken: account.accessToken,
          );
        } catch (e) {
          // 個別アカウントのエラーは無視
        }
      }

      // ループ完了後にも世代を確認 (最後のフェッチ直後に選択が変わった場合)。
      if (reqId != _selectionRequestId) return;

      allGroups.sort((a, b) => b.latestAt.compareTo(a.latestAt));

      _calculateUnreadCount(allGroups);

      state = AsyncValue.data(allGroups);
      if (allGroups.isNotEmpty) {
        _maxId = allGroups.last.mostRecentNotificationId;
      }

      _cachedNotifications[cacheKeyStr] = List.from(allGroups);
      _lastFetchTime[cacheKeyStr] = DateTime.now();
    } catch (e, st) {
      if (reqId != _selectionRequestId) return;
      state = AsyncValue.error(e, st);
    }
  }
  
  /// 関連するキャッシュをクリア
  void _clearRelatedCache(List<String> accountIds) {
    final keysToRemove = <String>[];
    for (final key in _cachedNotifications.keys) {
      final cachedAccountIds = key.split(',');
      // 新しいアカウント選択と異なるキャッシュをクリア
      if (!_listsEqual(cachedAccountIds, accountIds)) {
        keysToRemove.add(key);
      }
    }
    
    for (final key in keysToRemove) {
      _cachedNotifications.remove(key);
      _lastFetchTime.remove(key);
    }
    
    debugPrint('Notifications: Cleared ${keysToRemove.length} cache entries');
  }
  
  /// リストの内容が同じかチェック
  bool _listsEqual(List<String> list1, List<String> list2) {
    if (list1.length != list2.length) return false;
    final sorted1 = list1.toList()..sort();
    final sorted2 = list2.toList()..sort();
    for (int i = 0; i < sorted1.length; i++) {
      if (sorted1[i] != sorted2[i]) return false;
    }
    return true;
  }
  
  /// キャッシュを更新
  void _updateCache(List<NotificationGroup> groups) {
    if (_selectedAccountIds.isNotEmpty) {
      final cacheKey = _selectedAccountIds.toList()..sort();
      final cacheKeyStr = cacheKey.join(',');
      _cachedNotifications[cacheKeyStr] = List.from(groups);
      _lastFetchTime[cacheKeyStr] = DateTime.now();
    }
  }
  
  Future<void> clearNotifications() async {
    // 進行中の _init / updateSelectedAccounts のフェッチ完了が後から state を
    // 上書きしないよう、世代を進めて無効化する。
    _selectionRequestId++;
    _selectionCleared = true;
    _disconnectAllStreams();
    _selectedAccountIds.clear();
    _accountMaxIds.clear();
    _accountOldestTimes.clear();
    // レガシー単一アカウント分岐のページング位置も無効化 (これを残すと
    // loadMore が stale な位置から未選択のまま復活取得できてしまう)。
    _maxId = null;
    state = const AsyncValue.data([]);

    // 永続化もクリア
    await saveSelectedAccountIds([]);
  }

  static List<String> getSavedSelectedAccountIds() => _savedSelectedAccountIds;
  static Map<String, bool> getSavedFilters() => _savedFilters;
  
  /// フィルター設定を永続化
  static Future<void> saveFilters(Map<String, bool> filters) async {
    _savedFilters = Map.from(filters);
    
    final prefs = await SharedPreferences.getInstance();
    for (var entry in filters.entries) {
      final key = entry.key.toString();
      await prefs.setBool('notification_filter_$key', entry.value);
    }
  }
  
  /// アカウント選択を永続化
  static Future<void> saveSelectedAccountIds(List<String> accountIds) async {
    _savedSelectedAccountIds = List.from(accountIds);
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('notification_selected_accounts', accountIds);
  }
  
  /// 初期化時に保存された設定を読み込む
  static Future<void> loadSavedSettings() async {
    final prefs = await SharedPreferences.getInstance();
    
    // フィルター設定を読み込む
    _savedFilters.clear();
    for (var type in NotificationType.values) {
      final key = type.toString();
      final value = prefs.getBool('notification_filter_$key');
      if (value != null) {
        _savedFilters[key] = value;
      }
    }
    
    // アカウント選択を読み込む
    final savedAccounts = prefs.getStringList('notification_selected_accounts');
    if (savedAccounts != null) {
      _savedSelectedAccountIds = List.from(savedAccounts);
    }
  }

  /// 最後に読んだ通知IDを読み込む
  Future<void> _loadLastReadId() async {
    final prefs = await SharedPreferences.getInstance();
    _lastReadNotificationId = prefs.getString(_prefsKeyLastReadId);
  }

  /// 未読数を計算。グループ単位ではなく個別通知単位でカウントする
  /// (バッジに「未読 5 件」と出ていて中身が 1 グループ 5 favs だったとき、
  /// グルーピング ON/OFF で件数が変わると違和感が出るため)。
  ///
  /// 各グループの mostRecentNotificationId が `_lastReadNotificationId` より
  /// 新しいなら、そのグループの `notificationsCount` 全部を未読として加算する。
  /// 完全に正確ではない (部分的に既読のグループは過大カウント) が、運用上は
  /// 「グループ全体が新しいかどうか」で 1 つの read line を引く方が直感的。
  void _calculateUnreadCount(List<NotificationGroup> groups) {
    // 通知カラムを表示中 (or 通知タブ) なら、ロード結果は全て既読扱いにする。
    // (カラム表示中に初回ロード / アカウント切替の再フェッチが完了したケース)。
    if (_notificationCurrentlyVisible) {
      _unreadCount = 0;
      if (groups.isNotEmpty) {
        _lastReadNotificationId = groups.first.mostRecentNotificationId;
        _persistLastReadId();
      }
      return;
    }
    if (_lastReadNotificationId == null) {
      _unreadCount = 0;
      if (groups.isNotEmpty) markAsRead();
      return;
    }
    _unreadCount = 0;
    for (final g in groups) {
      // Mastodon ID は時系列でソート可能な文字列なので lexicographic 比較で OK
      if (g.mostRecentNotificationId.compareTo(_lastReadNotificationId!) <= 0) {
        break;
      }
      _unreadCount += g.notificationsCount;
    }
  }

  /// 新着通知 1 件を未読数に反映する。通知タブを開いている時は即既読扱い
  /// にして未読カウントを増やさず、`_lastReadNotificationId` も更新する。
  /// 両 SSE listener から呼ぶ共通処理。
  void _onNewNotificationArrived(NotificationItem item) {
    if (_notificationCurrentlyVisible) {
      // 通知タブを開いている or 通知カラムを表示中なので未読扱いにしない。
      // 最新を既読位置にする。
      _lastReadNotificationId = item.id;
      _persistLastReadId();
    } else {
      _unreadCount++;
    }
    // 効果音 (フォアグラウンドのみ・既定 OFF)。burst 抑制は SoundService 側。
    if (_ref.read(settingsProvider).soundOnNotification) {
      SoundService.instance.notification();
    }
  }

  /// 通知を既読にする。最新グループの `mostRecentNotificationId` を読み位置にする。
  Future<void> markAsRead() async {
    final current = state.value;
    if (current == null || current.isEmpty) return;

    _lastReadNotificationId = current.first.mostRecentNotificationId;
    _unreadCount = 0;

    // unreadNotificationCountProvider のリビルドを促すため、state を
    // 「同じデータの新インスタンス」で更新する。フィールドだけ書き換えても
    // StateNotifier は通知を発行しないので、watcher が再評価されない。
    state = AsyncValue.data(List<NotificationGroup>.from(current));

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKeyLastReadId, _lastReadNotificationId!);
  }

  /// 未読数を取得
  int get unreadCount => _unreadCount;

  // ============================================================
  // SSE 接続管理 (再接続 + watchdog + アプリ復帰時 force reconnect)
  // ============================================================

  /// 1 アカウント分の SSE 接続をセットアップする。`_init` の単一アカウント
  /// パスと `updateSelectedAccounts` のマルチアカウントパス両方から呼ばれる。
  /// 接続オブジェクトを作って `_streamConns` に登録 → 即時接続を試行 →
  /// watchdog を起動。冪等なので連続呼び出ししても安全。
  void _setupConnectionFor({
    required String accountId,
    required String instanceUrl,
    required String accessToken,
  }) {
    final conn = _NotifStreamConnection(
      accountId: accountId,
      instanceUrl: instanceUrl,
      accessToken: accessToken,
    );
    _streamConns.add(conn);
    _connectStream(conn);
    _startLivenessChecker();
  }

  /// 1 接続の確立 (失敗したら `_scheduleReconnect`)。
  ///
  /// 同じ conn に対する重複起動は `conn.connectInFlight` で合流させる
  /// (timeline_view 側 `_connectStream` と同じパターン)。forceReconnect
  /// (アプリ復帰) / watchdog / バックオフ Timer が接続確立の await 中に
  /// 重なって再突入すると、旧実装では両方の試行が `stream.listen` まで
  /// 完走し、先に張った subscription が cancel されないまま残って
  /// **同一アカウントの通知が二重配信** (= 通知一覧に 2 件表示) されていた。
  Future<void> _connectStream(_NotifStreamConnection conn) {
    return conn.connectInFlight ??=
        _doConnectStream(conn).whenComplete(() {
      conn.connectInFlight = null;
    });
  }

  Future<void> _doConnectStream(_NotifStreamConnection conn) async {
    conn.subscription?.cancel();
    conn.subscription = null;
    conn.reconnectTimer?.cancel();
    conn.reconnectTimer = null;
    if (!mounted) return;

    try {
      final stream = await subscribeNotifications(
        instanceUrl: conn.instanceUrl,
        accessToken: conn.accessToken,
      );
      if (!mounted || !_streamConns.contains(conn)) {
        // dispose / アカウント選択変更で conn が破棄された後に接続が確立した
        // ケース。SSE の底の接続は broadcast controller の onCancel (listener
        // が 0 になった時) でしか閉じられないため、listen → 即 cancel で
        // close を発火させる。放置すると HttpClient がリークする。
        unawaited(stream.listen(null).cancel());
        return;
      }
      conn.subscription = stream.listen(
        (item) => _onConnEvent(conn, item),
        onError: (e) => _onConnError(conn, e),
        onDone: () => _onConnDone(conn),
        cancelOnError: true,
      );
      _markStreamConnected(conn);
    } catch (e) {
      debugPrint('[Notif SSE] connect failed for ${conn.accountId}: $e');
      if (!mounted) return;
      _scheduleReconnect(conn);
    }
  }

  /// SSE から 1 件の `NotificationItem` を受信。グループ表現にラップして
  /// 既存リストにマージする。
  ///
  /// - グルーピング ON で、既存リストに `canMerge` するグループがあれば
  ///   `mergedWith` で置き換えて先頭に移動 (= 同じ status への複数 fav 等を集約)
  /// - マージ先が無いか OFF なら新規 singleton として先頭 prepend
  void _onConnEvent(_NotifStreamConnection conn, NotificationItem item) {
    conn.lastEventAt = DateTime.now();

    // 防御的 dedup: 同じ通知が二重配信されたら 2 回目以降は無視する
    // (未読カウント・通知音の二重も同時に防ぐ)。通知 ID はサーバローカル
    // なので accountId を混ぜてキーにする。
    final dedupKey = '${conn.accountId}:${item.id}';
    if (_recentSseKeys.contains(dedupKey)) {
      debugPrint('[Notif SSE] duplicate notification ignored: $dedupKey');
      return;
    }
    _recentSseKeys.add(dedupKey);
    if (_recentSseKeys.length > _recentSseKeysCap) {
      _recentSseKeys.remove(_recentSseKeys.first); // 挿入順 Set なので最古を落とす
    }

    item.sourceAccountId = conn.accountId;
    _onNewNotificationArrived(item);

    final incoming = NotificationGroup.single(item);
    final grouped = _groupedEnabled;

    state = state.whenData((list) {
      if (grouped) {
        for (var i = 0; i < list.length; i++) {
          final g = list[i];
          if (g.canMerge(incoming)) {
            final merged = g.mergedWith(incoming);
            final updated = [
              merged,
              for (var j = 0; j < list.length; j++)
                if (j != i) list[j],
            ];
            return updated;
          }
        }
      }
      // マージ先が無い / グルーピング OFF: 新規 singleton として時系列に挿入。
      //
      // 旧実装は毎イベント全件ソート (O(n log n)) を回しており、bot ブースト
      // 連打や複数アカウント運用で n=200+ になると 1〜2ms × イベント分の
      // CPU を消費していた (通知タブ表示中はその都度 ListView.builder も
      // 再評価される)。
      //
      // 実際には Mastodon SSE は newest-first 順に送られてくるので、incoming
      // の latestAt はほぼ常に list.first.latestAt 以上 = 単純 prepend で
      // 降順を保てる。連合遅延等で逆順イベントが来た稀なケースのみ二分探索で
      // 挿入位置を決める。`mergedWith` 経路は既に O(n) prepend なので同じ
      // 計算量に揃った。
      if (list.isEmpty ||
          !incoming.latestAt.isBefore(list.first.latestAt)) {
        return <NotificationGroup>[incoming, ...list];
      }
      final insertAt = _insertIndexForLatestAtDesc(list, incoming.latestAt);
      return <NotificationGroup>[
        ...list.sublist(0, insertAt),
        incoming,
        ...list.sublist(insertAt),
      ];
    });
  }

  /// `list` は `latestAt` 降順ソート済み前提。`target` を挿入すべき
  /// 最小インデックスを二分探索で返す。
  ///
  /// 不変条件: 戻り値を `idx` とすると、`idx == 0` または
  /// `list[idx-1].latestAt >= target`、かつ
  /// `idx == list.length` または `list[idx].latestAt < target`。
  static int _insertIndexForLatestAtDesc(
    List<NotificationGroup> list,
    DateTime target,
  ) {
    var lo = 0;
    var hi = list.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (list[mid].latestAt.isBefore(target)) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return lo;
  }

  void _onConnError(_NotifStreamConnection conn, Object e) {
    debugPrint('[Notif SSE] error on ${conn.accountId}: $e');
    _scheduleReconnect(conn);
  }

  void _onConnDone(_NotifStreamConnection conn) {
    debugPrint('[Notif SSE] done on ${conn.accountId}');
    _scheduleReconnect(conn);
  }

  /// 指数バックオフで再接続を予約。1s/2s/5s/10s/20s/30s と段階的に伸びる。
  void _scheduleReconnect(_NotifStreamConnection conn) {
    conn.subscription?.cancel();
    conn.subscription = null;
    conn.reconnectTimer?.cancel();
    conn.reconnectTimer = null;
    _markStreamDisconnected(conn);
    if (!mounted) return;
    if (!_streamConns.contains(conn)) return;

    final attemptIdx = conn.attempt < _backoffSeconds.length
        ? conn.attempt
        : _backoffSeconds.length - 1;
    final delay = Duration(seconds: _backoffSeconds[attemptIdx]);
    conn.attempt++;
    debugPrint(
        '[Notif SSE] schedule reconnect ${conn.accountId} in ${delay.inSeconds}s '
        '(attempt ${conn.attempt})');
    conn.reconnectTimer = Timer(delay, () {
      if (!mounted) return;
      if (!_streamConns.contains(conn)) return;
      _connectStream(conn);
    });
  }

  /// 接続成功時に呼ぶ。初回接続でなければ「再接続」とみなして
  /// `_recoverFromStreamReconnect` で取りこぼし通知を refresh で回収する。
  void _markStreamConnected(_NotifStreamConnection conn) {
    if (conn.isConnected) return;
    final isReconnect = conn.everConnected;
    conn.isConnected = true;
    conn.everConnected = true;
    conn.lastEventAt = DateTime.now();
    conn.attempt = 0; // 成功でバックオフリセット
    if (isReconnect) _recoverFromStreamReconnect();
  }

  void _markStreamDisconnected(_NotifStreamConnection conn) {
    conn.isConnected = false;
  }

  /// SSE は再接続しても切断中に発行されたイベントを再送しないので、
  /// `since_id` ベースの REST 取得 (`refresh()`) で取りこぼしを埋める。
  /// 複数アカウントが同時に再接続したり、バックオフ中の連続再接続で
  /// 過剰に refresh しないよう 10 秒のデバウンス。
  void _recoverFromStreamReconnect() {
    final now = DateTime.now();
    final last = _lastReconnectRefreshAt;
    if (last != null && now.difference(last).inSeconds < 10) {
      debugPrint('[Notif SSE] reconnect refresh debounced');
      return;
    }
    _lastReconnectRefreshAt = now;
    debugPrint('[Notif SSE] reconnect detected, fetching missed notifications');
    refresh();
  }

  /// プロキシ / NAT timeout 等で `onError` も `onDone` も発火させない
  /// 「黙って死ぬ」SSE を検出するための watchdog。`lastEventAt` が
  /// `_livenessTimeoutSeconds` を超えていたら強制再接続する。
  void _startLivenessChecker() {
    _livenessCheckTimer?.cancel();
    _livenessCheckTimer = Timer.periodic(_livenessCheckInterval, (_) {
      _checkStreamLiveness();
    });
  }

  void _checkStreamLiveness() {
    if (!mounted) return;
    final now = DateTime.now();
    for (final conn in _streamConns) {
      if (!conn.isConnected) continue; // バックオフ中は通常フローに任せる
      final last = conn.lastEventAt;
      if (last == null) continue;
      final silentSeconds = now.difference(last).inSeconds;
      if (silentSeconds < _livenessTimeoutSeconds) continue;
      debugPrint(
          '[Notif SSE] silent for ${silentSeconds}s on ${conn.accountId}, '
          'force-reconnecting');
      conn.attempt = 0; // バックオフリセット (これは「死亡検出」発端なので即時)
      conn.reconnectTimer?.cancel();
      conn.reconnectTimer = null;
      _markStreamDisconnected(conn);
      _connectStream(conn);
    }
  }

  /// アプリ復帰 (resumed) で全接続を強制再接続する。OS がバックグラウンド中に
  /// TCP を畳んでいることが多いので、復帰のたびにバックオフをリセットして
  /// 即時再試行する (timeline_view と同じポリシー)。
  void _forceReconnectAllStreams() {
    if (!mounted) return;
    for (final conn in _streamConns) {
      conn.attempt = 0;
      conn.reconnectTimer?.cancel();
      conn.reconnectTimer = null;
      conn.subscription?.cancel();
      conn.subscription = null;
      _markStreamDisconnected(conn);
      _connectStream(conn);
    }
  }

  void _disconnectAllStreams() {
    _livenessCheckTimer?.cancel();
    _livenessCheckTimer = null;
    for (final conn in _streamConns) {
      conn.subscription?.cancel();
      conn.subscription = null;
      conn.reconnectTimer?.cancel();
      conn.reconnectTimer = null;
    }
    _streamConns.clear();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(_lifecycleObserver);
    _disconnectAllStreams();
    super.dispose();
  }
}

/// 各アカウント 1 本の SSE 接続を表す内部状態オブジェクト。
/// timeline_view 側 `_StreamConnection` と同じ役割。
class _NotifStreamConnection {
  final String accountId;
  final String instanceUrl;
  final String accessToken;
  StreamSubscription<NotificationItem>? subscription;
  Timer? reconnectTimer;

  /// 進行中の接続確立処理。重複起動を `_connectStream` で合流させるための
  /// in-flight ガード (timeline_view 側 `_StreamConnection` と同じ)。
  Future<void>? connectInFlight;
  int attempt = 0;
  bool isConnected = false;
  bool everConnected = false;
  DateTime? lastEventAt;

  _NotifStreamConnection({
    required this.accountId,
    required this.instanceUrl,
    required this.accessToken,
  });
}

/// `WidgetsBindingObserver` の最小実装。NotificationsNotifier 本体を
/// 直接 observer にすると StateNotifier と Observer の責務が混じるので、
/// resumed コールバックだけ拾う薄い delegate を持たせる。
class _NotifLifecycleObserver extends WidgetsBindingObserver {
  _NotifLifecycleObserver({required this.onResumed});
  final VoidCallback onResumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) onResumed();
  }
}

final notificationsProvider = StateNotifierProvider<NotificationsNotifier,
    AsyncValue<List<NotificationGroup>>>(
  (ref) => NotificationsNotifier(ref),
);

/// 未読通知数を提供するプロバイダー
final unreadNotificationCountProvider = Provider<int>((ref) {
  // notificationsProviderの変更を監視
  ref.watch(notificationsProvider);
  
  final notifier = ref.read(notificationsProvider.notifier);
  return notifier.unreadCount;
});
