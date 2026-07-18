// lib/pages/column_settings_page.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_provider.dart';
import '../providers/column_provider.dart';
import '../providers/settings_provider.dart';
import '../services/mastodon_api.dart';
import '../models/mastodon_list.dart';
import '../utils/breakpoints.dart';
import '../widgets/user_avatar.dart';

/// カラム設定ページ：操作すると即保存＋反映
class ColumnSettingsPage extends ConsumerStatefulWidget {
  /// Deck (ワイド) のポップアップで開かれた時に渡される戻る (←) コールバック。
  /// null (ナロー/通常 push) のときは AppBar に通常の戻る矢印を出す。
  final VoidCallback? onDeckBack;

  const ColumnSettingsPage({super.key, this.onDeckBack});

  @override
  ConsumerState<ColumnSettingsPage> createState() => _ColumnSettingsPageState();
}

class _ColumnSettingsPageState extends ConsumerState<ColumnSettingsPage> {
  static const _baseTimelineTypes = ['home', 'local', 'federated', 'favourites', 'bookmarks'];
  
  static const _timelineTypeLabels = {
    'home': 'ホーム',
    'local': 'ローカル',
    'federated': '連合',
    'favourites': 'お気に入り',
    'bookmarks': 'ブックマーク',
  };
  
  static const _timelineTypeIcons = {
    'home': Icons.home,
    'local': Icons.people,
    'federated': Icons.public,
    'favourites': Icons.star,
    'bookmarks': Icons.bookmark,
    'lists': Icons.list,
  };

  /// 非時系列タイムライン (= 取得結果が status の created_at では並んで
  /// いない種別)。これらと時系列 (home/local/federated/list/hashtag) を
  /// 同じカラムに混ぜると merge 後の並びが意味を成さないため、UI 側で
  /// 混在不可にする。
  static bool _isNonChronological(String type) {
    return type == 'favourites' || type == 'bookmarks';
  }

  /// 候補タイプ [candidate] が、同カラム内の他ソース ([sources] の中で
  /// index != [currentIndex] のもの) と同じ「時系列カテゴリ」かどうか。
  /// 違っていたら ([候補] と他の組み合わせが) ミックス不可なので false。
  static bool _isCompatibleWithSiblings(
    String candidate,
    List sources,
    int currentIndex,
  ) {
    final candidateNonChrono = _isNonChronological(candidate);
    for (var k = 0; k < sources.length; k++) {
      if (k == currentIndex) continue;
      final other = sources[k]['timelineType'] as String? ?? 'home';
      if (_isNonChronological(other) != candidateNonChrono) {
        return false;
      }
    }
    return true;
  }

  /// 新規追加ソースのデフォルトタイプ。既存ソースの「時系列カテゴリ」に
  /// 合わせる (fav しか無いカラムに 'home' を足してミックス禁止
  /// 状態にしないため)。
  static String _defaultTimelineTypeFor(List sources) {
    if (sources.isEmpty) return 'home';
    final firstNonChrono = sources.any(
      (s) => _isNonChronological((s['timelineType'] as String?) ?? ''),
    );
    return firstNonChrono ? 'favourites' : 'home';
  }

  /// 同カラム内に同じ (accountId, timelineType) のソースが既にあるか
  /// (自分自身 [currentIndex] は除外)。重複登録防止用。
  static bool _isDuplicateOf(
    String? accountId,
    String timelineType,
    List sources,
    int currentIndex,
  ) {
    for (var k = 0; k < sources.length; k++) {
      if (k == currentIndex) continue;
      final s = sources[k];
      if (s['accountId'] == accountId &&
          s['timelineType'] == timelineType) {
        return true;
      }
    }
    return false;
  }

  final Map<String, List<MastodonList>> _accountLists = {};
  
  Future<List<String>> _getAvailableTimelineTypes(String? accountId) async {
    final List<String> types = List.from(_baseTimelineTypes);
    
    if (accountId != null) {
      try {
        final accounts = ref.read(authProvider).accounts;
        if (accounts.isEmpty) return types;
        
        final account = accounts.firstWhere(
          (a) => a.id == accountId,
          orElse: () => accounts.first,
        );
        
        if (!_accountLists.containsKey(accountId)) {
          final lists = await fetchLists(
            instanceUrl: account.instanceUrl,
            accessToken: account.accessToken,
          );
          _accountLists[accountId] = lists;
        }
        
        final lists = _accountLists[accountId] ?? [];
        for (final list in lists) {
          types.add('list_${list.id}');
        }
      } catch (e) {
        debugPrint('リスト取得エラー: $e');
      }
    }
    
    return types;
  }
  
  String _getTimelineTypeLabel(String type) {
    if (type.startsWith('list_')) {
      final listId = type.substring(5);
      for (final lists in _accountLists.values) {
        for (final list in lists) {
          if (list.id == listId) {
            return list.title;
          }
        }
      }
      return 'リスト';
    }
    return _timelineTypeLabels[type] ?? type;
  }
  
  IconData _getTimelineTypeIcon(String type) {
    if (type.startsWith('list_')) {
      return Icons.list;
    }
    return _timelineTypeIcons[type] ?? Icons.timeline;
  }

  /// カラムカード共通の「上へ / 下へ / 削除」操作ボタン群。
  /// カラム名の変更ダイアログ。空文字で保存するとカラム名なし (= ソースの
  /// 種別ラベル表示) に戻る。
  Future<void> _renameColumn(
      List<Map<String, dynamic>> columns, int index) async {
    final currentTitle = (columns[index]['title'] as String?) ?? '';
    final controller = TextEditingController(text: currentTitle);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('カラム名を変更'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 30,
          decoration: const InputDecoration(
            hintText: '例: 趣味アカまとめ',
            helperText: '空にするとタイムライン種別を表示します',
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    // ダイアログ閉鎖直後の同期 dispose は clearComposing との競合で例外に
    // なるため 1 frame 遅らせる (CLAUDE.md のダイアログ controller パターン)。
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (result == null) return;

    final newCols = List<Map<String, dynamic>>.from(columns);
    // in-place 変更せず新しい Map に差し替える (didUpdateWidget の差分検知用)
    newCols[index] = {...newCols[index], 'title': result.trim()};
    ref.read(columnProvider.notifier).save(newCols);
  }

  Widget _columnReorderButtons(List<Map<String, dynamic>> columns, int i) {
    final notifier = ref.read(columnProvider.notifier);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.arrow_upward),
          onPressed: i > 0
              ? () {
                  final newCols = List<Map<String, dynamic>>.from(columns);
                  final c = newCols.removeAt(i);
                  newCols.insert(i - 1, c);
                  notifier.save(newCols);
                }
              : null,
        ),
        IconButton(
          icon: const Icon(Icons.arrow_downward),
          onPressed: i < columns.length - 1
              ? () {
                  final newCols = List<Map<String, dynamic>>.from(columns);
                  final c = newCols.removeAt(i);
                  newCols.insert(i + 1, c);
                  notifier.save(newCols);
                }
              : null,
        ),
        IconButton(
          icon: const Icon(Icons.delete),
          onPressed: () {
            final newCols = List<Map<String, dynamic>>.from(columns)
              ..removeAt(i);
            notifier.save(newCols);
          },
        ),
      ],
    );
  }

  /// 固定幅モード時に各カラムの幅 (px) を調整するスライダー。
  /// 値は `column['width']` に保存する。
  Widget _buildColumnWidthSlider(List<Map<String, dynamic>> columns, int i) {
    final notifier = ref.read(columnProvider.notifier);
    final width =
        columnFixedWidth(columns[i]).clamp(kColumnMinWidth, kColumnMaxWidth);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
      child: Row(
        children: [
          const Icon(Icons.swap_horiz, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Slider(
              min: kColumnMinWidth,
              max: kColumnMaxWidth,
              // 10px 刻み。divisions を入れることでドラッグ中の保存回数も
              // (= onChanged 発火回数) ステップ数に抑えられる。
              divisions: ((kColumnMaxWidth - kColumnMinWidth) / 10).round(),
              value: width,
              label: '${width.round()}px',
              onChanged: (v) {
                final newCols = List<Map<String, dynamic>>.from(columns);
                newCols[i] = {...newCols[i], 'width': v};
                notifier.save(newCols);
              },
            ),
          ),
          SizedBox(
            width: 52,
            child: Text(
              '${width.round()}px',
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // これだけ見れば常に最新の設定が取れる
    final columns = ref.watch(columnProvider);
    final columnWidthMode =
        ref.watch(settingsProvider.select((s) => s.columnWidthMode));
    final accounts = ref.watch(authProvider).accounts;
    final defaultAccountId = accounts.isNotEmpty ? accounts.first.id : null;
    final notifier = ref.read(columnProvider.notifier);

    void save(List<Map<String, dynamic>> updated) {
      notifier.save(updated);
    }

    // 削除されたアカウントのチェックと自動修正
    WidgetsBinding.instance.addPostFrameCallback((_) {
      bool needsUpdate = false;
      final updatedColumns = List<Map<String, dynamic>>.from(columns);
      
      for (var i = 0; i < updatedColumns.length; i++) {
        final sources = List<Map<String, dynamic>>.from(updatedColumns[i]['sources']);
        for (var j = 0; j < sources.length; j++) {
          final accountId = sources[j]['accountId'] as String?;
          if (accountId != null && !accounts.any((a) => a.id == accountId)) {
            // 削除されたアカウントの場合、デフォルトアカウントに変更
            sources[j]['accountId'] = defaultAccountId;
            needsUpdate = true;
          }
        }
        if (needsUpdate) {
          updatedColumns[i] = {
            ...updatedColumns[i],
            'sources': sources,
          };
        }
      }
      
      if (needsUpdate) {
        save(updatedColumns);
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('カラム設定'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: widget.onDeckBack ?? () => Navigator.pop(context),
        ),
      ),
      body: accounts.isEmpty 
        ? const Center(
            child: Text('アカウントを追加してください'),
          )
        : ListView(
        children: [
          // ===== カラム幅モード (デスクトップ/Deck のみ有効) =====
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                const Icon(Icons.view_week, size: 20),
                const SizedBox(width: 8),
                const Text('カラム幅'),
                const Spacer(),
                SegmentedButton<ColumnWidthMode>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: ColumnWidthMode.flexible,
                      label: Text('可変'),
                    ),
                    ButtonSegment(
                      value: ColumnWidthMode.fixed,
                      label: Text('固定'),
                    ),
                  ],
                  selected: {columnWidthMode},
                  onSelectionChanged: (s) => ref
                      .read(settingsProvider.notifier)
                      .setColumnWidthMode(s.first),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text(
              columnWidthMode == ColumnWidthMode.fixed
                  ? 'デスクトップ表示のみ有効。各カラムを指定幅で左寄せ表示します。'
                  : 'デスクトップ表示のみ有効。ウィンドウ幅に合わせて自動調整します。',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const Divider(height: 8),

          // 各カラムカード
          for (var i = 0; i < columns.length; i++) ...[
            // 通知カラムはソース編集 UI を持たない特殊カラムなので、
            // 並べ替え/削除だけのシンプルなカードで表示する。
            if (isNotificationColumn(columns[i]))
              Card(
                margin: const EdgeInsets.all(8),
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.notifications),
                      title: const Text('通知'),
                      subtitle: const Text('通知タブと同じ内容を表示します'),
                      trailing: _columnReorderButtons(columns, i),
                    ),
                    if (columnWidthMode == ColumnWidthMode.fixed)
                      _buildColumnWidthSlider(columns, i),
                  ],
                ),
              )
            else
            Card(
              margin: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // タイトル行
                  ListTile(
                    title: Row(
                      children: [
                        for (var source in columns[i]['sources']) ...[
                          Icon(
                            _getTimelineTypeIcon(source['timelineType'] as String),
                            size: 20,
                            color: () {
                              if (accounts.isEmpty) return null;
                              final accountId = source['accountId'] as String?;
                              final account = accounts.firstWhere(
                                (a) => a.id == accountId,
                                orElse: () => accounts.first,
                              );
                              return account.accountColor;
                            }(),
                          ),
                          const SizedBox(width: 4),
                        ],
                        if (((columns[i]['title'] as String?) ?? '')
                            .isNotEmpty) ...[
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              columns[i]['title'] as String,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                        ],
                      ],
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.drive_file_rename_outline),
                          tooltip: 'カラム名を変更',
                          onPressed: () => _renameColumn(columns, i),
                        ),
                        _columnReorderButtons(columns, i),
                      ],
                    ),
                  ),

                  // ソース一覧
                  for (var j = 0; j < (columns[i]['sources'] as List).length; j++) ...[
                    ListTile(
                      title: Row(
                        children: [
                          // アカウント選択
                          Expanded(
                            child: Builder(builder: (context) {
                              final currentType = columns[i]['sources'][j]
                                      ['timelineType'] as String? ??
                                  'home';
                              final currentId = columns[i]['sources'][j]
                                  ['accountId'] as String?;
                              // 「(候補アカウント, 現在のタイプ)」が他ソースで
                              // 使われていたら候補から外す (重複登録防止)。
                              // 現在のアカウントは常に残す (レガシー重複時の
                              // Dropdown 空対策)。
                              final filteredAccounts = accounts.where((a) {
                                if (a.id == currentId) return true;
                                return !_isDuplicateOf(
                                  a.id,
                                  currentType,
                                  columns[i]['sources'] as List,
                                  j,
                                );
                              }).toList();
                              final hasCurrent = currentId != null &&
                                  filteredAccounts.any((a) => a.id == currentId);
                              return DropdownButton<String>(
                              isExpanded: true,
                              value: hasCurrent
                                  ? currentId
                                  : (filteredAccounts.isNotEmpty
                                      ? filteredAccounts.first.id
                                      : defaultAccountId),
                              hint: const Text('アカウントを選択'),
                              items: filteredAccounts
                                  .map((a) => DropdownMenuItem(
                                    value: a.id,
                                    child: Row(
                                      children: [
                                        Stack(
                                          children: [
                                            UserAvatar(
                                              url: a.avatarUrl,
                                              radius: 16,
                                            ),
                                            if (a.accountColor != null)
                                              Positioned(
                                                right: 0,
                                                bottom: 0,
                                                child: Container(
                                                  width: 12,
                                                  height: 12,
                                                  decoration: BoxDecoration(
                                                    color: a.accountColor,
                                                    shape: BoxShape.circle,
                                                    border: Border.all(
                                                      color: Colors.white,
                                                      width: 1,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            a.displayName,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ))
                                  .toList(),
                              onChanged: (v) {
                                if (v == null) return;
                                final newCols = List<Map<String, dynamic>>.from(columns);
                                final srcs = List<Map<String, dynamic>>.from(newCols[i]['sources']);
                                // List.from は浅いコピーなので srcs[j] は古い
                                // カラムが参照する Map と同一。in-place 変更すると
                                // oldWidget.column も書き換わり、timeline_view の
                                // didUpdateWidget が変更を検知できず反映されない。
                                // 新しい Map に差し替える。
                                srcs[j] = {...srcs[j], 'accountId': v};
                                newCols[i] = {
                                  ...newCols[i],
                                  'sources': srcs,
                                };
                                save(newCols);
                              },
                            );
                            }),
                          ),
                          const SizedBox(width: 8),
                          // タイムライン種別選択
                          FutureBuilder<List<String>>(
                            future: _getAvailableTimelineTypes(columns[i]['sources'][j]['accountId'] as String?),
                            builder: (context, snapshot) {
                              if (snapshot.connectionState == ConnectionState.waiting) {
                                return const SizedBox(
                                  width: 100,
                                  child: LinearProgressIndicator(),
                                );
                              }
                              
                              final rawTypes = snapshot.data ?? _baseTimelineTypes;
                              final currentAccount = columns[i]['sources'][j]
                                  ['accountId'] as String?;
                              final currentType = columns[i]['sources'][j]
                                  ['timelineType'] as String;
                              // 候補タイプの条件:
                              //   1) 時系列/非時系列カテゴリが他ソースと揃う
                              //      (fav/bookmark と home/local/list の混在禁止)
                              //   2) (現アカウント, 候補タイプ) が他ソースに
                              //      無い (同じ組み合わせの重複登録防止)
                              // ただし「現在値」は常に残す。レガシーで既に
                              // 重複しているデータでも Dropdown が空になって
                              // クラッシュしないように。
                              final availableTypes = rawTypes.where((t) {
                                if (t == currentType) return true;
                                if (!_isCompatibleWithSiblings(
                                  t,
                                  columns[i]['sources'] as List,
                                  j,
                                )) {
                                  return false;
                                }
                                if (_isDuplicateOf(
                                  currentAccount,
                                  t,
                                  columns[i]['sources'] as List,
                                  j,
                                )) {
                                  return false;
                                }
                                return true;
                              }).toList();

                              return DropdownButton<String>(
                                value: availableTypes.contains(currentType) ? currentType : availableTypes.first,
                                items: availableTypes
                                    .map((t) => DropdownMenuItem(
                                      value: t,
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(_getTimelineTypeIcon(t), size: 16),
                                          const SizedBox(width: 4),
                                          Text(_getTimelineTypeLabel(t)),
                                        ],
                                      ),
                                    ))
                                    .toList(),
                                onChanged: (v) {
                                  if (v == null) return;
                                  final newCols = List<Map<String, dynamic>>.from(columns);
                                  final srcs = List<Map<String, dynamic>>.from(newCols[i]['sources']);
                                  // 浅いコピーの srcs[j] を in-place 変更すると
                                  // 古いカラムの Map も書き換わり didUpdateWidget が
                                  // 変更を検知できない (ローカルに変えてもホームの
                                  // ままになる)。新しい Map に差し替える。
                                  srcs[j] = {...srcs[j], 'timelineType': v};
                                  newCols[i] = {
                                    ...newCols[i],
                                    'sources': srcs,
                                  };
                                  save(newCols);
                                },
                              );
                            },
                          ),
                        ],
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete),
                        onPressed: () {
                          final newCols = List<Map<String, dynamic>>.from(columns);
                          final srcs = List<Map<String, dynamic>>.from(newCols[i]['sources'])..removeAt(j);
                          newCols[i] = {
                            ...newCols[i],
                            'sources': srcs,
                          };
                          save(newCols);
                        },
                      ),
                    ),
                  ],

                  // ソース追加ボタン
                  Align(
                    alignment: Alignment.centerRight,
                    child: Builder(builder: (context) {
                      final existingSrcs =
                          columns[i]['sources'] as List;
                      // 重複しない (accountId, baseType) を探す。優先順:
                      //   1) (defaultAccountId, _defaultTimelineTypeFor)
                      //   2) defaultAccountId × 他の base types
                      //   3) 他アカウント × base types
                      // _baseTimelineTypes に絞っているのは、アカウント別の
                      // list_* タイプを起動時に網羅できないため。
                      final defaultType =
                          _defaultTimelineTypeFor(existingSrcs);
                      String? pickedAccount;
                      String? pickedType;
                      bool exists(String aid, String t) {
                        return existingSrcs.any((s) =>
                            s['accountId'] == aid &&
                            s['timelineType'] == t);
                      }
                      bool tryPick(String aid, String t) {
                        if (!_isCompatibleWithSiblings(t, existingSrcs, -1)) {
                          return false;
                        }
                        if (exists(aid, t)) return false;
                        pickedAccount = aid;
                        pickedType = t;
                        return true;
                      }
                      // 優先: defaultAccount + defaultType
                      if (defaultAccountId != null) {
                        tryPick(defaultAccountId, defaultType);
                      }
                      // それで埋まっていたら defaultAccount × 他タイプ
                      if (pickedAccount == null &&
                          defaultAccountId != null) {
                        for (final t in _baseTimelineTypes) {
                          if (tryPick(defaultAccountId, t)) break;
                        }
                      }
                      // それでも無ければ他アカウント × base types
                      if (pickedAccount == null) {
                        outer:
                        for (final a in accounts) {
                          for (final t in _baseTimelineTypes) {
                            if (tryPick(a.id, t)) break outer;
                          }
                        }
                      }

                      final acctToAdd = pickedAccount;
                      final typeToAdd = pickedType;
                      final canAdd = acctToAdd != null && typeToAdd != null;
                      return TextButton(
                        onPressed: canAdd
                            ? () {
                                final newCols =
                                    List<Map<String, dynamic>>.from(columns);
                                final srcs =
                                    List<Map<String, dynamic>>.from(
                                        newCols[i]['sources'])
                                      ..add({
                                        'accountId': acctToAdd,
                                        'timelineType': typeToAdd,
                                      });
                                newCols[i] = {
                                  ...newCols[i],
                                  'sources': srcs,
                                };
                                save(newCols);
                              }
                            : null,
                        child: Text(canAdd
                            ? '+ ソースを追加'
                            : '+ ソースを追加 (空きなし)'),
                      );
                    }),
                  ),

                  // 固定幅モード時のカラム幅スライダー
                  if (columnWidthMode == ColumnWidthMode.fixed)
                    _buildColumnWidthSlider(columns, i),
                ],
              ),
            ),
          ],

          // カラム追加
          Padding(
            padding: const EdgeInsets.all(8),
            child: ElevatedButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('カラムを追加'),
              onPressed: () {
                final newCols = List<Map<String, dynamic>>.from(columns)
                  ..add({
                    'title': '',
                    'sources': [
                      {
                        'accountId': defaultAccountId,
                        'timelineType': _baseTimelineTypes.first,
                      }
                    ],
                  });
                save(newCols);
              },
            ),
          ),

          // 通知カラム追加。タイムラインではなく通知一覧を表示する特殊カラム
          // (内容は通知タブと共有)。1 つだけにしておく (複数あっても同じ内容)。
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.notifications),
              label: const Text('通知カラムを追加'),
              onPressed: columns.any(isNotificationColumn)
                  ? null
                  : () {
                      final newCols =
                          List<Map<String, dynamic>>.from(columns)
                            ..add(buildNotificationColumn(defaultAccountId));
                      save(newCols);
                    },
            ),
          ),
        ],
      ),
    );
  }
}
