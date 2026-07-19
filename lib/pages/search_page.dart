// lib/pages/search_page.dart

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../widgets/network_image_x.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import '../models/auth_account.dart';
import '../models/status.dart';
import '../models/emoji.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
import '../services/local_status_event_bus.dart';
import '../services/mastodon_api.dart';
import '../widgets/post_tile.dart';
import '../widgets/timeline_post_decoration.dart';
import '../widgets/user_avatar.dart';
import '../pages/hashtag_page.dart';
import '../utils/html_parser.dart';
import '../utils/open_profile.dart';

class SearchPage extends ConsumerStatefulWidget {
  /// Deck (ワイド) のポップアップで開かれた時に渡される戻る (←) コールバック。
  /// null (ナロー/通常) のときは AppBar に戻る矢印を出さない。
  final VoidCallback? onDeckBack;

  const SearchPage({super.key, this.onDeckBack});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _searchController = TextEditingController();
  
  // データ保持用
  List<Status> _trendingPosts = [];
  List<TrendingHashtag> _trendingHashtags = [];
  List<SuggestedAccount> _suggestedUsers = [];
  List<TrendingLink> _trendingNews = [];
  
  // ローディング状態
  bool _isLoadingPosts = false;
  bool _isLoadingHashtags = false;
  bool _isLoadingUsers = false;
  bool _isLoadingNews = false;

  /// 探索ページで使用するアカウント ID。`current` 概念廃止に伴いページ内の
  /// ローカル state として持ち、SharedPreferences で永続化する。null の間は
  /// `accounts.first` にフォールバック。
  static const _prefsKeySearchAccount = 'search_last_account_id';
  String? _searchAccountId;

  /// `_searchAccountId` を解決して該当 AuthAccount を返す。null や invalid
  /// なら `accounts.first` を返す。アカウント 0 件の場合は null。
  AuthAccount? get _searchAccount {
    final accounts = ref.read(authProvider).accounts;
    if (accounts.isEmpty) return null;
    if (_searchAccountId != null) {
      for (final a in accounts) {
        if (a.id == _searchAccountId) return a;
      }
    }
    return accounts.first;
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _restoreSearchAccount().then((_) => _loadInitialData());
  }

  Future<void> _restoreSearchAccount() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKeySearchAccount);
    if (saved != null && mounted) {
      setState(() => _searchAccountId = saved);
    }
  }

  Future<void> _persistSearchAccount(String accountId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKeySearchAccount, accountId);
  }


  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialData() async {
    // 各タブのデータを並行して読み込み
    await Future.wait([
      _loadTrendingPosts(),
      _loadTrendingHashtags(),
      _loadSuggestedUsers(),
      _loadTrendingNews(),
    ]);
  }

  Future<void> _loadTrendingPosts() async {
    if (_isLoadingPosts) return;
    setState(() => _isLoadingPosts = true);
    
    try {
      final auth = _searchAccount;
      if (auth == null) return;
      
      final posts = await fetchTrendingPosts(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
      );
      if (mounted) {
        setState(() => _trendingPosts = posts);
      }
    } catch (e) {
      debugPrint('Error loading trending posts: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoadingPosts = false);
      }
    }
  }

  Future<void> _loadTrendingHashtags() async {
    if (_isLoadingHashtags) return;
    setState(() => _isLoadingHashtags = true);
    
    try {
      final auth = _searchAccount;
      if (auth == null) return;
      
      final hashtags = await fetchTrendingHashtags(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
      );
      if (mounted) {
        setState(() => _trendingHashtags = hashtags);
      }
    } catch (e) {
      debugPrint('Error loading trending hashtags: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoadingHashtags = false);
      }
    }
  }

  Future<void> _loadSuggestedUsers() async {
    if (_isLoadingUsers) return;
    setState(() => _isLoadingUsers = true);
    
    try {
      final auth = _searchAccount;
      if (auth == null) return;
      
      final users = await fetchSuggestedUsers(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
      );
      if (mounted) {
        setState(() => _suggestedUsers = users);
      }
    } catch (e) {
      debugPrint('Error loading suggested users: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoadingUsers = false);
      }
    }
  }

  Future<void> _loadTrendingNews() async {
    if (_isLoadingNews) return;
    setState(() => _isLoadingNews = true);
    
    try {
      final auth = _searchAccount;
      if (auth == null) return;
      
      final news = await fetchTrendingLinks(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
      );
      if (mounted) {
        setState(() => _trendingNews = news);
      }
    } catch (e) {
      debugPrint('Error loading trending news: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoadingNews = false);
      }
    }
  }

  Future<void> _performSearch(String query) async {
    if (query.trim().isEmpty) return;
    final acct = _searchAccount;
    if (acct == null) return;

    // 検索結果ページへ遷移 (使用アカウントを明示的に渡す)
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SearchResultsPage(query: query.trim(), account: acct),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);

    return Scaffold(
      appBar: AppBar(
        // AppBar 自体を少し高くして縦の余白を確保する。glyph の ink box が font の
        // ascent/descent を超える端末 (Sony Xperia 等) で漢字の上下が切れる問題は、
        // 行ボックスの高さ不足が原因なので、ここで高さを取るのが素直な対処。
        toolbarHeight: 64,
        leading: widget.onDeckBack == null
            ? null
            : BackButton(onPressed: widget.onDeckBack),
        // 行の高さを少し広げ、余白を上下均等に配って (leadingDistribution.even)
        // glyph を行ボックスの中央に置く。これで Xperia 等での見切れを覆いつつ、
        // leading の戻る矢印とも縦位置が揃う。`forceStrutHeight` を使うと glyph が
        // 上寄りになって矢印と揃わなかったため、strut は使わず TextStyle 側で配る。
        title: Text(
          context.l10n.searchExplore,
          style: const TextStyle(
            height: 1.5,
            leadingDistribution: TextLeadingDistribution.even,
          ),
        ),
        actions: [
          // アカウント切り替え (この探索ページ内だけのローカル選択。global の
          // current は変更しない)。選択中アバター + ▼ だけのコンパクトな
          // トリガにして、表示名/@ID がどれだけ長くても actions 側が幅を食って
          // AppBar の「探索」タイトルを潰さないようにする (旧 DropdownButton は
          // 選択中表示に名前と @ID を出すため、長いと探索の文字が消えていた)。
          // アカウント一覧はプロフィールページと同じくモーダルボトムシートで
          // 画面下から出す。
          if (authState.accounts.length > 1)
            _buildAccountSwitcher(authState.accounts),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(100),
          child: Column(
            children: [
              // 検索バー
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: context.l10n.searchHint,
                    prefixIcon: const Icon(Icons.search),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(25),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                  ),
                  onSubmitted: _performSearch,
                ),
              ),
              // タブバー
              TabBar(
                controller: _tabController,
                tabs: [
                  Tab(text: context.l10n.searchTabPosts),
                  Tab(text: context.l10n.hashtags),
                  Tab(text: context.l10n.searchTabUsers),
                  Tab(text: context.l10n.searchTabNews),
                ],
              ),
            ],
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildPostsTab(),
          _buildHashtagsTab(),
          _buildUsersTab(),
          _buildNewsTab(),
        ],
      ),
    );
  }

  /// AppBar のアカウント切り替えトリガ。選択中アカウントのアバター + 表示名 +
  /// ▼ を出す。ただし表示名は `maxWidth` で上限を設けて末尾省略するため、名前が
  /// どれだけ長くても actions 側が AppBar の幅を食い尽くさず、「探索」タイトルが
  /// 消えない (旧 DropdownButton はここが無制限で名前が長いとタイトルが消えた)。
  /// タップでモーダルボトムシートを下から出す。
  Widget _buildAccountSwitcher(List<AuthAccount> accounts) {
    final selected = _searchAccount;
    final name = selected == null
        ? ''
        : (selected.displayName.isNotEmpty
            ? selected.displayName
            : selected.username);
    // 画面幅に応じて名前の最大幅を決める。狭い端末でもタイトルの余白を残すため
    // 上限を抑えめにし、広い端末では長めに出す。
    final maxNameWidth =
        (MediaQuery.of(context).size.width * 0.3).clamp(72.0, 180.0);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => _showAccountSwitcher(accounts),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // AppBar の actions スロットは toolbar の content 高さ (タイトル基準、
              // 実測 ~36px) しか確保されず、toolbarHeight(64) 全体は来ない。ここに
              // スロットより大きいアバターを置くと、Web の UserAvatar(ClipOval+
              // SizedBox) がスロット高さに潰れて「横長楕円」になり (commit ce5bdc4
              // と同種)、固定サイズで押し込むと 2px ずつオーバーフローする。スロットに
              // 収まる radius 14 (28px) にして、縦に余白を残したまま真円で収める。
              UserAvatar(
                url: selected?.avatarUrl ?? '',
                radius: 14,
              ),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxNameWidth),
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const Icon(Icons.arrow_drop_down),
            ],
          ),
        ),
      ),
    );
  }

  /// 検索に使うアカウントの選択をモーダルボトムシートで表示する
  /// (プロフィールページのアカウント切り替えと同じく画面下から出す)。
  /// 選択は探索ページ内のローカル state で、global の current は変えない。
  void _showAccountSwitcher(List<AuthAccount> accounts) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                context.l10n.searchAccountLabel,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: accounts.map((account) {
                    final isSelected = account.id == _searchAccount?.id;
                    return ListTile(
                      leading: Stack(
                        children: [
                          UserAvatar(url: account.avatarUrl, radius: 20),
                          if (account.accountColor != null)
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: Container(
                                width: 12,
                                height: 12,
                                decoration: BoxDecoration(
                                  color: account.accountColor,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Theme.of(context).cardColor,
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      title: Text(
                        account.displayName.isNotEmpty
                            ? account.displayName
                            : account.username,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      subtitle: Text(
                        '@${account.username}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: isSelected
                          ? const Icon(Icons.check, color: Colors.green)
                          : null,
                      onTap: () {
                        Navigator.pop(context);
                        if (account.id != _searchAccount?.id) {
                          setState(() => _searchAccountId = account.id);
                          _persistSearchAccount(account.id);
                          // アカウント切り替え後にデータを再読み込み
                          _loadInitialData();
                        }
                      },
                    );
                  }).toList(),
                ),
              ),
              // ナビゲーションバー分のスペースを確保
              SizedBox(height: MediaQuery.of(context).padding.bottom),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPostsTab() {
    if (_isLoadingPosts) {
      return const Center(child: CircularProgressIndicator());
    }
    
    if (_trendingPosts.isEmpty) {
      return Center(child: Text(context.l10n.searchNoTrendingPosts));
    }

    final layout = ref.watch(settingsProvider.select((s) => s.timelineLayout));
    return RefreshIndicator(
      onRefresh: _loadTrendingPosts,
      child: ListView.builder(
        itemCount: _trendingPosts.length,
        itemBuilder: (context, index) {
          return Column(
            children: [
              wrapForTimelineLayout(
                context,
                PostTile(status: _trendingPosts[index]),
                layout,
              ),
              timelineSeparator(layout),
            ],
          );
        },
      ),
    );
  }

  Widget _buildHashtagsTab() {
    final settings = ref.watch(settingsProvider.select((s) => (
      themeColor: s.themeColor,
      fontSize: s.fontSize,
    )));
    
    if (_isLoadingHashtags) {
      return const Center(child: CircularProgressIndicator());
    }
    
    if (_trendingHashtags.isEmpty) {
      return Center(child: Text(context.l10n.searchNoTrendingHashtags));
    }

    return RefreshIndicator(
      onRefresh: _loadTrendingHashtags,
      child: ListView.builder(
        itemCount: _trendingHashtags.length,
        itemBuilder: (context, index) {
          final hashtag = _trendingHashtags[index];
          return ListTile(
            leading: CircleAvatar(
              backgroundColor: settings.themeColor.withValues(alpha: 0.1),
              child: Text(
                '#',
                style: TextStyle(
                  color: settings.themeColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ),
            title: Text(
              '#${hashtag.name}',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: settings.fontSize,
              ),
            ),
            subtitle: Text(
              context.l10n.searchTalkingCount(hashtag.uses),
              style: TextStyle(fontSize: settings.fontSize * 0.9),
            ),
            trailing: hashtag.history.isNotEmpty
                ? _buildTrendChart(hashtag.history)
                : null,
            onTap: () {
              _performSearch('#${hashtag.name}');
            },
          );
        },
      ),
    );
  }

  Widget _buildUsersTab() {
    final settings = ref.watch(settingsProvider.select((s) => (
      fontSize: s.fontSize,
      avatarSize: s.avatarSize,
      emojiScale: s.emojiScale,
      emojiScaleInDisplayName: s.emojiScaleInDisplayName,
      disableCustomEmojiAnimationInDisplayName:
          s.disableCustomEmojiAnimationInDisplayName,
      disableCustomEmojiAnimationInContent:
          s.disableCustomEmojiAnimationInContent,
    )));

    if (_isLoadingUsers) {
      return const Center(child: CircularProgressIndicator());
    }
    
    if (_suggestedUsers.isEmpty) {
      return Center(child: Text(context.l10n.searchNoSuggestedUsers));
    }

    return RefreshIndicator(
      onRefresh: _loadSuggestedUsers,
      child: ListView.builder(
        itemCount: _suggestedUsers.length,
        itemBuilder: (context, index) {
          final user = _suggestedUsers[index];
          final emojiSizeDisplayName = settings.fontSize * settings.emojiScaleInDisplayName;
          final emojiSizeContent = settings.fontSize * settings.emojiScale;
          
          return Column(
            children: [
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                leading: GestureDetector(
                  onTap: () => _navigateToProfile(user),
                  child: UserAvatar(
                    url: user.avatarStatic,
                    radius: settings.avatarSize / 2,
                  ),
                ),
                // RichText ではなく Text.rich を使うことで、テーマの
                // fontFamilyFallback (Web/デスクトップの日本語フォント) を
                // DefaultTextStyle 経由で継承し、漢字が中国語字形になるのを防ぐ。
                // RichText は DefaultTextStyle を継承しないので不可。
                // textScaler は見た目維持のため noScaling 固定 (本アプリは
                // フォントサイズを設定で制御しているため)。
                title: Text.rich(
                  TextSpan(
                    style: TextStyle(
                      fontSize: settings.fontSize,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).textTheme.bodyLarge?.color,
                    ),
                    children: parseContentWithEmojis(
                      contentHtml: user.displayName,
                      emojis: user.emojis,
                      baseStyle: TextStyle(
                        fontSize: settings.fontSize,
                        fontWeight: FontWeight.bold,
                                              ),
                      linkColor: Colors.blue, // リンクは青色固定
                      emojiSize: emojiSizeDisplayName,
                      disableEmojiAnimation: settings.disableCustomEmojiAnimationInDisplayName,
                      enableInlineLinks: false, // 表示名は metadata
                    ),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textScaler: TextScaler.noScaling,
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      // `acct` はローカルなら `user`、リモートなら `user@host` を返す
                      // webfinger 形式。`username` だと連合先と自インスタンスを
                      // 区別できないので acct を使う。
                      '@${user.acct}',
                      style: TextStyle(
                        fontSize: settings.fontSize * 0.9,
                        color: Colors.grey,
                                              ),
                    ),
                    if (user.note.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      RichText(
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        text: TextSpan(
                          style: TextStyle(
                            fontSize: settings.fontSize * 0.8,
                            color: Colors.grey[600],
                                                      ),
                          children: parseContentWithEmojis(
                            contentHtml: user.note,
                            emojis: user.emojis,
                            baseStyle: TextStyle(
                              fontSize: settings.fontSize * 0.8,
                              color: Colors.grey[600],
                                                          ),
                            linkColor: Colors.blue, // リンクは青色固定
                            emojiSize: emojiSizeContent * 0.8,
                            disableEmojiAnimation: settings.disableCustomEmojiAnimationInContent,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                trailing: user.followersCount != null
                    ? Text(
                        context.l10n.followersCountLabel(
                            _formatNumber(user.followersCount!)),
                        style: TextStyle(
                          fontSize: settings.fontSize * 0.8,
                          color: Colors.grey,
                                                  ),
                      )
                    : null,
                onTap: () => _navigateToProfile(user),
              ),
              const Divider(height: 1),
            ],
          );
        },
      ),
    );
  }

  Widget _buildNewsTab() {
    final settings = ref.watch(settingsProvider.select((s) => (
      fontSize: s.fontSize,
    )));

    if (_isLoadingNews) {
      return const Center(child: CircularProgressIndicator());
    }
    
    if (_trendingNews.isEmpty) {
      return Center(child: Text(context.l10n.searchNoTrendingNews));
    }

    return RefreshIndicator(
      onRefresh: _loadTrendingNews,
      child: ListView.builder(
        itemCount: _trendingNews.length,
        itemBuilder: (context, index) {
          final news = _trendingNews[index];
          return Card(
            margin: const EdgeInsets.all(8),
            child: InkWell(
              onTap: () => _openLink(news.url),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (news.image?.isNotEmpty == true)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: KurageNetworkImage(
                          imageUrl: news.image!,
                          width: 80,
                          height: 80,
                          fit: BoxFit.cover,
                          placeholder: (_, _) => Container(
                            color: Colors.grey.shade200,
                            width: 80,
                            height: 80,
                          ),
                          errorWidget: (_, _, _) => Container(
                            color: Colors.grey.shade200,
                            width: 80,
                            height: 80,
                            child: const Icon(Icons.article),
                          ),
                        ),
                      ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            news.title,
                            style: TextStyle(
                              fontSize: settings.fontSize,
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          if (news.description?.isNotEmpty == true)
                            Text(
                              news.description!,
                              style: TextStyle(
                                fontSize: settings.fontSize * 0.9,
                                color: Colors.grey[600],
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                          const SizedBox(height: 8),
                          Text(
                            context.l10n.searchSharedCount(news.uses),
                            style: TextStyle(
                              fontSize: settings.fontSize * 0.8,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTrendChart(List<TrendHistory> history) {
    if (history.isEmpty) return const SizedBox.shrink();
    
    final maxUses = history.map((h) => h.uses).reduce((a, b) => a > b ? a : b);
    
    return SizedBox(
      width: 60,
      height: 30,
      child: CustomPaint(
        painter: TrendChartPainter(
          history: history,
          maxUses: maxUses,
          color: ref.watch(settingsProvider.select((s) => s.themeColor)),
        ),
      ),
    );
  }

  void _navigateToProfile(SuggestedAccount user) {
    final auth = _searchAccount;
    if (auth == null) return;

    // user (ログイン中の AuthAccount) は API 認証用に渡し、表示対象は
    // targetAccountId で指定する。ここを誤って AuthAccount を作り直して
    // しまうと ProfilePage が「自分のプロフィール」判定に倒れて編集
    // ボタンが出てしまう。
    //
    // targetUsername / targetInstanceUrl も渡しておく: ProfilePage で
    // 「別のアカウントから開く」を選んで別インスタンスのアカウントに切替
    // したとき、`targetAccountId` は元インスタンス側の ID なので無効になる。
    // その fallback として username + instance URL から検索 (search) し直す
    // 仕組みが ProfilePage 側にあるため、その材料を渡す必要がある。
    final acct = user.acct.isNotEmpty ? user.acct : user.username;
    final String username;
    final String instanceUrl;
    if (acct.contains('@')) {
      final parts = acct.split('@');
      username = parts.first;
      instanceUrl = 'https://${parts.last}';
    } else {
      username = acct;
      instanceUrl = auth.instanceUrl;
    }

    openProfile(
      context,
      user: auth,
      targetAccountId: user.id,
      targetUsername: username,
      targetInstanceUrl: instanceUrl,
    );
  }

  void _openLink(String url) {
    // URL を開く処理（url_launcher パッケージを使用）
    // launchUrl(Uri.parse(url));
    debugPrint('Opening URL: $url');
  }

  String _formatNumber(int number) {
    if (number >= 1000000) {
      return '${(number / 1000000).toStringAsFixed(1)}M';
    } else if (number >= 1000) {
      return '${(number / 1000).toStringAsFixed(1)}K';
    }
    return number.toString();
  }
}

// 検索結果ページ
class SearchResultsPage extends ConsumerStatefulWidget {
  final String query;
  /// 検索を実行するアカウント。`current` 概念廃止に伴い、呼び出し側
  /// (探索ページのドロップダウンで選んだアカウント) から明示的に渡す。
  final AuthAccount account;

  const SearchResultsPage({
    super.key,
    required this.query,
    required this.account,
  });

  @override
  ConsumerState<SearchResultsPage> createState() => _SearchResultsPageState();
}

class _SearchResultsPageState extends ConsumerState<SearchResultsPage> {
  List<Status> _posts = [];
  List<dynamic> _accounts = [];
  List<dynamic> _hashtags = [];
  bool _isLoading = false;
  StreamSubscription<LocalStatusEvent>? _localStatusEventSub;

  @override
  void initState() {
    super.initState();
    _localStatusEventSub = localStatusEventStream.listen(_onLocalStatusEvent);
    _performSearch();
  }

  @override
  void dispose() {
    _localStatusEventSub?.cancel();
    _localStatusEventSub = null;
    super.dispose();
  }

  /// 検索結果の `_posts` に編集 / 削除を反映する。検索を実行したアカウント
  /// (= `widget.account`) と操作元アカウントが一致するときだけ処理する。
  void _onLocalStatusEvent(LocalStatusEvent event) {
    if (!mounted) return;
    if (event.accountId != widget.account.id) return;

    switch (event) {
      case LocalStatusDeleted():
        final before = _posts.length;
        _posts.removeWhere((s) => s.id == event.statusId);
        if (_posts.length != before) setState(() {});

      case LocalStatusEdited():
        var changed = false;
        for (var i = 0; i < _posts.length; i++) {
          if (_posts[i].id == event.updated.id) {
            _posts[i] = event.updated;
            changed = true;
          }
        }
        if (changed) setState(() {});
    }
  }


  Future<void> _performSearch() async {
    setState(() => _isLoading = true);

    try {
      final auth = widget.account;

      debugPrint('Searching for: "${widget.query}" on ${auth.instanceUrl}');
      
      final results = await searchContent(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
        query: widget.query,
      );
      
      debugPrint('Search results: ${results.keys}');
      debugPrint('Posts count: ${(results['statuses'] as List?)?.length ?? 0}');
      debugPrint('Accounts count: ${(results['accounts'] as List?)?.length ?? 0}');
      debugPrint('Hashtags count: ${(results['hashtags'] as List?)?.length ?? 0}');
      
      if (mounted) {
        debugPrint('Processing search results...');
        final rawPosts = results['statuses'] as List<dynamic>? ?? [];
        debugPrint('Raw posts type: ${rawPosts.runtimeType}');
        debugPrint('Raw posts length: ${rawPosts.length}');
        
        // APIから返されたStatusオブジェクトを直接使用
        final processedPosts = rawPosts.whereType<Status>().toList();
        debugPrint('Processed posts length: ${processedPosts.length}');
        
        setState(() {
          _posts = processedPosts;
          _accounts = results['accounts'] ?? [];
          _hashtags = results['hashtags'] ?? [];
        });
        
        debugPrint('After setState - _posts length: ${_posts.length}');
      }
    } catch (e) {
      debugPrint('Search error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.searchError('$e'))),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    debugPrint('SearchResultsPage build - _isLoading: $_isLoading, _posts.length: ${_posts.length}');
    
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.searchResultsTitle(widget.query)),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : DefaultTabController(
              length: 3,
              child: Column(
                children: [
                  TabBar(
                    tabs: [
                      Tab(text: context.l10n.searchTabPosts),
                      Tab(text: context.l10n.searchTabAccounts),
                      Tab(text: context.l10n.hashtags),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _buildPostResults(),
                        _buildAccountResults(),
                        _buildHashtagResults(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildPostResults() {
    if (_posts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.search_off, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              context.l10n.searchNoPostsFound(widget.query),
              style: const TextStyle(fontSize: 16, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    
    final layout = ref.watch(settingsProvider.select((s) => s.timelineLayout));
    return ListView.builder(
      itemCount: _posts.length,
      itemBuilder: (context, index) {
        return Column(
          children: [
            wrapForTimelineLayout(
              context,
              PostTile(status: _posts[index]),
              layout,
            ),
            timelineSeparator(layout),
          ],
        );
      },
    );
  }

  Widget _buildAccountResults() {
    if (_accounts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.person_search, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              context.l10n.searchNoAccountsFound(widget.query),
              style: const TextStyle(fontSize: 16, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    
    return ListView.builder(
      itemCount: _accounts.length,
      itemBuilder: (context, index) {
        final account = _accounts[index];
        return ListTile(
          leading: UserAvatar(
            url: account.avatarStatic ?? '',
            radius: 20,
          ),
          title: Text(account.displayName ?? ''),
          // `acct` はローカル `user` / リモート `user@host` の webfinger 形式。
          subtitle: Text('@${account.acct}'),
          onTap: () => _navigateToProfile(account),
        );
      },
    );
  }

  Widget _buildHashtagResults() {
    if (_hashtags.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.tag, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              context.l10n.searchNoHashtagsFound(widget.query),
              style: const TextStyle(fontSize: 16, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    
    return ListView.builder(
      itemCount: _hashtags.length,
      itemBuilder: (context, index) {
        final hashtag = _hashtags[index];
        return ListTile(
          leading: const Icon(Icons.tag),
          title: Text('#${hashtag.name}'),
          onTap: () => _navigateToHashtag(hashtag.name),
        );
      },
    );
  }

  /// 検索結果のアカウントからプロフィールページに遷移
  void _navigateToProfile(dynamic account) {
    final auth = widget.account;
    final id = account.id?.toString() ?? '';
    if (id.isEmpty) return;

    // 注意: AuthAccount を作り直すと「自分のプロフィール」判定に倒れて
    // しまう。ログイン中の auth をそのまま渡し、表示対象は targetAccountId
    // で指定する。
    //
    // targetUsername / targetInstanceUrl も併せて渡しておく
    // (上の _navigateToProfile(SuggestedAccount) と同じ理由 ── 「別の
    // アカウントから開く」で別インスタンスへ切替したときの fallback 材料)。
    // SuggestedAccount は `acct` を持つので、無ければ `username` で代替。
    final dynamic acctRaw = account.acct ?? account.username ?? '';
    final String acct = acctRaw.toString();
    final String username;
    final String instanceUrl;
    if (acct.contains('@')) {
      final parts = acct.split('@');
      username = parts.first;
      instanceUrl = 'https://${parts.last}';
    } else {
      username = acct;
      instanceUrl = auth.instanceUrl;
    }

    openProfile(
      context,
      user: auth,
      targetAccountId: id,
      targetUsername: username,
      targetInstanceUrl: instanceUrl,
    );
  }

  /// 検索結果のハッシュタグからハッシュタグページに遷移
  void _navigateToHashtag(String hashtagName) {
    openDeckPage(
      context,
      (onDeckBack) => HashtagPage(hashtag: hashtagName, onDeckBack: onDeckBack),
    );
  }
}

// トレンドチャート描画用のカスタムペインター
class TrendChartPainter extends CustomPainter {
  final List<TrendHistory> history;
  final int maxUses;
  final Color color;

  TrendChartPainter({
    required this.history,
    required this.maxUses,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (history.isEmpty || maxUses == 0) return;

    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final path = Path();
    
    for (int i = 0; i < history.length; i++) {
      final x = (i / (history.length - 1)) * size.width;
      final y = size.height - ((history[i].uses / maxUses) * size.height);
      
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// 必要なデータモデル（実際のプロジェクトでは適切なファイルに配置）
class TrendingHashtag {
  final String name;
  final int uses;
  final List<TrendHistory> history;

  TrendingHashtag({
    required this.name,
    required this.uses,
    required this.history,
  });
}

class TrendHistory {
  final String day;
  final int uses;
  final int accounts;

  TrendHistory({
    required this.day,
    required this.uses,
    required this.accounts,
  });
}

class SuggestedAccount {
  final String id;
  final String username;

  /// 完全な webfinger 形式 (`user@host.example`)、ローカルアカウントなら
  /// `user` のみ。検索 API がロードしたインスタンス上での acct なので、
  /// 「別アカウントから開く」で別インスタンスへ切り替えるとき、これを使って
  /// `targetUsername` と `targetInstanceUrl` を復元する。
  final String acct;

  final String displayName;
  final String note;
  final String avatarStatic;
  final int? followersCount;
  final List<Emoji> emojis;

  SuggestedAccount({
    required this.id,
    required this.username,
    required this.acct,
    required this.displayName,
    required this.note,
    required this.avatarStatic,
    this.followersCount,
    this.emojis = const [],
  });
}

class TrendingLink {
  final String url;
  final String title;
  final String? description;
  final String? image;
  final int uses;

  TrendingLink({
    required this.url,
    required this.title,
    this.description,
    this.image,
    required this.uses,
  });
}