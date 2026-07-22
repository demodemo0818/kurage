// lib/pages/notifications_page.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../models/account.dart';
import '../models/notification_item.dart';
import '../models/notification_group.dart';
import '../models/auth_account.dart';
import '../providers/auth_provider.dart';
import '../providers/notifications_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/tab_state_provider.dart';
import '../utils/time_formatter.dart';
import '../utils/html_parser.dart';
import '../utils/open_profile.dart';
import '../widgets/post_tile.dart';
import '../widgets/timeline_post_decoration.dart';
import '../widgets/user_avatar.dart';
import 'collection_detail_page.dart';

class NotificationsPage extends ConsumerStatefulWidget {
  /// Deck (ワイド) のポップアップで開かれた時に渡される戻る (←) コールバック。
  /// null (ナロー/通常) のときは AppBar に戻る矢印を出さない。
  final VoidCallback? onDeckBack;

  /// カラム (Deck のホーム常設カラム / モバイルのタブ) に埋め込むモード。
  /// true のときは Scaffold/AppBar を持たず、上部のコンパクトバー
  /// (アカウント選択 + フィルタ) + 通知リストだけを返す。
  final bool embedded;

  /// embedded カラムがいま実際に画面に見えているか。
  /// - Deck (デスクトップ) は全カラム横並びなので常に true。
  /// - モバイルはタブなので「自分のタブがアクティブか」を渡す。
  ///
  /// true かつホームタブ表示中の間は、通知タブを開いているのと同様に扱い、
  /// 新着で未読バッジを増やさず表示開始時に既読化する ([notificationsProvider]
  /// の addNotificationViewer / removeNotificationViewer)。これがないと、
  /// 通知カラムで見えている (= 既読のはず) のにナビに未読バッジが付いてしまう。
  final bool isActive;

  const NotificationsPage({
    super.key,
    this.onDeckBack,
    this.embedded = false,
    this.isActive = true,
  });

  @override
  ConsumerState<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends ConsumerState<NotificationsPage> {
  late final Map<NotificationType, bool> _filters;
  bool _loadingMore = false;
  final Set<String> _selectedAccountIds = {};
  bool _hasInitialized = false;

  /// dispose / post-frame コールバックから `ref` を使うと、Riverpod 側の
  /// element 破棄が先行したタイミングで 'Cannot use "ref" after the widget
  /// was disposed' で落ちる (Crashlytics d2deba6 / f963269)。initState で
  /// notifier を捕まえておき、ref を介さず直接呼ぶ。
  late final NotificationsNotifier _notificationsNotifier;

  /// `_syncViewer` が ref.read(tabStateProvider) しなくて済むよう、build の
  /// ref.listen / initState で最新のタブ index をミラーしておく。
  int _currentTab = 0;

  @override
  void initState() {
    super.initState();
    _notificationsNotifier = ref.read(notificationsProvider.notifier);
    _currentTab = ref.read(tabStateProvider);
    // 保存されたフィルター設定を復元
    final savedFilters = NotificationsNotifier.getSavedFilters();
    if (savedFilters.isNotEmpty) {
      _filters = {};
      for (var t in NotificationType.values) {
        _filters[t] = savedFilters[t.toString()] ?? true;
      }
    } else {
      _filters = {for (var t in NotificationType.values) t: true};
    }
    
    // 保存されたアカウント選択を復元
    final savedAccountIds = NotificationsNotifier.getSavedSelectedAccountIds();
    if (savedAccountIds.isNotEmpty) {
      _selectedAccountIds.addAll(savedAccountIds);
    }
    
    // 通知ページ (タブ) を開いたら未読をクリア。
    // embedded カラムは「表示中ビューア」の登録で既読制御するので別経路。
    if (!widget.embedded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _notificationsNotifier.markAsRead();
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncViewer());
    }
  }

  /// embedded カラムが「いま見えているか」を [notificationsProvider] に登録/解除
  /// する。可視 = 自分がアクティブ (isActive) かつ ホームタブ (tabState 0) 表示中。
  bool _viewerRegistered = false;

  void _syncViewer() {
    // ref は使わない (キャッシュ済み notifier + _currentTab のみ)。post-frame
    // コールバック経由で widget 破棄後に呼ばれても安全に登録解除だけ行う。
    if (!widget.embedded) return;
    final visible = mounted && widget.isActive && _currentTab == 0;
    if (visible && !_viewerRegistered) {
      _viewerRegistered = true;
      _notificationsNotifier.addNotificationViewer();
    } else if (!visible && _viewerRegistered) {
      _viewerRegistered = false;
      _notificationsNotifier.removeNotificationViewer();
    }
  }

  @override
  void didUpdateWidget(NotificationsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // モバイルのタブ切替で isActive が変わったら可視状態を同期 (build 中の
    // provider 変更を避けるため次フレームで)。
    if (widget.embedded && oldWidget.isActive != widget.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncViewer());
    }
  }

  @override
  void dispose() {
    if (_viewerRegistered) {
      _viewerRegistered = false;
      // ref.read はここでは使えないことがある (クラス冒頭のコメント参照)。
      _notificationsNotifier.removeNotificationViewer();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // RootPage が IndexedStack で全ページを常駐させているので、initState は
    // アプリ起動時に 1 回しか走らない。タブ切替で通知タブが選ばれる度に
    // 未読をクリアするよう、tabStateProvider を listen する。
    if (!widget.embedded) {
      ref.listen<int>(tabStateProvider, (prev, next) {
        // 通知タブ (index 1) が新たに選ばれた瞬間に未読クリア。
        // 取り逃しの自動取り込みは NotificationsNotifier 側の SSE 再接続
        // 経路 (`_recoverFromStreamReconnect`) と watchdog (5 分無音検出 →
        // 強制再接続 → reconnect refresh) と app resume 時の force reconnect
        // で面倒を見ているので、ここでは refresh を別途投げない。
        if (next == 1 && prev != 1) {
          ref.read(notificationsProvider.notifier).markAsRead();
        }
      });
    } else {
      // embedded カラム: ホームタブから離れる/戻る (= 裏のホームを覆う Deck
      // ポップアップや別ナビへの切替) で可視状態が変わるので同期する。
      ref.listen<int>(tabStateProvider, (_, next) {
        _currentTab = next;
        _syncViewer();
      });
    }

    final asyncList = ref.watch(notificationsProvider);
    // build で実際に使うフィールドだけ record select。Settings 全体 watch だと
    // 無関係な設定変更 (appLock 系等) でも通知一覧全体が rebuild される。
    final settings = ref.watch(settingsProvider.select((s) => (
      fontSize: s.fontSize,
      lineHeight: s.lineHeight,
      emojiScale: s.emojiScale,
      emojiScaleInDisplayName: s.emojiScaleInDisplayName,
      timelineLayout: s.timelineLayout,
    )));
    final authState = ref.watch(authProvider);
    final accounts = authState.accounts;

    // 初回アカウント選択
    if (!_hasInitialized && accounts.isNotEmpty) {
      _hasInitialized = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        setState(() {
          // 保存されたアカウント選択がない場合は全アカウントを選択
          if (_selectedAccountIds.isEmpty) {
            _selectedAccountIds.addAll(accounts.map((a) => a.id));
          } else {
            // 保存されたアカウントIDのうち、現在存在するものだけを保持
            _selectedAccountIds.removeWhere((id) => !accounts.any((a) => a.id == id));
            if (_selectedAccountIds.isEmpty) {
              _selectedAccountIds.addAll(accounts.map((a) => a.id));
            }
          }
        });
        _refreshNotifications();
      });
    }

    // テキスト＆絵文字サイズ
    final baseStyle = DefaultTextStyle.of(context).style.copyWith(
      fontSize: settings.fontSize,
      height: settings.lineHeight,
      color: Theme.of(context).textTheme.bodyMedium?.color,
    );
    final emojiSizeDisplayName = settings.fontSize * settings.emojiScaleInDisplayName;
    final emojiSizeContent = settings.fontSize * settings.emojiScale;

    // フィルタボタン (適用中フィルタ数バッジ付き)。AppBar / 埋め込みバー
    // どちらからも使うので変数化。
    final Widget filterAction = Stack(
      children: [
        IconButton(
          icon: const Icon(Icons.filter_list),
          onPressed: _showFilterDialog,
        ),
        // フィルターされているアイテム数を表示
        if (_getActiveFilterCount() < NotificationType.values.length)
          Positioned(
            right: 8,
            top: 8,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(10),
              ),
              constraints: const BoxConstraints(
                minWidth: 16,
                minHeight: 16,
              ),
              child: Text(
                '${_getActiveFilterCount()}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
      ],
    );

    final Widget body = asyncList.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text(context.l10n.genericError('$e'))),
      data: (items) {
        // フィルタ適用
        final filtered = items.where((n) => _filters[n.type]!).toList();
        if (filtered.isEmpty) {
          return Center(child: Text(context.l10n.notifFilterNoMatch));
        }
        return NotificationListener<ScrollNotification>(
          onNotification: (sn) {
            if (!_loadingMore &&
                sn.metrics.pixels >= sn.metrics.maxScrollExtent - 100) {
              setState(() => _loadingMore = true);
              ref
                  .read(notificationsProvider.notifier)
                  .loadMore()
                  .whenComplete(() => setState(() => _loadingMore = false));
            }
            return false;
          },
          child: RefreshIndicator(
            onRefresh: () => ref.read(notificationsProvider.notifier).refresh(),
            child: ListView.builder(
              itemCount: filtered.length + (_loadingMore ? 1 : 0),
              itemBuilder: (ctx, i) {
                if (i >= filtered.length) {
                  return const Padding(
                    padding: EdgeInsets.all(8),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final g = filtered[i];
                final layout = settings.timelineLayout;
                // 通知グループごとの安定キー。markAsRead / SSE / refresh で
                // リストの identity・並びが変わるたびに Element がインデックス
                // 位置で使い回されると、_PostActionBar 等の State が別の通知に
                // 付け替わる (リアクションマークが消えて見える)。groupKey は
                // アカウント内でのみ一意なのでマルチアカウントのマージリストでは
                // sourceAccountId と複合する。timeline_view の
                // ValueKey('post_...') の通知版。
                return Column(
                  key: ValueKey('ng_${g.sourceAccountId}_${g.groupKey}'),
                  children: [
                    wrapForTimelineLayout(
                      ctx,
                      _buildNotificationItem(
                        g,
                        baseStyle,
                        emojiSizeDisplayName,
                        emojiSizeContent,
                        accounts,
                      ),
                      layout,
                    ),
                    timelineSeparator(layout),
                  ],
                );
              },
            ),
          ),
        );
      },
    );

    // カラム埋め込みモード: Scaffold/AppBar を持たず、コンパクトな上部バー
    // (アカウント選択 + フィルタ) + リストだけを返す。ヘッダー (種別ラベルや
    // 戻る矢印) は親のカラムヘッダー / タブ側が担う。
    if (widget.embedded) {
      return Column(
        children: [
          SizedBox(
            height: 60,
            child: Row(
              children: [
                Expanded(child: _buildAccountSelector(accounts)),
                filterAction,
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: body),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: widget.onDeckBack == null
            ? null
            : BackButton(onPressed: widget.onDeckBack),
        title: Text(context.l10n.navNotifications),
        actions: [filterAction],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: _buildAccountSelector(accounts),
        ),
      ),
      body: body,
    );
  }

  Widget _buildNotificationItem(NotificationGroup g, TextStyle baseStyle,
      double emojiSizeDisplayName, double emojiSizeContent,
      List<AuthAccount> accounts) {
    final sourceAccount = accounts.firstWhere(
      (a) => a.id == g.sourceAccountId,
      orElse: () => accounts.isNotEmpty
          ? accounts.first
          : throw StateError('No accounts available'),
    );

    // 投稿系の通知（いいね、ブースト、リアクション、メンション、返信、投票）
    if (g.status != null && _hasPostContent(g.type)) {
      return Container(
        decoration: sourceAccount.accountColor != null
            ? BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: sourceAccount.accountColor!.withValues(alpha: 0.6),
                    width: 4,
                  ),
                ),
                color: sourceAccount.accountColor!.withValues(alpha: 0.05),
              )
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildNotificationHeader(
                g, baseStyle, emojiSizeDisplayName, sourceAccount),
            PostTile(
              status: g.status!,
              accountId: g.sourceAccountId,
            ),
          ],
        ),
      );
    } else {
      return Container(
        decoration: sourceAccount.accountColor != null
            ? BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: sourceAccount.accountColor!.withValues(alpha: 0.6),
                    width: 4,
                  ),
                ),
                color: sourceAccount.accountColor!.withValues(alpha: 0.05),
              )
            : null,
        child: _buildSimpleNotification(
            g, baseStyle, emojiSizeDisplayName, emojiSizeContent, sourceAccount),
      );
    }
  }

  /// 通知ヘッダー部分を作成
  Widget _buildNotificationHeader(NotificationGroup g, TextStyle baseStyle,
      double emojiSizeDisplayName, AuthAccount sourceAccount) {
    final settings = ref.watch(settingsProvider.select((s) => (
      fontSize: s.fontSize,
      avatarSize: s.avatarSize,
      disableCustomEmojiAnimationInDisplayName:
          s.disableCustomEmojiAnimationInDisplayName,
      useRelativeTime: s.useRelativeTime,
    )));
    final primary = g.primaryAccount;
    if (primary == null) return const SizedBox.shrink();

    final icon = _getNotificationIcon(g.type);
    final color = _getNotificationColor(g.type);
    final iconSize = settings.fontSize * 1.6;
    final avatarRadius = settings.avatarSize * 0.3;

    return Container(
      color: sourceAccount.accountColor?.withValues(alpha: 0.2),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: iconSize, color: color),
          const SizedBox(width: 8),
          if (g.isGroup)
            _buildAvatarStack(g, sourceAccount, avatarRadius)
          else
            GestureDetector(
              onTap: () => _navigateToProfile(primary, sourceAccount),
              child: UserAvatar(
                url: primary.avatarStatic,
                radius: avatarRadius,
              ),
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RichText(
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  text: TextSpan(
                    style: baseStyle.copyWith(fontWeight: FontWeight.bold),
                    children: _buildHeaderTextSpans(
                      g,
                      baseStyle,
                      emojiSizeDisplayName,
                      settings.disableCustomEmojiAnimationInDisplayName,
                    ),
                  ),
                ),
                if (g.isGroup) _buildSeeAllLink(g, baseStyle, sourceAccount),
              ],
            ),
          ),
          TimeText(
            dt: g.latestAt,
            useRelative: settings.useRelativeTime,
            style: TextStyle(
              fontSize: settings.fontSize,
              color: Colors.grey,
            ),
          ),
        ],
      ),
    );
  }

  /// グループの表示テキストを RichText 用 span に組み立てる。
  /// - 単体 (isGroup == false): 「`displayName` がアクションしました」
  /// - グループ (件数 > 1): 「`displayName` 他 N 人がアクションしました」
  ///   (公式 Android の `user_and_x_more_*` テンプレ準拠)
  List<InlineSpan> _buildHeaderTextSpans(
    NotificationGroup g,
    TextStyle baseStyle,
    double emojiSize,
    bool disableEmojiAnim,
  ) {
    final primary = g.primaryAccount;
    if (primary == null) return const [];

    final boldStyle = baseStyle.copyWith(fontWeight: FontWeight.bold);
    final normalStyle = baseStyle.copyWith(fontWeight: FontWeight.normal);
    final spans = <InlineSpan>[
      ...parseContentWithEmojis(
        contentHtml: primary.displayName,
        emojis: primary.emojis,
        baseStyle: boldStyle,
        linkColor: Colors.blue,
        emojiSize: emojiSize,
        disableEmojiAnimation: disableEmojiAnim,
        enableInlineLinks: false,
      ),
    ];

    if (g.isGroup) {
      final others = g.notificationsCount - 1;
      spans.add(TextSpan(
        text: context.l10n
            .notifGroupOthersSuffix(others, _getNotificationVerb(g.type)),
        style: normalStyle,
      ));
      // 「全員を見る」リンクはここには足さない。RichText の
      // maxLines: 2 + ellipsis に巻き込まれると Deck の狭いカラムで
      // 本文に押し出されて消えてしまうため、呼び出し側で独立した行
      // (_buildSeeAllLink) として描画する。
    } else {
      spans.add(TextSpan(
        text: ' ${_getNotificationLabel(g.type)}',
        style: normalStyle,
      ));
    }
    return spans;
  }

  /// グループ通知の「全員を見る」リンク。本文 RichText の 2 行 ellipsis に
  /// 巻き込まれると Deck の狭いカラムで押し出されて消えてしまうため、本文とは
  /// 別の独立した行の widget として描画する。タップで全 sample アカウントの
  /// BottomSheet ([_showAllAccountsSheet]) を開く。
  Widget _buildSeeAllLink(
    NotificationGroup g,
    TextStyle baseStyle,
    AuthAccount sourceAccount,
  ) {
    return GestureDetector(
      onTap: () => _showAllAccountsSheet(g, sourceAccount),
      child: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          context.l10n.notifSeeAll,
          style: baseStyle.copyWith(
            fontWeight: FontWeight.normal,
            color: Colors.blue,
            decoration: TextDecoration.underline,
            fontSize:
                baseStyle.fontSize != null ? baseStyle.fontSize! * 0.9 : 12,
          ),
        ),
      ),
    );
  }

  /// グループ用のアバター重ね表示。最大 3 件、`+N` バッジは出さない
  /// (テキスト側で「他 N 人」を出すので二重表記を避けるため)。
  Widget _buildAvatarStack(
    NotificationGroup g,
    AuthAccount sourceAccount,
    double radius,
  ) {
    final visible = g.sampleAccounts.take(3).toList();
    final stackWidth = radius * 2 + (visible.length - 1) * radius * 1.1;
    return SizedBox(
      width: stackWidth,
      height: radius * 2,
      child: Stack(
        children: [
          for (var i = 0; i < visible.length; i++)
            Positioned(
              left: i * radius * 1.1,
              child: GestureDetector(
                onTap: () => _navigateToProfile(visible[i], sourceAccount),
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      width: 1.5,
                    ),
                  ),
                  child: UserAvatar(
                    url: visible[i].avatarStatic,
                    radius: radius,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// グループの全 sample アカウント一覧 BottomSheet。各行タップで該当
  /// プロフィールへ。`sample_account_ids` は server 上限あり (Mastodon 仕様)
  /// だが、ここには取得できた範囲を全て出す。
  void _showAllAccountsSheet(NotificationGroup g, AuthAccount sourceAccount) {
    final settings = ref.read(settingsProvider);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    Icon(_getNotificationIcon(g.type),
                        color: _getNotificationColor(g.type)),
                    const SizedBox(width: 8),
                    Text(
                      context.l10n.notifSheetTitle(
                          _getNotificationVerb(g.type), g.notificationsCount),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: g.sampleAccounts.length,
                  itemBuilder: (_, i) {
                    final a = g.sampleAccounts[i];
                    return ListTile(
                      leading: GestureDetector(
                        onTap: () {
                          Navigator.pop(ctx);
                          _navigateToProfile(a, sourceAccount);
                        },
                        child: UserAvatar(
                          url: a.avatarStatic,
                          radius: settings.avatarSize * 0.4,
                        ),
                      ),
                      title: RichText(
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        text: TextSpan(
                          style: TextStyle(
                            fontSize: settings.fontSize,
                            color: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.color,
                            fontWeight: FontWeight.bold,
                          ),
                          children: parseContentWithEmojis(
                            contentHtml: a.displayName,
                            emojis: a.emojis,
                            baseStyle: TextStyle(
                              fontSize: settings.fontSize,
                              color: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.color,
                              fontWeight: FontWeight.bold,
                            ),
                            linkColor: Colors.blue,
                            emojiSize: settings.fontSize *
                                settings.emojiScaleInDisplayName,
                            disableEmojiAnimation:
                                settings.disableCustomEmojiAnimationInDisplayName,
                            enableInlineLinks: false,
                          ),
                        ),
                      ),
                      subtitle: Text('@${a.acct}'),
                      onTap: () {
                        Navigator.pop(ctx);
                        _navigateToProfile(a, sourceAccount);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// シンプルな通知（フォローなど）
  Widget _buildSimpleNotification(NotificationGroup g, TextStyle baseStyle,
      double emojiSizeDisplayName, double emojiSizeContent,
      AuthAccount sourceAccount) {
    final settings = ref.watch(settingsProvider.select((s) => (
      fontSize: s.fontSize,
      avatarSize: s.avatarSize,
      disableCustomEmojiAnimationInDisplayName:
          s.disableCustomEmojiAnimationInDisplayName,
      disableCustomEmojiAnimationInContent:
          s.disableCustomEmojiAnimationInContent,
      useRelativeTime: s.useRelativeTime,
    )));
    final primary = g.primaryAccount;
    if (primary == null) return const SizedBox.shrink();
    final avatarRadius = settings.avatarSize * 0.4;

    // コレクション系通知は行全体タップでコレクション詳細へ (collectionId が
    // 取れない間はプロフィールへフォールバック)。アバターの内側 GestureDetector
    // が優先されるので、アバタータップは従来どおりプロフィールに飛ぶ。
    final isCollection = g.type == NotificationType.addedToCollection ||
        g.type == NotificationType.collectionUpdate;

    final content = Container(
      color: sourceAccount.accountColor?.withValues(alpha: 0.2),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            _getNotificationIcon(g.type),
            size: settings.fontSize * 1.6,
            color: _getNotificationColor(g.type),
          ),
          const SizedBox(width: 8),
          if (g.isGroup)
            _buildAvatarStack(g, sourceAccount, avatarRadius)
          else
            GestureDetector(
              onTap: () => _navigateToProfile(primary, sourceAccount),
              child: UserAvatar(
                url: primary.avatarStatic,
                radius: avatarRadius,
              ),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RichText(
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  text: TextSpan(
                    style: baseStyle.copyWith(fontWeight: FontWeight.bold),
                    children: _buildHeaderTextSpans(
                      g,
                      baseStyle,
                      emojiSizeDisplayName,
                      settings.disableCustomEmojiAnimationInDisplayName,
                    ),
                  ),
                ),
                if (g.isGroup) _buildSeeAllLink(g, baseStyle, sourceAccount),
                if (g.status != null) ...[
                  const SizedBox(height: 4),
                  RichText(
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    text: TextSpan(
                      style: baseStyle.copyWith(color: Colors.grey[600]),
                      children: parseContentWithEmojis(
                        contentHtml: g.status!.content,
                        emojis: g.status!.emojis,
                        baseStyle: baseStyle.copyWith(color: Colors.grey[600]),
                        linkColor: Colors.blue,
                        emojiSize: emojiSizeContent,
                        disableEmojiAnimation:
                            settings.disableCustomEmojiAnimationInContent,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          TimeText(
            dt: g.latestAt,
            useRelative: settings.useRelativeTime,
            style: TextStyle(
              fontSize: settings.fontSize,
              color: Colors.grey,
            ),
          ),
        ],
      ),
    );

    if (isCollection) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _navigateToCollection(g, primary, sourceAccount),
        child: content,
      );
    }
    return content;
  }

  /// コレクション系通知のタップ遷移。collectionId が取れていればコレクション
  /// 詳細へ、無ければ通知主のプロフィールへフォールバックする。
  void _navigateToCollection(
      NotificationGroup g, Account primary, AuthAccount sourceAccount) {
    final collectionId = g.collectionId;
    if (collectionId == null) {
      _navigateToProfile(primary, sourceAccount);
      return;
    }
    openDeckPage(
      context,
      (onDeckBack) => CollectionDetailPage(
        user: sourceAccount,
        collectionId: collectionId,
        onDeckBack: onDeckBack,
      ),
    );
  }

  /// プロフィールページへ遷移。`sourceAccount` は通知を受信したアカウント
  /// (= プロフィール操作時の操作主体)。
  void _navigateToProfile(Account account, AuthAccount sourceAccount) {
    // アカウントのインスタンスURLを判定
    String? userInstanceUrl;
    if (account.acct.contains('@')) {
      // リモートユーザー: @username@instance.domain
      final parts = account.acct.split('@');
      if (parts.length >= 2) {
        userInstanceUrl = 'https://${parts.last}';
      }
    } else {
      // ローカルユーザー → 通知を受信したアカウントのインスタンス
      userInstanceUrl = sourceAccount.instanceUrl;
    }

    openProfile(
      context,
      user: sourceAccount, // 操作主体 = 通知を受け取ったアカウント
      targetAccountId: account.id, // 表示対象のアカウントID
      targetUsername: account.username, // 検索用ユーザー名
      targetInstanceUrl: userInstanceUrl, // ユーザーのインスタンスURL
    );
  }

  /// 投稿内容を持つ通知かどうか
  bool _hasPostContent(NotificationType type) {
    return [
      NotificationType.favourite,
      NotificationType.reblog,
      NotificationType.reaction,
      NotificationType.mention,
      NotificationType.reply,
      NotificationType.poll,
      NotificationType.quote,
    ].contains(type);
  }

  /// 通知タイプに応じたアイコン
  IconData _getNotificationIcon(NotificationType type) {
    switch (type) {
      case NotificationType.favourite:
        return Icons.star;
      case NotificationType.reblog:
        return Icons.repeat;
      case NotificationType.reaction:
        return Icons.emoji_emotions;
      case NotificationType.mention:
        return Icons.alternate_email;
      case NotificationType.reply:
        return Icons.reply;
      case NotificationType.follow:
        return Icons.person_add;
      case NotificationType.poll:
        return Icons.how_to_vote;
      case NotificationType.followRequest:
        return Icons.person_add_outlined;
      case NotificationType.status:
        return Icons.new_releases;
      case NotificationType.quote:
        return Icons.format_quote;
      case NotificationType.addedToCollection:
        return Icons.library_add;
      case NotificationType.collectionUpdate:
        return Icons.collections_bookmark;
      case NotificationType.unknown:
        return Icons.notifications;
    }
  }

  /// 通知タイプに応じた色
  Color _getNotificationColor(NotificationType type) {
    switch (type) {
      case NotificationType.favourite:
        return Colors.amber;
      case NotificationType.reblog:
        return Colors.green;
      case NotificationType.reaction:
        return Colors.orange;
      case NotificationType.mention:
        return Colors.blue;
      case NotificationType.reply:
        return Colors.blue;
      case NotificationType.follow:
        return Colors.purple;
      case NotificationType.poll:
        return Colors.cyan;
      case NotificationType.followRequest:
        return Colors.purple.shade300;
      case NotificationType.status:
        return Colors.indigo;
      case NotificationType.quote:
        return Colors.teal;
      case NotificationType.addedToCollection:
        return Colors.pink;
      case NotificationType.collectionUpdate:
        return Colors.brown;
      case NotificationType.unknown:
        return Colors.grey;
    }
  }

  /// グループ通知用の短い動詞句。「他 N 人が<...>」に続けて使う。
  /// 例: type=favourite → 「お気に入りに追加しました」(主語省略)
  String _getNotificationVerb(NotificationType type) {
    switch (type) {
      case NotificationType.favourite:
        return context.l10n.notifVerbFavourite;
      case NotificationType.reblog:
        return context.l10n.notifVerbReblog;
      case NotificationType.reaction:
        return context.l10n.notifVerbReaction;
      case NotificationType.follow:
        return context.l10n.notifVerbFollow;
      case NotificationType.followRequest:
        return context.l10n.notifVerbFollowRequest;
      case NotificationType.poll:
        return context.l10n.notifVerbPoll;
      case NotificationType.status:
        return context.l10n.notifVerbStatus;
      case NotificationType.quote:
        return context.l10n.notifVerbQuote;
      case NotificationType.addedToCollection:
        return context.l10n.notifVerbAddedToCollection;
      case NotificationType.collectionUpdate:
        return context.l10n.notifVerbCollectionUpdate;
      case NotificationType.mention:
      case NotificationType.reply:
      case NotificationType.unknown:
        return context.l10n.notifVerbGeneric;
    }
  }

  /// 通知タイプに応じたラベル
  String _getNotificationLabel(NotificationType type) {
    switch (type) {
      case NotificationType.favourite:
        return context.l10n.notifLabelFavourite;
      case NotificationType.reblog:
        return context.l10n.notifLabelReblog;
      case NotificationType.reaction:
        return context.l10n.notifLabelReaction;
      case NotificationType.mention:
        return context.l10n.notifLabelMention;
      case NotificationType.reply:
        return context.l10n.notifLabelReply;
      case NotificationType.follow:
        return context.l10n.notifLabelFollow;
      case NotificationType.poll:
        return context.l10n.notifLabelPoll;
      case NotificationType.followRequest:
        return context.l10n.notifLabelFollowRequest;
      case NotificationType.status:
        return context.l10n.notifLabelStatus;
      case NotificationType.quote:
        return context.l10n.notifLabelQuote;
      case NotificationType.addedToCollection:
        return context.l10n.notifLabelAddedToCollection;
      case NotificationType.collectionUpdate:
        return context.l10n.notifLabelCollectionUpdate;
      case NotificationType.unknown:
        return context.l10n.notifLabelUnknown;
    }
  }

  // フィルタダイアログ用ラベル
  String _filterLabel(NotificationType t) {
    switch (t) {
      case NotificationType.mention:      return context.l10n.notifTypeMention;
      case NotificationType.reply:        return context.l10n.notifTypeReply;
      case NotificationType.favourite:    return context.l10n.notifTypeFavourite;
      case NotificationType.reblog:       return context.l10n.notifTypeReblog;
      case NotificationType.follow:       return context.l10n.notifTypeFollow;
      case NotificationType.poll:         return context.l10n.notifTypePoll;
      case NotificationType.reaction:     return context.l10n.notifTypeReaction;
      case NotificationType.followRequest:
        return context.l10n.notifTypeFollowRequest;
      case NotificationType.status:       return context.l10n.notifTypeStatus;
      case NotificationType.quote:        return context.l10n.notifTypeQuote;
      case NotificationType.addedToCollection:
        return context.l10n.notifTypeAddedToCollection;
      case NotificationType.collectionUpdate:
        return context.l10n.notifTypeCollectionUpdate;
      case NotificationType.unknown:      return context.l10n.notifTypeOther;
    }
  }

  void _showFilterDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialog) {
            // 全て選択されているかチェック
            final allSelected = NotificationType.values.every((t) => _filters[t] == true);
            
            // ダークモードでも視認性を確保するため Material 3 の
            // colorScheme.primary を使う (Theme.of(context).primaryColor は
            // M2 由来でダーク時に暗い紫を返すことがあり背景に埋もれる)
            final accent = Theme.of(context).colorScheme.primary;

            // 広い画面 (Deck) では double.maxFinite だとダイアログが
            // ウィンドウ幅いっぱいまで横に広がってしまうので最大幅を制限する。
            // 狭い画面 (スマホ) では従来どおりフル幅にしてチェック項目に余裕を持たせる。
            final screenWidth = MediaQuery.of(context).size.width;
            final dialogContentWidth =
                screenWidth < 480 ? double.maxFinite : 400.0;

            return AlertDialog(
              title: Row(
                children: [
                  Icon(Icons.filter_list, color: accent),
                  const SizedBox(width: 8),
                  Text(context.l10n.notifFilterTitle),
                ],
              ),
              content: SizedBox(
                width: dialogContentWidth,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 全て選択/解除チェックボックス
                    Container(
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: CheckboxListTile(
                        title: Text(
                          context.l10n.notifFilterSelectAll,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: accent,
                          ),
                        ),
                        secondary: Icon(
                          allSelected ? Icons.select_all : Icons.deselect,
                          color: accent,
                        ),
                        value: allSelected,
                        onChanged: (v) {
                          final newValue = v ?? false;
                          setDialog(() {
                            for (var t in NotificationType.values) {
                              _filters[t] = newValue;
                            }
                          });
                          // 即座に画面に反映
                          setState(() {});
                          // フィルター設定を保存
                          _saveFilters();
                        },
                      ),
                    ),
                    const SizedBox(height: 16),
                    // 個別のフィルター項目をスクロール可能にする
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          children: NotificationType.values.map((t) {
                            return CheckboxListTile(
                              secondary: Icon(
                                _getNotificationIcon(t), 
                                color: _getNotificationColor(t),
                                size: 20,
                              ),
                              title: Text(_filterLabel(t)),
                              value: _filters[t],
                              onChanged: (v) {
                                setDialog(() => _filters[t] = v!);
                                // 即座に画面に反映
                                setState(() {});
                                // フィルター設定を保存
                                _saveFilters();
                              },
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(context.l10n.close),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// フィルター設定を保存
  void _saveFilters() {
    final filterMap = <String, bool>{};
    for (var entry in _filters.entries) {
      filterMap[entry.key.toString()] = entry.value;
    }
    NotificationsNotifier.saveFilters(filterMap);
  }

  /// アクティブなフィルターの数を取得
  int _getActiveFilterCount() {
    return _filters.values.where((isActive) => isActive).length;
  }

  Widget _buildAccountSelector(List<AuthAccount> accounts) {
    final isAvatarSquare =
        ref.watch(settingsProvider.select((s) => s.isAvatarSquare));
    return Container(
      height: 60,
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.1),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        itemCount: accounts.length,
        itemBuilder: (context, index) {
          final account = accounts[index];
          final isSelected = _selectedAccountIds.contains(account.id);

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: GestureDetector(
              onTap: () {
                setState(() {
                  if (isSelected) {
                    _selectedAccountIds.remove(account.id);
                  } else {
                    _selectedAccountIds.add(account.id);
                  }
                });
                // アカウント選択を永続化
                NotificationsNotifier.saveSelectedAccountIds(_selectedAccountIds.toList());
                _refreshNotifications();
              },
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      // 外観設定の四角アイコンに合わせて選択リング/影の
                      // 形状も切り替える。
                      shape: isAvatarSquare
                          ? BoxShape.rectangle
                          : BoxShape.circle,
                      borderRadius: isAvatarSquare
                          ? BorderRadius.circular(4)
                          : null,
                      border: isSelected
                          ? Border.all(
                              color: account.accountColor ?? Theme.of(context).primaryColor,
                              width: 3,
                            )
                          : null,
                      boxShadow: isSelected
                          ? [
                              BoxShadow(
                                color: (account.accountColor ?? Theme.of(context).primaryColor).withValues(alpha: 0.3),
                                blurRadius: 8,
                                spreadRadius: 2,
                              )
                            ]
                          : null,
                    ),
                    child: UserAvatar(
                      url: account.avatarUrl,
                      radius: 20,
                    ),
                  ),
                  if (isSelected)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: account.accountColor ?? Theme.of(context).primaryColor,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1),
                        ),
                        child: const Icon(
                          Icons.check,
                          color: Colors.white,
                          size: 8,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _refreshNotifications() {
    if (_selectedAccountIds.isEmpty) {
      ref.read(notificationsProvider.notifier).clearNotifications();
    } else {
      ref.read(notificationsProvider.notifier).updateSelectedAccounts(_selectedAccountIds.toList());
    }
  }

}