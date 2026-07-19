// lib/widgets/emoji_picker.dart

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart' as ep;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../models/emoji.dart';
import '../services/mastodon_api.dart' as api;
import '../providers/auth_provider.dart';
import 'network_image_x.dart';

class EmojiPicker extends ConsumerStatefulWidget {
  final Function(String) onEmojiSelected;
  final Set<String> selectedAccountIds;

  const EmojiPicker({
    super.key,
    required this.onEmojiSelected,
    required this.selectedAccountIds,
  });

  @override
  ConsumerState<EmojiPicker> createState() => _EmojiPickerState();
}

class _EmojiPickerState extends ConsumerState<EmojiPicker> with TickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _searchController = TextEditingController();

  final Map<String, List<Emoji>> _customEmojisByInstance = {};
  List<Emoji> _allCustomEmojis = [];
  List<Emoji> _filteredCustomEmojis = [];
  // カスタム絵文字をカテゴリ別にグループ化したもの。
  // 順序を保持するため LinkedHashMap (Dart の Map のデフォルト) を使う。
  // 未分類は null キー → '未分類' ラベルで末尾配置。
  Map<String, List<Emoji>> _customByCategory = {};
  // 統合検索: 標準 (Unicode) 絵文字の検索結果。emoji_picker_flutter の
  // EmojiPickerUtils.searchEmoji に委譲。
  List<ep.Emoji> _filteredStandardEmojis = [];
  final ep.EmojiPickerUtils _epUtils = ep.EmojiPickerUtils();
  int _searchToken = 0;
  bool _isLoading = true;
  String _searchQuery = '';
  Set<String> _lastSelectedAccountIds = {};

  @override
  void initState() {
    super.initState();
    // 0: カスタム / 1: 標準 (emoji_picker_flutter)
    _tabController = TabController(length: 2, vsync: this);
    _searchController.addListener(_onSearchChanged);
    _lastSelectedAccountIds = Set.from(widget.selectedAccountIds);
    _loadCustomEmojis();
  }

  @override
  void didUpdateWidget(EmojiPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    // アカウント選択が変更された場合、絵文字を再読み込み
    if (!_setEquals(_lastSelectedAccountIds, widget.selectedAccountIds)) {
      _lastSelectedAccountIds = Set.from(widget.selectedAccountIds);
      _loadCustomEmojis();
    }
  }

  bool _setEquals<T>(Set<T> a, Set<T> b) {
    if (a.length != b.length) return false;
    return a.containsAll(b);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final q = _searchController.text.toLowerCase();
    setState(() {
      _searchQuery = q;
      // カスタム側は同期で即フィルタ。
      if (q.isEmpty) {
        _filteredCustomEmojis = _allCustomEmojis;
        _filteredStandardEmojis = [];
      } else {
        _filteredCustomEmojis = _allCustomEmojis
            .where((emoji) => emoji.shortcode.toLowerCase().contains(q))
            .toList();
      }
    });
    // 標準絵文字は非同期検索 (platform compatibility チェックで I/O が走る)。
    // 古いクエリの結果で上書きされないよう token で stale check。
    if (q.isEmpty) return;
    final token = ++_searchToken;
    _epUtils.searchEmoji(q, ep.defaultEmojiSet).then((results) {
      if (!mounted || token != _searchToken) return;
      setState(() {
        _filteredStandardEmojis = results;
      });
    });
  }

  Future<void> _loadCustomEmojis() async {
    if (widget.selectedAccountIds.isEmpty) {
      if (mounted) {
        setState(() {
          _allCustomEmojis = [];
          _filteredCustomEmojis = [];
          _isLoading = false;
        });
      }
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final auth = ref.read(authProvider);
      final allEmojis = <Emoji>[];
      final seenEmojis = <String>{};

      // 選択されたアカウントの各インスタンスから絵文字を取得
      for (final accountId in widget.selectedAccountIds) {
        final account = auth.accounts.firstWhere(
          (a) => a.id == accountId,
          orElse: () => auth.accounts.first,
        );

        try {
          // キャッシュがあるかチェック
          if (!_customEmojisByInstance.containsKey(account.instanceUrl)) {
            final emojis = await api.fetchCustomEmojis(
              instanceUrl: account.instanceUrl,
              accessToken: account.accessToken,
            );
            _customEmojisByInstance[account.instanceUrl] = emojis;
          }

          // 重複を避けて絵文字を追加（ショートコードが同じものは除外）
          final instanceEmojis = _customEmojisByInstance[account.instanceUrl] ?? [];
          for (final emoji in instanceEmojis) {
            if (!seenEmojis.contains(emoji.shortcode)) {
              seenEmojis.add(emoji.shortcode);
              allEmojis.add(emoji);
            }
          }
        } catch (e) {
          debugPrint('インスタンス ${account.instanceUrl} の絵文字読み込みエラー: $e');
        }
      }

      // カテゴリ別グループ化。サーバー側の出現順を保つため LinkedHashMap で
      // 累積。未分類は null → '未分類' に振り、最後に並べる。
      final byCategory = <String, List<Emoji>>{};
      final uncategorized = <Emoji>[];
      for (final e in allEmojis) {
        final cat = e.category;
        if (cat == null) {
          uncategorized.add(e);
        } else {
          byCategory.putIfAbsent(cat, () => <Emoji>[]).add(e);
        }
      }
      if (uncategorized.isNotEmpty) {
        byCategory[l10n.emojiUncategorized] = uncategorized;
      }

      if (mounted) {
        setState(() {
          _allCustomEmojis = allEmojis;
          _filteredCustomEmojis = allEmojis;
          _customByCategory = byCategory;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('カスタム絵文字読み込みエラー: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _selectCustomEmoji(Emoji emoji) {
    widget.onEmojiSelected(':${emoji.shortcode}:');
  }

  /// カテゴリ別グループ化済みのカスタム絵文字を、ヘッダー + Wrap で
  /// 縦スクロール表示する。
  Widget _buildCustomEmojiCategorizedView() {
    if (_customByCategory.isEmpty) {
      return Center(
        child: Text(context.l10n.emojiNoCustom,
            style: const TextStyle(color: Colors.grey)),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        for (final entry in _customByCategory.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
            child: Row(
              children: [
                Text(
                  entry.key,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${entry.value.length}',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ),
          ),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final emoji in entry.value)
                SizedBox(
                  width: 48,
                  height: 48,
                  child: _buildCustomEmojiTile(emoji),
                ),
            ],
          ),
        ],
      ],
    );
  }

  /// カスタム絵文字の単一タイル。グリッド/Wrap どちらからも使う共通部品。
  Widget _buildCustomEmojiTile(Emoji emoji) {
    return InkWell(
      onTap: () => _selectCustomEmoji(emoji),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: emoji.isAnimated
                ? Colors.orange.shade300
                : Colors.grey.shade300,
            width: emoji.isAnimated ? 1.5 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Expanded(
              child: Stack(
                children: [
                  // Web では CORS 未対応インスタンスの絵文字 CDN でも表示できる
                  // よう KurageNetworkImage (HTML <img> フォールバック) を使う。
                  // 素の Image.network は CanvasKit decode で CORS に阻まれて
                  // 表示されない (本文中の絵文字と同じく html_parser のパターン)。
                  Positioned.fill(
                    child: KurageNetworkImage(
                      imageUrl: emoji.animatedUrl,
                      fit: BoxFit.contain,
                      placeholder: (context, url) => const Center(
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                      errorWidget: (context, url, error) =>
                          const Icon(Icons.broken_image, size: 20),
                    ),
                  ),
                  // アニメーションGIFの場合は再生アイコンを表示
                  if (emoji.isAnimated)
                    Positioned(
                      bottom: 2,
                      right: 2,
                      child: Container(
                        padding: const EdgeInsets.all(1),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: const Icon(
                          Icons.gif,
                          color: Colors.white,
                          size: 8,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Text(
              ':${emoji.shortcode}:',
              style: const TextStyle(fontSize: 8),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ],
        ),
      ),
    );
  }

  /// 統合検索: カスタム + 標準 を 1 つのスクロールビューで縦に並べる。
  /// 両方ヒット 0 件の時のみ「該当なし」を出す。
  Widget _buildUnifiedSearchResults() {
    final hasCustom = _filteredCustomEmojis.isNotEmpty;
    final hasStandard = _filteredStandardEmojis.isNotEmpty;
    if (!hasCustom && !hasStandard) {
      return Center(
        child: Text(
          context.l10n.emojiNoneFound,
          style: const TextStyle(color: Colors.grey),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        if (hasCustom) ...[
          _buildSectionHeader(
              context.l10n.emojiCustomSection, _filteredCustomEmojis.length),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final emoji in _filteredCustomEmojis)
                SizedBox(
                  width: 48,
                  height: 48,
                  child: _buildCustomEmojiTile(emoji),
                ),
            ],
          ),
        ],
        if (hasStandard) ...[
          _buildSectionHeader(context.l10n.emojiStandardSection,
              _filteredStandardEmojis.length),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final emoji in _filteredStandardEmojis)
                SizedBox(
                  width: 40,
                  height: 40,
                  child: InkWell(
                    onTap: () => widget.onEmojiSelected(emoji.emoji),
                    borderRadius: BorderRadius.circular(6),
                    child: Center(
                      child: Text(
                        emoji.emoji,
                        style: const TextStyle(fontSize: 26),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildSectionHeader(String label, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey[600],
            ),
          ),
        ],
      ),
    );
  }

  /// Unicode 全絵文字を網羅するため emoji_picker_flutter パッケージに委譲。
  /// パッケージ側が自前のカテゴリタブ (Recent / Smileys / Animals / Food /
  /// Travel / Activities / Objects / Symbols / Flags) + 検索 + Recent を提供。
  Widget _buildStandardEmojiView() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bg = theme.scaffoldBackgroundColor;
    final iconColor = theme.iconTheme.color ?? (isDark ? Colors.white70 : Colors.grey);
    // Dark の category bar は scaffoldBackgroundColor (= 黒) だと境界が消えるので
    // ワントーン浮かせた cardColor を使う。Light は従来通り scaffoldBackgroundColor。
    final categoryBg = isDark ? theme.cardColor : bg;

    return ep.EmojiPicker(
      onEmojiSelected: (category, emoji) {
        widget.onEmojiSelected(emoji.emoji);
      },
      config: ep.Config(
        // 親 (高さ 400 の Container) の利用可能領域にフィットさせる。
        height: double.infinity,
        checkPlatformCompatibility: true,
        // パッケージ側のカテゴリ名等をアプリの表示言語に追従させる
        locale: Localizations.localeOf(context),
        emojiViewConfig: ep.EmojiViewConfig(
          columns: 8,
          emojiSizeMax: 24,
          backgroundColor: bg,
          noRecents: Text(
            context.l10n.emojiNoRecent,
            style: TextStyle(fontSize: 14, color: iconColor),
            textAlign: TextAlign.center,
          ),
        ),
        categoryViewConfig: ep.CategoryViewConfig(
          initCategory: ep.Category.SMILEYS,
          iconColor: iconColor,
          iconColorSelected: theme.colorScheme.primary,
          indicatorColor: theme.colorScheme.primary,
          backgroundColor: categoryBg,
        ),
        bottomActionBarConfig: ep.BottomActionBarConfig(
          backgroundColor: categoryBg,
          buttonColor: categoryBg,
          buttonIconColor: iconColor,
          showBackspaceButton: false,
        ),
        searchViewConfig: ep.SearchViewConfig(
          backgroundColor: bg,
          buttonIconColor: iconColor,
          hintText: context.l10n.search,
          inputTextStyle: TextStyle(color: theme.textTheme.bodyMedium?.color),
        ),
        skinToneConfig: ep.SkinToneConfig(
          dialogBackgroundColor: theme.cardColor,
          indicatorColor: iconColor,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 400,
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        children: [
          // ハンドルバー
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: Colors.grey.shade400,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // 検索バー (カスタム絵文字専用。標準絵文字はパッケージ側の検索を使う)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: context.l10n.emojiSearchHint,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
            ),
          ),

          // 検索中はタブを隠してカスタム + 標準 をまとめて表示
          if (_searchQuery.isNotEmpty) ...[
            Expanded(child: _buildUnifiedSearchResults()),
          ] else ...[
            // タブバー
            TabBar(
              controller: _tabController,
              tabs: [
                Tab(
                    icon: const Icon(Icons.star),
                    text: context.l10n.emojiCustomTab),
                Tab(
                    icon: const Icon(Icons.emoji_emotions),
                    text: context.l10n.emojiStandardTab),
              ],
            ),

            // タブビュー
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : TabBarView(
                      controller: _tabController,
                      children: [
                        // カスタム絵文字タブ (カテゴリ別)
                        _buildCustomEmojiCategorizedView(),

                        // 標準絵文字タブ (Unicode 全絵文字)
                        _buildStandardEmojiView(),
                      ],
                    ),
            ),
          ],
        ],
      ),
    );
  }
}
