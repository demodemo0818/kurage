// lib/pages/main_page.dart

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../providers/announcements_provider.dart';
import '../providers/column_provider.dart';
import '../providers/deck_column_settings_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/notifications_provider.dart';
import '../providers/settings_provider.dart';
import '../services/mastodon_api.dart';
import '../utils/breakpoints.dart';
import 'account_settings_page.dart';
import 'announcements_page.dart';
import 'column_settings_page.dart';
import 'notifications_page.dart';
import 'post_page.dart';
import '../widgets/column_header.dart';
import '../widgets/timeline_view.dart';
import '../widgets/user_avatar.dart';

/// アクティブなタイムラインカラムを「j/k で 1 件送り」する関数を公開する。
/// MainPage が現在アクティブなカラムに対応するクロージャを登録し、RootPage の
/// グローバルキーボードショートカット (Web) がこれを読んで呼ぶ。カラムや
/// アクティブタブの参照を RootPage まで引き回さずに済ませるための橋渡し。
/// 値は `delta` (j = +1 / k = -1) を取る関数。未登録時は null。
final timelineJumpProvider =
    StateProvider<void Function(int delta)?>((ref) => null);

/// メインページ：複数カラムのタイムライン表示
class MainPage extends ConsumerStatefulWidget {
  const MainPage({super.key});

  @override
  ConsumerState<MainPage> createState() => _MainPageState();
}

class _MainPageState extends ConsumerState<MainPage>
    with TickerProviderStateMixin {
  TabController? _tabController;
  List<GlobalKey<ColumnTimelineViewState>> _keys = [];
  final Map<String, String> _listNames = {}; // listId -> listName のマップ

  /// デスクトップ (Deck) の横スクロール用コントローラ。横方向の Scrollbar を
  /// 常時表示するために、Scrollbar と SingleChildScrollView の両方に同じ
  /// controller を渡す必要がある (横スクロールは PrimaryScrollController に
  /// 乗らないため)。可変モードの溢れ時 / 固定モードの両方で使い回す
  /// (同時に 2 つの ScrollView へ attach されることはない)。
  final ScrollController _deckHScrollController = ScrollController();

  static const _timelineTypeIcons = {
    'home': Icons.home,
    'local': Icons.people,
    'federated': Icons.public,
    'favourites': Icons.star,
    'bookmarks': Icons.bookmark,
    'lists': Icons.list,
    'notifications': Icons.notifications,
  };

  static Map<String, String> get _timelineTypeLabels => {
        'home': l10n.timelineHome,
        'local': l10n.timelineLocal,
        'federated': l10n.timelineFederated,
        'favourites': l10n.timelineFavourites,
        'bookmarks': l10n.timelineBookmarks,
        'notifications': l10n.timelineNotifications,
      };

  Widget _buildAppBarTitle(List<dynamic> columns) {
    if (columns.isEmpty || _tabController == null) {
      return const Text('Timeline');
    }

    final currentIndex = _tabController!.index;
    if (currentIndex >= columns.length) {
      return const Text('Timeline');
    }

    final currentColumn = columns[currentIndex];
    final sources = currentColumn['sources'] as List;

    if (sources.isEmpty) {
      return const Text('Timeline');
    }

    final authState = ref.watch(authProvider);  // readからwatchに変更
    if (authState.accounts.isEmpty) {
      return const Text('Timeline');
    }

    // 全てのソースからアイコンを生成
    final List<Widget> children = [];
    final columnTitle = (currentColumn['title'] as String?) ?? '';

    for (int i = 0; i < sources.length; i++) {
      final source = sources[i];
      final accountId = source['accountId'] as String?;
      final timelineType = source['timelineType'] as String;

      if (accountId == null) continue;

      final account = authState.accounts.firstWhere(
        (a) => a.id == accountId,
        orElse: () => authState.accounts.first,
      );

      // リストの場合は非同期でリスト名を読み込む
      if (timelineType.startsWith('list_')) {
        final listId = timelineType.substring(5);
        _loadListName(listId, accountId);
      }

      // アカウントアイコン (外観設定の四角アイコンに追従)
      children.add(
        UserAvatar(
          url: account.avatarUrl,
          radius: 14,
        ),
      );

      // タイムライン種別テキスト。カラム名が付いている場合はカラム名を
      // 優先し、種別ラベルは省略してアバターだけ並べる (複数ソース時の
      // 横幅節約)。
      if (columnTitle.isEmpty) {
        children.add(
          Container(
            margin: const EdgeInsets.only(left: 4),
            child: Text(_getTimelineTypeLabel(timelineType)),
          ),
        );
      }

      // 次のソースとの間隔
      if (i < sources.length - 1) {
        children.add(SizedBox(width: columnTitle.isEmpty ? 8 : 4));
      }
    }

    // カラム名がある場合は追加
    if (columnTitle.isNotEmpty) {
      children.add(const SizedBox(width: 8));
      children.add(Text(columnTitle));
    }

    // ソースが多い / カラム名が長い場合でも右側の actions (お知らせベル・
    // ストリーミングボタン) に被らないよう、AppBar が title に与える幅の
    // 中に縮小して収める。
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }

  String _getTimelineTypeLabel(String type) {
    if (type.startsWith('list_')) {
      final listId = type.substring(5);
      return _listNames[listId] ?? l10n.timelineList;
    }
    return _timelineTypeLabels[type] ?? type;
  }

  Future<void> _loadListName(String listId, String accountId) async {
    // 既にリスト名がある場合はスキップ
    if (_listNames.containsKey(listId)) return;

    try {
      final authState = ref.read(authProvider);
      if (authState.accounts.isEmpty) return;
      
      final account = authState.accounts.firstWhere(
        (a) => a.id == accountId,
        orElse: () => authState.accounts.first,
      );

      final lists = await fetchLists(
        instanceUrl: account.instanceUrl,
        accessToken: account.accessToken,
      );

      // 取得したすべてのリストを保存
      bool hasUpdates = false;
      for (final list in lists) {
        if (!_listNames.containsKey(list.id)) {
          _listNames[list.id] = list.title;
          hasUpdates = true;
        }
      }

      // 新しいリスト名が追加された場合のみ状態更新
      if (mounted && hasUpdates) {
        setState(() {});
      }
    } catch (e) {
      debugPrint('リスト名取得エラー: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    // 初期化時にリスト名をプリロード。デフォルトカラムの自動生成は行わず、
    // カラム未設定時はオンボーディング画面でユーザーに明示的に作らせる。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _preloadListNames();
      // Web のグローバル j/k ショートカット用に、アクティブカラムを 1 件送り
      // するクロージャを登録。呼び出し時に最新のアクティブカラムを解決するので
      // タブ切替のたびに再登録する必要はない。
      if (kIsWeb && mounted) {
        ref.read(timelineJumpProvider.notifier).state = _jumpActiveColumn;
      }
    });
  }

  /// 現在アクティブなカラムを `delta` 件ぶんスクロールする (j = +1 / k = -1)。
  /// ナローはタブのカラム、デスクトップ (複数カラム同時表示) は左端カラムを
  /// 対象にする。
  void _jumpActiveColumn(int delta) {
    if (_keys.isEmpty || !mounted) return;
    final idx = isWideLayout(context) ? 0 : (_tabController?.index ?? 0);
    if (idx < 0 || idx >= _keys.length) return;
    _keys[idx].currentState?.scrollByItems(delta);
  }

  /// 初回起動時のオンボーディング画面 (「アカウントを追加」「カラムを追加」)。
  /// アイコン + タイトル + 説明文 + アクションボタンを縦に並べた素直なレイアウト。
  Widget _buildOnboardingScreen(
    BuildContext context, {
    required String appBarTitle,
    required IconData icon,
    required String title,
    required String description,
    required String buttonLabel,
    required VoidCallback onPressed,
  }) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(appBarTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 96, color: theme.colorScheme.primary),
                const SizedBox(height: 24),
                Text(
                  title,
                  style: theme.textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  description,
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                FilledButton.icon(
                  onPressed: onPressed,
                  icon: const Icon(Icons.arrow_forward),
                  label: Text(buttonLabel),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 14),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    // 登録した j/k クロージャがまだ自分のものなら外す。
    if (kIsWeb) {
      final notifier = ref.read(timelineJumpProvider.notifier);
      if (identical(notifier.state, _jumpActiveColumn)) {
        notifier.state = null;
      }
    }
    _tabController?.dispose();
    _deckHScrollController.dispose();
    super.dispose();
  }

  /// カラムヘッダの ⋮ メニュー「このカラムを削除」用。
  /// columnProvider から index 位置のカラムを除いた配列で save する。
  Future<void> _confirmDeleteColumn(int index) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.columnDeleteTitle),
        content: Text(ctx.l10n.columnDeleteConfirmMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final current = List<Map<String, dynamic>>.from(ref.read(columnProvider));
    if (index < 0 || index >= current.length) return;
    current.removeAt(index);
    await ref.read(columnProvider.notifier).save(current);
  }

  /// 全カラムのリスト名を事前に読み込み
  Future<void> _preloadListNames() async {
    final columns = ref.read(columnProvider);
    final authState = ref.read(authProvider);
    
    if (authState.accounts.isEmpty) return;

    for (final column in columns) {
      final sources = column['sources'] as List? ?? [];
      for (final source in sources) {
        final timelineType = source['timelineType'] as String? ?? '';
        final accountId = source['accountId'] as String?;
        
        if (timelineType.startsWith('list_') && accountId != null) {
          final listId = timelineType.substring(5);
          await _loadListName(listId, accountId);
        }
      }
    }
  }

  void _updateTabController(List<dynamic> columns) {
    // TabControllerが未初期化、またはカラム数が変更された場合
    if (_tabController == null || _tabController!.length != columns.length) {
      // 既存のカラム選択を可能な限り保持。なければ 0 にフォールバック。
      // 注: tabStateProvider はボトムナビ用なのでここでは参照しない
      final previousIndex = _tabController?.index ?? 0;
      _tabController?.dispose();

      final initialIndex = previousIndex < columns.length ? previousIndex : 0;
      _tabController = TabController(
        length: columns.length,
        vsync: this,
        initialIndex: initialIndex,
      );

      // キーも再生成
      _keys = List.generate(
        columns.length,
        (_) => GlobalKey<ColumnTimelineViewState>(),
      );

      // タブ (カラム) が切り替わったら AppBar タイトルを更新するため
      // setState する。
      // 注: `_tabController!.index` はカラムインデックス (0..カラム数-1) で、
      //     `tabStateProvider` (ボトムナビ index) とは別物。ここで
      //     setTabIndex を呼ぶと、カラム切替が通知タブ等への遷移として
      //     扱われてしまうので絶対に書き込まない。
      _tabController!.addListener(() {
        if (!_tabController!.indexIsChanging) {
          if (mounted) {
            setState(() {});
          }
        }
      });
    }
  }

  /// 「いま開いているカラム」のアカウント集合を
  /// [activeColumnAccountIdsProvider] に反映する。お知らせ一覧 / バッジが
  /// そのアカウント (= 出元インスタンス) ぶんだけにフィルタされる。
  ///
  /// モバイル: 現在のタブのカラムのアカウントのみ。
  /// デスクトップ: 全カラム同時表示なので全カラムの和集合。
  /// カラム未定 (空 / 範囲外): null = フィルタ無し (全件)。
  void _updateActiveColumnAccounts({
    required List<dynamic> columns,
    required bool isDesktop,
  }) {
    Set<String>? next;
    if (columns.isEmpty) {
      next = null;
    } else if (isDesktop) {
      final all = <String>{};
      for (final col in columns) {
        final sources = (col['sources'] as List?) ?? const [];
        for (final s in sources) {
          final id = (s as Map)['accountId'] as String?;
          if (id != null) all.add(id);
        }
      }
      next = all.isEmpty ? null : all;
    } else {
      final ctrl = _tabController;
      if (ctrl == null || ctrl.index >= columns.length) {
        next = null;
      } else {
        final col = columns[ctrl.index];
        final sources = (col['sources'] as List?) ?? const [];
        final set = <String>{};
        for (final s in sources) {
          final id = (s as Map)['accountId'] as String?;
          if (id != null) set.add(id);
        }
        next = set.isEmpty ? null : set;
      }
    }

    // build 内から直接 Provider state を書き換えると assertion で死ぬので
    // postFrame に逃がす。差分なしのときは書き込まない (= リスナー fanout
    // を避ける) ため、現在値と比較する。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final current = ref.read(activeColumnAccountIdsProvider);
      if (!_setEqualsNullable(current, next)) {
        ref.read(activeColumnAccountIdsProvider.notifier).state = next;
      }
    });
  }

  bool _setEqualsNullable(Set<String>? a, Set<String>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (final e in a) {
      if (!b.contains(e)) return false;
    }
    return true;
  }

  /// ワイドレイアウトの 1 カラム分 (ヘッダ + タイムライン本体)。
  /// fill モード (Expanded) / スクロールモード (SizedBox 固定幅) のどちらからも
  /// 同じ中身を使うので共通化。幅は呼び出し側で与える。
  /// 固定幅モードの Deck。各カラムを `column['width']` (未設定は既定幅) で
  /// 並べ、左寄せ + 余白は右、はみ出せば横スクロールする。可変幅モードと違って
  /// 等分・中央寄せはしない。
  Widget _buildFixedWidthDeck(List<dynamic> columns) {
    return Scrollbar(
      controller: _deckHScrollController,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _deckHScrollController,
        scrollDirection: Axis.horizontal,
        physics: const ClampingScrollPhysics(),
        child: Row(
          // 左寄せ (Row は SingleChildScrollView 内で子の合計幅にフィットする
          // ので余りは自然と右側に出る)。縦は stretch でカラムを全高に伸ばす。
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: List.generate(
            columns.length,
            (i) => SizedBox(
              width: columnFixedWidth(columns[i] as Map<String, dynamic>),
              child: _buildDesktopColumn(i, columns),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopColumn(int i, List<dynamic> columns) {
    final column = columns[i] as Map<String, dynamic>;
    final isNotif = isNotificationColumn(column);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(
            color: Theme.of(context).dividerColor,
            width: 0.5,
          ),
        ),
      ),
      child: Column(
        children: [
          ColumnHeader(
            column: column,
            listNames: _listNames,
            // 通知カラムは TimelineView を持たないので、更新は通知 provider に
            // 直接投げる (スクロール先頭移動は埋め込みリスト側に任せて no-op)。
            onRefresh: isNotif
                ? () => ref.read(notificationsProvider.notifier).refresh()
                : () => _keys[i].currentState?.refresh(),
            onScrollToTop: () => _keys[i].currentState?.scrollToTop(),
            // ワイド (Deck) 専用パスなので、フルスクリーン push ではなく
            // ホーム上のポップアップで開く (他ページと統一)。
            onEdit: () =>
                ref.read(deckColumnSettingsProvider.notifier).open(),
            onDelete: () => _confirmDeleteColumn(i),
          ),
          Expanded(
            child: isNotif
                ? const NotificationsPage(embedded: true)
                : ColumnTimelineView(
                    key: _keys[i],
                    column: column,
                    isActive: true,
                  ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final columns = ref.watch(columnProvider);
    final authState = ref.watch(authProvider);

    // ===== オンボーディング =====
    // 初回起動時は「アカウント追加 → カラム設定」の順に誘導する。
    // 両ステップとも MainPage の AppBar 配下で完結させ、別タブを意識させない。

    // ステップ 1: アカウント未登録 → アカウント設定へ誘導
    if (authState.accounts.isEmpty) {
      return _buildOnboardingScreen(
        context,
        appBarTitle: context.l10n.welcomeTitle,
        icon: Icons.account_circle_outlined,
        title: context.l10n.welcomeAddAccountTitle,
        description: context.l10n.welcomeAddAccountMessage,
        buttonLabel: context.l10n.welcomeOpenAccountSettings,
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const AccountSettingsPage()),
          );
        },
      );
    }

    // ステップ 2: アカウント有 / カラム未設定 → カラム設定へ誘導
    if (columns.isEmpty) {
      return _buildOnboardingScreen(
        context,
        appBarTitle: context.l10n.welcomeColumnsTitle,
        icon: Icons.view_column_outlined,
        title: context.l10n.welcomeAddColumnTitle,
        description: context.l10n.welcomeAddColumnMessage,
        buttonLabel: context.l10n.welcomeOpenColumnSettings,
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ColumnSettingsPage()),
          );
        },
      );
    }

    // TabControllerを更新
    _updateTabController(columns);

    final isDesktop = isWideLayout(context);

    // 開いているカラムのアカウントを announcements の Provider に反映。
    // build 内から直接 ref.read(...).state = ... は禁止なので postFrame で。
    _updateActiveColumnAccounts(columns: columns, isDesktop: isDesktop);

    final streamingEnabled =
        ref.watch(settingsProvider.select((s) => s.streamingEnabled));

    // ===== ワイドレイアウト (TweetDeck 風) =====
    // AppBar 非表示 + 横スクロール + 各カラムにヘッダー。
    // ストリーミング / お知らせベル / 投稿 FAB は RootPage の NavigationRail
    // 側に移動しているので、ここでは扱わない。
    if (isDesktop) {
      final columnWidthMode =
          ref.watch(settingsProvider.select((s) => s.columnWidthMode));
      return Scaffold(
        body: SafeArea(
          child: columnWidthMode == ColumnWidthMode.fixed
              ? _buildFixedWidthDeck(columns)
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final available = constraints.maxWidth;
                    // 全カラムを固定幅で並べても画面に収まるなら、横スクロール
                    // せず利用可能幅を等分して fill する (1 カラムだけのときに
                    // 右側が空白になるのを防ぐ)。ただし 1 カラムあたり
                    // kColumnMaxWidth で頭打ちにして、巨大モニタで極端に間延び
                    // しないようにする。頭打ちで合計が画面より狭い場合は
                    // 中央寄せではなく左寄せ (Row は SingleChildScrollView 内で
                    // 子の合計幅にフィットするので余りは自然と右側に出る)。
                    final fits = columns.length * kColumnWidth <= available;
                    final each = fits
                        ? (available / columns.length)
                            .clamp(kColumnWidth, kColumnMaxWidth)
                        : kColumnWidth;
                    // 重要: fits の true/false で widget ツリーの「型」を変えない
                    // こと (変わるのは width / physics 等のプロパティのみ)。
                    // 型が変わると Element がマッチせず配下の全カラム State が
                    // 破棄され、投稿ペインの開閉 (幅 ±360px) で fits が反転する
                    // たびに通知カラムの全リロード + タイムラインのスクロール
                    // 位置喪失が起きる (実際に起きた回帰)。
                    return Scrollbar(
                      controller: _deckHScrollController,
                      thumbVisibility: !fits,
                      child: SingleChildScrollView(
                        controller: _deckHScrollController,
                        scrollDirection: Axis.horizontal,
                        physics: fits
                            ? const NeverScrollableScrollPhysics()
                            : const ClampingScrollPhysics(),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: List.generate(
                            columns.length,
                            (i) => SizedBox(
                              width: each,
                              child: _buildDesktopColumn(i, columns),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      );
    }

    // ===== モバイル (narrow) レイアウト (従来通り) =====
    return Scaffold(
      appBar: AppBar(
        title: _buildAppBarTitle(columns),
        actions: [
          // サーバからのお知らせ。未読数を small badge で重ねる。
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
                          color: Theme.of(context).colorScheme.error,
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
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const AnnouncementsPage(),
                  ),
                );
              },
            );
          }),
          IconButton(
            icon: Icon(
              streamingEnabled ? Icons.podcasts : Icons.podcasts_outlined,
              color: streamingEnabled
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            tooltip: context.l10n
                .streamingTooltip(streamingEnabled ? 'ON' : 'OFF'),
            onPressed: () {
              final next = !streamingEnabled;
              ref
                  .read(settingsProvider.notifier)
                  .setStreamingEnabled(next);
              final messenger = ScaffoldMessenger.maybeOf(context);
              if (messenger != null) {
                // SnackBar の既定背景は light/dark でちょうど反転するため
                // (light テーマでは暗い背景, dark テーマでは明るい背景)、
                // ここでは onInverseSurface を使って両方で読めるようにする。
                final fg = Theme.of(context).colorScheme.onInverseSurface;
                messenger.hideCurrentSnackBar();
                messenger.showSnackBar(
                  SnackBar(
                    duration: const Duration(seconds: 2),
                    content: Row(
                      children: [
                        Icon(
                          next ? Icons.podcasts : Icons.podcasts_outlined,
                          color: fg,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            next
                                ? context.l10n.streamingConnected
                                : context.l10n.streamingDisconnected,
                            style: TextStyle(color: fg),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }
            },
          ),
        ],
        bottom:
            isDesktop
                ? null
                // TabBar は内部で _kTabHeight (46px) を最低限として preferredSize
                // を返すため、Tab(height: 32) を指定しても AppBar は 48px 予約してしまう
                // (Tab は 32px で描画されるが下に 14px の空白が残る)。
                // PreferredSize で外側から強制的に高さを 34px (Tab 32 + indicator 2)
                // に上書きしてタイムライン領域を広げる。
                : PreferredSize(
                  preferredSize: const Size.fromHeight(34),
                  child: TabBar(
                  controller: _tabController,
                  isScrollable: true,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 12),
                  tabs: [
                    for (final col in columns)
                      Tab(
                        height: 32,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (var source in col['sources']) ...[
                              Icon(
                                () {
                                  final tlType =
                                      source['timelineType'] as String;
                                  if (tlType.startsWith('list_')) {
                                    return Icons.list;
                                  }
                                  return _timelineTypeIcons[tlType] ??
                                      Icons.timeline;
                                }(),
                                size: 16,
                                color: () {
                                  final accounts =
                                      ref.read(authProvider).accounts;
                                  if (accounts.isEmpty) return null;
                                  final accountId =
                                      source['accountId'] as String?;
                                  final account = accounts.firstWhere(
                                    (a) => a.id == accountId,
                                    orElse: () => accounts.first,
                                  );
                                  return account.accountColor;
                                }(),
                              ),
                              const SizedBox(width: 2),
                            ],
                            if (((col['title'] as String?) ?? '')
                                .isNotEmpty) ...[
                              const SizedBox(width: 4),
                              Text(col['title'] as String),
                            ],
                          ],
                        ),
                      ),
                  ],
                  onTap: (idx) {
                    // 同じタブを再タップしたら先頭へスクロール
                    if (_tabController!.index == idx) {
                      _keys[idx].currentState?.scrollToTop();
                    }
                  },
                ),
                ),
      ),
      body:
          isDesktop
              ? Row(
                children: List.generate(columns.length, (i) {
                  // デスクトップは複数カラム同時表示なので全部 active
                  return Expanded(
                    child: ColumnTimelineView(
                      key: _keys[i],
                      column: columns[i],
                      isActive: true,
                    ),
                  );
                }),
              )
              : TabBarView(
                controller: _tabController,
                // ColumnTimelineView は AutomaticKeepAliveClientMixin で
                // opt-in しているので、TabBarView が自動的に KeepAlive を
                // 適用する。外側の AutomaticKeepAlive ラップは不要 (むしろ
                // ParentDataWidget エラーを誘発するので外してある)
                //
                // ただし KeepAlive で裏のタブの State も生かしっぱなしになる
                // ため、SSE 購読を有効にしておくと裏のカラムも全部イベント
                // 処理 + setState して表のスクロールに干渉する。`isActive`
                // で現在表示中のタブだけが SSE を購読するように切り替える。
                children: List.generate(columns.length, (i) {
                  if (isNotificationColumn(columns[i])) {
                    // isActive で「このタブが表示中か」を伝える。表示中だけ
                    // 通知タブ同様に既読扱いにしてナビ未読バッジを抑制する。
                    return NotificationsPage(
                      embedded: true,
                      isActive: i == _tabController!.index,
                    );
                  }
                  return ColumnTimelineView(
                    key: _keys[i],
                    column: columns[i],
                    isActive: i == _tabController!.index,
                  );
                }),
              ),
      floatingActionButton: FloatingActionButton(
        // PostPage 等が持つ default タグ FAB と遷移アニメ中に衝突して
        // 「multiple heroes share the same tag」で落ちるため一意タグを付与。
        heroTag: 'main_compose_fab',
        onPressed: () {
          // 現在のタブのカラムからアカウントIDを取得
          final currentIndex = _tabController?.index ?? 0;
          final currentColumn = columns[currentIndex];
          final accountIds = <String>[];

          if (currentColumn['sources'] != null) {
            for (final source in currentColumn['sources'] as List) {
              final accountId = source['accountId'] as String?;
              if (accountId != null && !accountIds.contains(accountId)) {
                accountIds.add(accountId);
              }
            }
          }

          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => PostPage(initialAccountIds: accountIds),
            ),
          );
        },
        child: const Icon(Icons.edit),
      ),
    );
  }
}
