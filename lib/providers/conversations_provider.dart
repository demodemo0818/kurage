// lib/providers/conversations_provider.dart

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/conversation.dart';
import '../providers/auth_provider.dart';
import '../services/mastodon_api.dart' as api;

class ConversationsNotifier
    extends StateNotifier<AsyncValue<List<Conversation>>> {
  ConversationsNotifier(this._ref) : super(const AsyncValue.loading()) {
    _init();
  }

  final Ref _ref;

  late final String instanceUrl;
  late final String accessToken;

  final List<String> _selectedAccountIds = [];
  static List<String> _savedSelectedAccountIds = [];

  /// アカウント選択の世代カウンタ。`_init` / `updateSelectedAccounts` /
  /// `clearConversations` を呼ぶたびに更新し、非同期フェッチの完了時に
  /// 「自分の世代がまだ最新か」を確認する。DM ページはアカウント選択を
  /// 全解除しても `updateSelectedAccounts([])` を呼ぶため、選択 ON→OFF の
  /// 素早い 2 連続タップで、古いフェッチが後から `state` を上書きして
  /// 「未選択なのに DM が出る」状態になるのを防ぐ
  /// (notifications_provider の同名対策と同じ。eb98c3a / 62cb595 参照)。
  int _selectionRequestId = 0;

  /// ユーザーが明示的にアカウント選択を全解除した状態か。
  /// `refresh()` / `loadMore()` には選択が空のときの単一アカウント
  /// フォールバック分岐があり、全解除直後にこれらが走ると stale な
  /// `instanceUrl` / `_maxId` で「未選択なのに DM が復活する」ため、
  /// このフラグが true の間はフォールバックを止める。
  bool _selectionCleared = false;

  // キャッシュ用
  static final Map<String, List<Conversation>> _cachedConversations = {};
  static final Map<String, DateTime> _lastFetchTime = {};

  // ページング用
  String? _maxId;
  final Map<String, String> _accountMaxIds = {}; // アカウントごとのmaxId
  bool _loadingMore = false;

  Future<void> _init() async {
    // updateSelectedAccounts と同じ世代ガード。このフォールバックフェッチは
    // 起動直後に飛ぶため、完了前にユーザーがアカウント選択を操作 (特に素早い
    // ON→OFF の全解除) すると、ガード無しでは古い結果が後から state を
    // 上書きし「未選択なのに DM が表示される」状態になる。
    final reqId = ++_selectionRequestId;
    try {
      final accounts = _ref.read(authProvider).accounts;
      if (accounts.isEmpty) {
        state = const AsyncValue.data([]);
        return;
      }
      // `current` 概念廃止に伴い、初期は最初のアカウントを使う。ユーザーが
      // DM ページでアカウントを選択すると `updateSelectedAccounts` で上書き。
      final account = accounts.first;

      instanceUrl = account.instanceUrl;
      accessToken = account.accessToken;

      // 初回 20 件取得
      final initial = await api.fetchConversations(
        instanceUrl: instanceUrl,
        accessToken: accessToken,
        limit: 20,
      );
      if (reqId != _selectionRequestId) return;
      state = AsyncValue.data(initial);
      if (initial.isNotEmpty) _maxId = initial.last.id;

    } catch (e, st) {
      if (reqId != _selectionRequestId) return;
      state = AsyncValue.error(e, st);
    }
  }

  /// 無限スクロールで過去の会話を取得
  Future<void> loadMore() async {
    if (_loadingMore) return;
    // 全解除中は「選択が空 = 単一アカウントモード」分岐に入れない
    // (stale な _maxId / instanceUrl で未選択なのに DM が復活するため)。
    if (_selectionCleared) return;
    _loadingMore = true;
    try {
      if (_selectedAccountIds.isEmpty) {
        // 単一アカウントの場合
        if (_maxId == null) return;
        final older = await api.fetchConversations(
          instanceUrl: instanceUrl,
          accessToken: accessToken,
          limit: 20,
          maxId: _maxId!,
        );
        if (older.isNotEmpty) {
          final current = state.value ?? [];
          final currentIds = current.map((c) => c.id).toSet();
          final deduped = older.where((c) => !currentIds.contains(c.id));
          state = AsyncValue.data([...current, ...deduped]);
          _maxId = older.last.id;
        }
      } else {
        // 複数アカウントの場合
        final authState = _ref.read(authProvider);
        final accounts = authState.accounts.where((a) => _selectedAccountIds.contains(a.id)).toList();
        
        var allOlderConversations = <Conversation>[];
        
        for (final account in accounts) {
          final accountMaxId = _accountMaxIds[account.id];
          if (accountMaxId == null) continue;
          
          try {
            final older = await api.fetchConversations(
              instanceUrl: account.instanceUrl,
              accessToken: account.accessToken,
              limit: 20,
              maxId: accountMaxId,
            );
            
            for (var conversation in older) {
              conversation.sourceAccountId = account.id;
            }
            
            if (older.isNotEmpty) {
              _accountMaxIds[account.id] = older.last.id;
            }
            
            allOlderConversations.addAll(older);
          } catch (e) {
            // 個別アカウントのエラーは無視
          }
        }
        
        if (allOlderConversations.isNotEmpty) {
          final current = state.value ?? [];
          final currentIds = current.map((c) => c.id).toSet();
          final deduped =
              allOlderConversations.where((c) => !currentIds.contains(c.id));
          
          // 時系列順にソート（最新メッセージ順）
          final sortedOlder = deduped.toList()..sort((a, b) {
            final aTime = a.lastMessageTime;
            final bTime = b.lastMessageTime;
            if (aTime == null && bTime == null) return 0;
            if (aTime == null) return 1;
            if (bTime == null) return -1;
            return bTime.compareTo(aTime);
          });
          
          final combined = [...current, ...sortedOlder];
          combined.sort((a, b) {
            final aTime = a.lastMessageTime;
            final bTime = b.lastMessageTime;
            if (aTime == null && bTime == null) return 0;
            if (aTime == null) return 1;
            if (bTime == null) return -1;
            return bTime.compareTo(aTime);
          });
          
          state = AsyncValue.data(combined);
        }
      }
    } catch (_) {
      // エラーは無視
    } finally {
      _loadingMore = false;
    }
  }

  /// Pull-to-refresh で差分取得
  Future<void> refresh() async {
    // 全解除中は何も取得しない。これがないと pull-to-refresh や Deck の
    // 更新ボタンで accounts.first へフォールバックして未選択なのに DM が
    // 復活する。
    if (_selectionCleared) return;
    final current = state.value ?? [];
    final sinceId = current.isNotEmpty ? current.first.id : null;

    try {
      if (_selectedAccountIds.isEmpty) {
        // 単一アカウントの場合
        final newer = await api.fetchConversations(
          instanceUrl: instanceUrl,
          accessToken: accessToken,
          limit: 20,
          sinceId: sinceId,
        );
        if (newer.isNotEmpty) {
          // 重複を排除
          final currentIds = current.map((c) => c.id).toSet();
          final deduped =
              newer.where((c) => !currentIds.contains(c.id)).toList();

          final combined = [...deduped, ...current];
          combined.sort((a, b) {
            final aTime = a.lastMessageTime;
            final bTime = b.lastMessageTime;
            if (aTime == null && bTime == null) return 0;
            if (aTime == null) return 1;
            if (bTime == null) return -1;
            return bTime.compareTo(aTime);
          });
          state = AsyncValue.data(combined);
          _updateCache(combined);
        }
      } else {
        // 複数アカウントの場合
        final authState = _ref.read(authProvider);
        final accounts = authState.accounts.where((a) => _selectedAccountIds.contains(a.id)).toList();
        
        List<Conversation> allNewerConversations = [];
        
        for (final account in accounts) {
          try {
            final newer = await api.fetchConversations(
              instanceUrl: account.instanceUrl,
              accessToken: account.accessToken,
              limit: 20,
              sinceId: sinceId,
            );
            
            for (var conversation in newer) {
              conversation.sourceAccountId = account.id;
            }
            
            allNewerConversations.addAll(newer);
          } catch (e) {
            // 個別アカウントのエラーは無視
          }
        }
        
        if (allNewerConversations.isNotEmpty) {
          // 重複を排除
          final currentIds = current.map((c) => c.id).toSet();
          final deduped = allNewerConversations
              .where((c) => !currentIds.contains(c.id))
              .toList();

          final combined = [...deduped, ...current];
          combined.sort((a, b) {
            final aTime = a.lastMessageTime;
            final bTime = b.lastMessageTime;
            if (aTime == null && bTime == null) return 0;
            if (aTime == null) return 1;
            if (bTime == null) return -1;
            return bTime.compareTo(aTime);
          });
          
          state = AsyncValue.data(combined);
          _updateCache(combined);
        }
      }
    } catch (e) {
      // エラーは無視
    }
  }

  Future<void> updateSelectedAccounts(List<String> accountIds) async {
    // この呼び出しを最新世代として記録。以降の await の後で世代が変わって
    // いたら (= より新しい選択操作が来ていたら) 自分の結果で state を
    // 上書きしないように早期 return する。
    final reqId = ++_selectionRequestId;
    _selectionCleared = accountIds.isEmpty;

    final previousAccountIds = Set.from(_selectedAccountIds);
    final newAccountIds = Set.from(accountIds);

    _selectedAccountIds.clear();
    _selectedAccountIds.addAll(accountIds);
    _savedSelectedAccountIds = List.from(accountIds);

    _accountMaxIds.clear();

    if (accountIds.isEmpty) {
      // 単一アカウント分岐のページング位置も無効化 (これを残すと全解除後の
      // loadMore が stale な位置から未選択のまま復活取得できてしまう)。
      _maxId = null;
      state = const AsyncValue.data([]);
      return;
    }
    
    // アカウント切り替えが発生した場合は関連キャッシュをクリア
    if (!previousAccountIds.containsAll(newAccountIds) || !newAccountIds.containsAll(previousAccountIds)) {
      debugPrint('Account selection changed, clearing related cache');
      _clearRelatedCache(accountIds);
    }
    
    // アカウント切り替え時は常にローディング状態から開始
    state = const AsyncValue.loading();
    
    // キャッシュキーを作成
    final cacheKey = accountIds.toList()..sort();
    final cacheKeyStr = cacheKey.join(',');
    
    try {
      final authState = _ref.read(authProvider);
      final accounts = authState.accounts.where((a) => accountIds.contains(a.id)).toList();
      
      List<Conversation> allConversations = [];
      
      for (final account in accounts) {
        try {
          final conversations = await api.fetchConversations(
            instanceUrl: account.instanceUrl,
            accessToken: account.accessToken,
            limit: 20,
          );
          // フェッチ中に選択が変わっていたら state 反映せず中断。
          if (reqId != _selectionRequestId) return;

          for (var conversation in conversations) {
            conversation.sourceAccountId = account.id;
          }

          if (conversations.isNotEmpty) {
            _accountMaxIds[account.id] = conversations.last.id;
          }

          allConversations.addAll(conversations);
        } catch (e) {
          // 個別アカウントのエラーは無視
        }
      }

      // ループ完了後にも世代を確認 (最後のフェッチ直後に選択が変わった場合)。
      if (reqId != _selectionRequestId) return;

      // アカウント切り替え時は常に新しいデータを表示
      // 時系列順でソート
      allConversations.sort((a, b) {
        final aTime = a.lastMessageTime;
        final bTime = b.lastMessageTime;
        if (aTime == null && bTime == null) return 0;
        if (aTime == null) return 1;
        if (bTime == null) return -1;
        return bTime.compareTo(aTime);
      });
      
      state = AsyncValue.data(allConversations);
      if (allConversations.isNotEmpty) _maxId = allConversations.last.id;
      
      // キャッシュに保存
      _cachedConversations[cacheKeyStr] = List.from(allConversations);
      _lastFetchTime[cacheKeyStr] = DateTime.now();
      
    } catch (e, st) {
      if (reqId != _selectionRequestId) return;
      state = AsyncValue.error(e, st);
    }
  }


  /// キャッシュを更新
  void _updateCache(List<Conversation> conversations) {
    if (_selectedAccountIds.isNotEmpty) {
      final cacheKey = _selectedAccountIds.toList()..sort();
      final cacheKeyStr = cacheKey.join(',');
      _cachedConversations[cacheKeyStr] = List.from(conversations);
      _lastFetchTime[cacheKeyStr] = DateTime.now();
    }
  }
  
  /// 関連するキャッシュをクリア
  void _clearRelatedCache(List<String> accountIds) {
    // 現在のアカウント組み合わせ以外のキャッシュを保持するため、
    // より積極的なクリアを実装
    final keysToRemove = <String>[];
    for (final key in _cachedConversations.keys) {
      final cachedAccountIds = key.split(',');
      // 新しいアカウント選択と異なるキャッシュをクリア
      if (!_listsEqual(cachedAccountIds, accountIds)) {
        keysToRemove.add(key);
      }
    }
    
    for (final key in keysToRemove) {
      _cachedConversations.remove(key);
      _lastFetchTime.remove(key);
    }
    
    debugPrint('Cleared ${keysToRemove.length} cache entries');
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
  
  Future<void> clearConversations() async {
    // 進行中の _init / updateSelectedAccounts のフェッチ完了が後から state を
    // 上書きしないよう、世代を進めて無効化する。
    _selectionRequestId++;
    _selectionCleared = true;
    _selectedAccountIds.clear();
    _savedSelectedAccountIds.clear();
    _accountMaxIds.clear();
    // 単一アカウント分岐のページング位置も無効化 (stale な位置から loadMore で
    // 未選択のまま復活取得できてしまうため)。
    _maxId = null;
    state = const AsyncValue.data([]);
  }

  /// 会話を既読にする
  Future<void> markAsRead(String conversationId) async {
    try {
      final conversations = state.value ?? [];
      final conversation = conversations.firstWhere((c) => c.id == conversationId);
      final sourceAccountId = conversation.sourceAccountId;
      
      if (sourceAccountId != null) {
        final authState = _ref.read(authProvider);
        final account = authState.accounts.firstWhere((a) => a.id == sourceAccountId);
        
        await api.markConversationRead(
          instanceUrl: account.instanceUrl,
          accessToken: account.accessToken,
          conversationId: conversationId,
        );
        
        // ローカル状態を更新
        final updatedConversations = conversations.map((c) {
          if (c.id == conversationId) {
            return c.copyWith(unread: false);
          }
          return c;
        }).toList();
        
        state = AsyncValue.data(updatedConversations);
        _updateCache(updatedConversations);
      }
    } catch (e) {
      // エラーは無視
    }
  }

  /// 会話を削除
  Future<void> removeConversation(String conversationId) async {
    try {
      final conversations = state.value ?? [];
      final conversation = conversations.firstWhere((c) => c.id == conversationId);
      final sourceAccountId = conversation.sourceAccountId;
      
      if (sourceAccountId != null) {
        final authState = _ref.read(authProvider);
        final account = authState.accounts.firstWhere((a) => a.id == sourceAccountId);
        
        await api.deleteConversation(
          instanceUrl: account.instanceUrl,
          accessToken: account.accessToken,
          conversationId: conversationId,
        );
        
        // ローカル状態を更新
        final updatedConversations = conversations.where((c) => c.id != conversationId).toList();
        
        state = AsyncValue.data(updatedConversations);
        _updateCache(updatedConversations);
      }
    } catch (e) {
      // エラーは無視
    }
  }

  static List<String> getSavedSelectedAccountIds() => _savedSelectedAccountIds;

}

final conversationsProvider =
    StateNotifierProvider<ConversationsNotifier, AsyncValue<List<Conversation>>>(
  (ref) => ConversationsNotifier(ref),
);