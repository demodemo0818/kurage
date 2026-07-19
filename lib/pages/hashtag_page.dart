// lib/pages/hashtag_page.dart

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../models/status.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
import '../services/local_status_event_bus.dart';
import '../services/mastodon_api.dart';
import '../widgets/post_tile.dart';
import '../widgets/timeline_post_decoration.dart';
import 'post_page.dart';

class HashtagPage extends ConsumerStatefulWidget {
  final String hashtag;

  /// Deck ポップアップで最初のページとして開かれた時だけ非 null。AppBar の
  /// 戻る (←) でポップアップ全体を閉じるのに使う。
  final VoidCallback? onDeckBack;

  const HashtagPage({super.key, required this.hashtag, this.onDeckBack});

  @override
  ConsumerState<HashtagPage> createState() => _HashtagPageState();
}

class _HashtagPageState extends ConsumerState<HashtagPage> {
  List<Status> _posts = [];
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _isFollowing = false;
  String? _maxId;
  final ScrollController _scrollController = ScrollController();
  StreamSubscription<LocalStatusEvent>? _localStatusEventSub;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _localStatusEventSub = localStatusEventStream.listen(_onLocalStatusEvent);
    _loadHashtagPosts();
    _checkFollowStatus();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _localStatusEventSub?.cancel();
    _localStatusEventSub = null;
    super.dispose();
  }

  /// 自分の投稿の編集 / 削除を `_posts` に反映する。ハッシュタグ TL は
  /// `auth.accounts.first` で fetch しているので、操作元アカウントが
  /// それと一致する場合だけ処理する。
  void _onLocalStatusEvent(LocalStatusEvent event) {
    if (!mounted) return;
    final viewer = ref.read(authProvider).accounts.isEmpty
        ? null
        : ref.read(authProvider).accounts.first;
    if (viewer == null || event.accountId != viewer.id) return;

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

  void _onScroll() {
    if (_scrollController.position.pixels >= 
        _scrollController.position.maxScrollExtent - 500) {
      _loadMorePosts();
    }
  }

  Future<void> _loadHashtagPosts() async {
    if (_isLoading) return;
    
    setState(() {
      _isLoading = true;
      _maxId = null;
    });

    try {
      final auth = ref.read(authProvider).accounts.first;
      final posts = await fetchHashtagTimeline(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
        hashtag: widget.hashtag,
        limit: 20,
      );
      
      setState(() {
        _posts = posts;
        if (posts.isNotEmpty) {
          _maxId = posts.last.id;
        }
      });
    } catch (e) {
      debugPrint('Error loading hashtag posts: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.hashtagLoadPostsFailed('$e'))),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _loadMorePosts() async {
    if (_isLoadingMore || _maxId == null) return;
    
    setState(() => _isLoadingMore = true);

    try {
      final auth = ref.read(authProvider).accounts.first;
      final morePosts = await fetchHashtagTimeline(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
        hashtag: widget.hashtag,
        maxId: _maxId,
        limit: 20,
      );
      
      setState(() {
        _posts.addAll(morePosts);
        if (morePosts.isNotEmpty) {
          _maxId = morePosts.last.id;
        }
      });
    } catch (e) {
      debugPrint('Error loading more hashtag posts: $e');
    } finally {
      setState(() => _isLoadingMore = false);
    }
  }

  Future<void> _checkFollowStatus() async {
    try {
      final auth = ref.read(authProvider).accounts.first;
      final following = await isFollowingHashtag(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
        hashtag: widget.hashtag,
      );
      setState(() => _isFollowing = following);
    } catch (e) {
      debugPrint('Error checking hashtag follow status: $e');
    }
  }

  Future<void> _toggleFollow() async {
    try {
      final auth = ref.read(authProvider).accounts.first;
      final newStatus = await toggleHashtagFollow(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
        hashtag: widget.hashtag,
        currentlyFollowing: _isFollowing,
      );
      if (!mounted) return;
      setState(() => _isFollowing = newStatus);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_isFollowing
              ? context.l10n.hashtagFollowed
              : context.l10n.hashtagUnfollowed),
        ),
      );
    } catch (e) {
      debugPrint('Error toggling hashtag follow: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.actionFailed('$e'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    
    return Scaffold(
      appBar: AppBar(
        leading: widget.onDeckBack == null
            ? null
            : BackButton(onPressed: widget.onDeckBack),
        title: Text('#${widget.hashtag}'),
        actions: [
          IconButton(
            icon: Icon(_isFollowing ? Icons.notifications_active : Icons.notifications_none),
            onPressed: _toggleFollow,
            tooltip:
                _isFollowing ? context.l10n.unfollow : context.l10n.follow,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadHashtagPosts,
        child: _isLoading && _posts.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : _posts.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.tag,
                          size: 64,
                          color: Colors.grey[400],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          '#${widget.hashtag}',
                          style: TextStyle(
                            fontSize: settings.fontSize * 1.5,
                            fontWeight: FontWeight.bold,
                            color: Colors.grey[600],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          context.l10n.noPostsYet,
                          style: TextStyle(
                            fontSize: settings.fontSize,
                            color: Colors.grey[500],
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: _posts.length + (_isLoadingMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index >= _posts.length) {
                        return const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      
                      return Column(
                        children: [
                          wrapForTimelineLayout(
                            context,
                            PostTile(status: _posts[index]),
                            settings.timelineLayout,
                          ),
                          timelineSeparator(settings.timelineLayout),
                        ],
                      );
                    },
                  ),
      ),
      floatingActionButton: FloatingActionButton(
        // 遷移時の default heroTag 衝突を避けるため一意タグを付与。
        heroTag: 'hashtag_compose_fab',
        onPressed: () => _composeWithHashtag(),
        tooltip: context.l10n.hashtagComposeTooltip,
        child: const Icon(Icons.edit),
      ),
    );
  }

  void _composeWithHashtag() {
    // PostPage を直接起動する (/compose という名前付きルートは登録していない)。
    // initialText に「#ハッシュタグ 」(末尾スペース) を渡してカーソルが
    // タグの後ろから始まるようにする。アカウントは PostPage 側のデフォルト
    // (= 最後に使ったアカウント / なければ accounts.first) に任せる。
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PostPage(initialText: '#${widget.hashtag} '),
      ),
    );
  }
}