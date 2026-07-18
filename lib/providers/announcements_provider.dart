// lib/providers/announcements_provider.dart

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/announcement.dart';
import '../providers/auth_provider.dart';
import '../services/mastodon_api.dart';

/// サーバからのお知らせ (`/api/v1/announcements`) をマルチアカウントで
/// 統合管理する Notifier。
///
/// - 各アカウントごとに並列に fetch して 1 本のリストにマージする
/// - 既読/未読は **サーバ側の `read` フィールド** をそのまま信頼する
///   (= dismiss API で書き込んだら次回 fetch で反映される)
/// - `unreadAnnouncementCountProvider` で BottomNav バッジ用の件数を公開
class AnnouncementsNotifier
    extends StateNotifier<AsyncValue<List<Announcement>>> {
  AnnouncementsNotifier(this._ref) : super(const AsyncValue.loading()) {
    WidgetsBinding.instance.addObserver(_lifecycleObserver);
    refresh();
  }

  final Ref _ref;
  bool _disposed = false;
  bool _refreshing = false;

  // resume で再 fetch する。お知らせは SSE 通知が無いので、アプリ復帰時に
  // 取り直さないと新着があるか分からない。
  late final _AnnouncementsLifecycleObserver _lifecycleObserver =
      _AnnouncementsLifecycleObserver(onResumed: refresh);

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(_lifecycleObserver);
    super.dispose();
  }

  /// 全アカウントぶんを並列 fetch してマージ。デバウンスして二重実行を防ぐ。
  Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final accounts = _ref.read(authProvider).accounts;
      if (accounts.isEmpty) {
        if (!_disposed) state = const AsyncValue.data([]);
        return;
      }
      final merged = <Announcement>[];
      final futures = accounts.map((acct) async {
        try {
          final list = await fetchAnnouncements(
            instanceUrl: acct.instanceUrl,
            accessToken: acct.accessToken,
          );
          for (final a in list) {
            a.sourceAccountId = acct.id;
          }
          return list;
        } catch (_) {
          // 個別アカウント失敗は黙って空リスト扱い。他アカウントの
          // お知らせを潰さない (= 1 サーバが落ちても全部消えるのを避ける)。
          return <Announcement>[];
        }
      }).toList();
      final results = await Future.wait(futures);
      for (final r in results) {
        merged.addAll(r);
      }
      // 新しいものが上。startsAt / endsAt は filter には使わない
      // (サーバが返した時点で表示すべきものだけ返ってくる)。
      merged.sort((a, b) => b.publishedAt.compareTo(a.publishedAt));
      if (!_disposed) state = AsyncValue.data(merged);
    } catch (e, st) {
      if (!_disposed) state = AsyncValue.error(e, st);
    } finally {
      _refreshing = false;
    }
  }

  /// 既読化。サーバに dismiss を投げ、ローカル state も即座に
  /// `read: true` の新インスタンスへ差し替える (Announcement は immutable
  /// にしているので新規生成)。
  Future<void> dismiss(Announcement target) async {
    final accountId = target.sourceAccountId;
    if (accountId == null) return;
    final auth = _ref.read(authProvider);
    final acct = auth.accounts.where((a) => a.id == accountId).firstOrNull;
    if (acct == null) return;
    try {
      await dismissAnnouncement(
        instanceUrl: acct.instanceUrl,
        accessToken: acct.accessToken,
        announcementId: target.id,
      );
    } catch (_) {
      // 失敗時はサイレント。次の refresh で再同期される。
      rethrow;
    }
    _replace(target, (a) => _copyWithRead(a, true));
  }

  /// リアクション追加。楽観的に local state を先に更新し、失敗したら
  /// rollback する。
  Future<void> addReaction(Announcement target, String name) async {
    final accountId = target.sourceAccountId;
    if (accountId == null) return;
    final auth = _ref.read(authProvider);
    final acct = auth.accounts.where((a) => a.id == accountId).firstOrNull;
    if (acct == null) return;

    final original = target;
    _replace(target, (a) => _withReactionToggled(a, name, true));
    try {
      await addAnnouncementReaction(
        instanceUrl: acct.instanceUrl,
        accessToken: acct.accessToken,
        announcementId: target.id,
        name: name,
      );
    } catch (e) {
      _replace(original, (_) => original); // rollback
      rethrow;
    }
  }

  /// リアクション削除。同じく optimistic update。
  Future<void> removeReaction(Announcement target, String name) async {
    final accountId = target.sourceAccountId;
    if (accountId == null) return;
    final auth = _ref.read(authProvider);
    final acct = auth.accounts.where((a) => a.id == accountId).firstOrNull;
    if (acct == null) return;

    final original = target;
    _replace(target, (a) => _withReactionToggled(a, name, false));
    try {
      await removeAnnouncementReaction(
        instanceUrl: acct.instanceUrl,
        accessToken: acct.accessToken,
        announcementId: target.id,
        name: name,
      );
    } catch (e) {
      _replace(original, (_) => original); // rollback
      rethrow;
    }
  }

  // ----- 内部ユーティリティ -----

  /// state のリスト中で `(sourceAccountId, id)` が一致するエントリを
  /// `transform` で差し替えて新しい state を組む。Announcement 自体は
  /// final フィールドだけなので、置き換え用の new instance を作るための
  /// ヘルパー (_copyWithRead / _withReactionToggled) も用意。
  void _replace(
    Announcement target,
    Announcement Function(Announcement existing) transform,
  ) {
    final current = state.value;
    if (current == null) return;
    final next = current.map((a) {
      if (a.sourceAccountId == target.sourceAccountId && a.id == target.id) {
        return transform(a);
      }
      return a;
    }).toList();
    if (!_disposed) state = AsyncValue.data(next);
  }

  Announcement _copyWithRead(Announcement a, bool read) {
    final clone = Announcement(
      id: a.id,
      content: a.content,
      startsAt: a.startsAt,
      endsAt: a.endsAt,
      publishedAt: a.publishedAt,
      updatedAt: a.updatedAt,
      read: read,
      emojis: a.emojis,
      reactions: a.reactions,
      sourceAccountId: a.sourceAccountId,
    );
    return clone;
  }

  Announcement _withReactionToggled(
    Announcement a,
    String name,
    bool meNext,
  ) {
    final newReactions = <AnnouncementReaction>[];
    var found = false;
    for (final r in a.reactions) {
      if (r.name == name) {
        found = true;
        final nextCount = meNext
            ? (r.me ? r.count : r.count + 1)
            : (r.me ? (r.count - 1).clamp(0, 1 << 30) : r.count);
        if (nextCount == 0 && !meNext) {
          // 自分が外して残数 0 ならエントリごと削除
          continue;
        }
        newReactions.add(AnnouncementReaction(
          name: r.name,
          count: nextCount,
          me: meNext,
          url: r.url,
          staticUrl: r.staticUrl,
        ));
      } else {
        newReactions.add(r);
      }
    }
    if (!found && meNext) {
      // 新しいリアクション追加。カスタム絵文字 URL は Announcement の
      // emojis から見つけられたら反映。
      final customEmoji =
          a.emojis.where((e) => e.shortcode == name).firstOrNull;
      newReactions.add(AnnouncementReaction(
        name: name,
        count: 1,
        me: true,
        url: customEmoji?.url,
        staticUrl: customEmoji?.staticUrl,
      ));
    }
    return Announcement(
      id: a.id,
      content: a.content,
      startsAt: a.startsAt,
      endsAt: a.endsAt,
      publishedAt: a.publishedAt,
      updatedAt: a.updatedAt,
      read: a.read,
      emojis: a.emojis,
      reactions: newReactions,
      sourceAccountId: a.sourceAccountId,
    );
  }
}

/// 小さな WidgetsBindingObserver delegate。
class _AnnouncementsLifecycleObserver with WidgetsBindingObserver {
  _AnnouncementsLifecycleObserver({required this.onResumed});
  final VoidCallback onResumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      onResumed();
    }
  }
}

final announcementsProvider = StateNotifierProvider<AnnouncementsNotifier,
    AsyncValue<List<Announcement>>>((ref) {
  return AnnouncementsNotifier(ref);
});

/// 「いま開いているカラム」のアカウント ID 集合。
///   - 非 null: そのアカウント ID 群のお知らせだけにフィルタする
///   - null:   フィルタ無し (全アカウントのお知らせ)
///
/// 単一カラム表示 (モバイル) では現在のタブのカラムのアカウントを、
/// マルチカラム同時表示 (デスクトップ) では全カラムのアカウントを和集合で
/// 入れる。MainPage 側で TabController の listener / 初期化時 / カラム変化時
/// に更新する。アプリ起動直後の MainPage 未初期化時は null のまま全件表示。
final activeColumnAccountIdsProvider = StateProvider<Set<String>?>((ref) {
  return null;
});

/// `activeColumnAccountIdsProvider` でフィルタ済みのお知らせ。
/// 一覧ページもバッジ件数もこちらを参照する。
final filteredAnnouncementsProvider = Provider<List<Announcement>>((ref) {
  final all = ref.watch(announcementsProvider).value ?? const [];
  final filter = ref.watch(activeColumnAccountIdsProvider);
  if (filter == null || filter.isEmpty) return all;
  return all
      .where((a) =>
          a.sourceAccountId != null && filter.contains(a.sourceAccountId))
      .toList();
});

/// 未読お知らせの件数 (フィルタ適用後)。BottomNav バッジ等で使う。
final unreadAnnouncementCountProvider = Provider<int>((ref) {
  final filtered = ref.watch(filteredAnnouncementsProvider);
  return filtered.where((a) => !a.read).length;
});
