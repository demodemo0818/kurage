// lib/pages/thread_page.dart

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../l10n/l10n.dart';
import '../models/status_context.dart';
import '../models/status.dart';
import '../providers/auth_provider.dart';
import '../services/local_status_event_bus.dart';
import '../services/mastodon_api.dart';
import '../widgets/post_tile.dart';
import '../widgets/timeline_post_decoration.dart';
import '../providers/settings_provider.dart';

/// 返信ツリー（スレッド）を表示するページ
/// 引数に threadRootStatusId を受け取り、そのステータスの ancestors/descendants を取得する
class ThreadPage extends ConsumerWidget {
  final String threadRootStatusId;
  final String? sourceAccountId; // 複数アカウント対応用
  final dynamic originalStatus; // 元のステータスオブジェクト（URL情報取得用）

  /// 投稿元サーバを直接指定して開くときの instanceUrl。non-null の場合、
  /// アカウント解決をせず、この URL から認証なしでスレッドを取得する
  /// （現在のアカウントが保持していないリモート投稿を投稿元サーバで読むため）。
  final String? overrideInstanceUrl;

  /// Deck ポップアップで最初のページとして開かれた時だけ非 null。AppBar の
  /// 戻る (←) でポップアップ全体を閉じるのに使う。
  final VoidCallback? onDeckBack;

  const ThreadPage({
    super.key,
    required this.threadRootStatusId,
    this.sourceAccountId,
    this.originalStatus,
    this.onDeckBack,
    this.overrideInstanceUrl,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.read(authProvider);
    
    // デバッグ情報を出力
    debugPrint('ThreadPage: sourceAccountId = $sourceAccountId');
    debugPrint('ThreadPage: available accounts = ${auth.accounts.map((a) => '${a.id}:${a.displayName}').join(', ')}');
    
    // sourceAccountIdが指定されている場合は該当するアカウントを使用、
    // そうでなければ現在のアカウントを使用
    final acct = sourceAccountId != null
        ? auth.accounts.firstWhere(
            (account) => account.id == sourceAccountId,
            orElse: () {
              debugPrint('ThreadPage: sourceAccountId not found, falling back to first account');
              return auth.accounts.first;
            },
          )
        : auth.accounts.first;
    
    debugPrint('ThreadPage: using account = ${acct.id}:${acct.displayName} for instance ${acct.instanceUrl}');

    return Scaffold(
      appBar: AppBar(
        leading:
            onDeckBack == null ? null : BackButton(onPressed: onDeckBack),
        title: Text(context.l10n.threadTitle),
      ),
      body: FutureBuilder<StatusContext>(
        future: _fetchStatusContextFromCorrectAccount(auth, threadRootStatusId, sourceAccountId, originalStatus, overrideInstanceUrl),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          } else if (snapshot.hasError) {
            debugPrint('ThreadPage: Error fetching status context: ${snapshot.error}');
            debugPrint('ThreadPage: Stack trace: ${snapshot.stackTrace}');
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error, size: 64, color: Colors.red),
                  const SizedBox(height: 16),
                  Text(context.l10n.genericError('${snapshot.error}')),
                  const SizedBox(height: 8),
                  Text(context.l10n.threadAccountLabel(acct.displayName)),
                  Text(context.l10n.threadInstanceLabel(acct.instanceUrl)),
                  Text(context.l10n.threadStatusIdLabel(threadRootStatusId)),
                ],
              ),
            );
          } else if (!snapshot.hasData) {
            return Center(child: Text(context.l10n.threadNoData));
          }

          final contextData = snapshot.data!;
          // ancestors (先祖) は「一番古いものが先頭」、descendants (子孫) も「古い→新しい」です。
          // ここで「現在のステータス」を ancestors の最後以降に挿入する方法はいくつかありますが、
          // threadRootStatusId は「親スレッドのID」ではなく「タップしたステータスID」なので、そのまま取得済みの ancestors に含まれていません。
          // したがって、一度そのステータス単体を fetch してから allStatuses に挿入するか、もしくは
          // ancestors リストの中に threadRootStatusId があればそれを表示する、という方法があります。
          //
          // ここではシンプルに「先祖の最後に threadRoot の Status オブジェクト」を fetch して追加する実装例を示します。

          return _ThreadListView(
            ancestors: contextData.ancestors,
            currentStatusId: threadRootStatusId,
            descendants: contextData.descendants,
            sourceAccountId: sourceAccountId,
            overrideInstanceUrl: overrideInstanceUrl,
          );
        },
      ),
    );
  }
}

/// 実際に ListView で並べるウィジェットを分離
class _ThreadListView extends ConsumerStatefulWidget {
  final List<Status> ancestors;
  final String currentStatusId;
  final List<Status> descendants;
  final String? sourceAccountId;
  final String? overrideInstanceUrl;

  const _ThreadListView({
    required this.ancestors,
    required this.currentStatusId,
    required this.descendants,
    this.sourceAccountId,
    this.overrideInstanceUrl,
  });

  @override
  ConsumerState<_ThreadListView> createState() => _ThreadListViewState();
}

class _ThreadListViewState extends ConsumerState<_ThreadListView> {
  Status? _currentStatus;

  /// `widget.ancestors` / `widget.descendants` のローカル可変コピー。
  /// `local_status_event_bus` 経由で編集 / 削除を反映するため、配列自体を
  /// State 側で持ち変える必要がある。widget が再構築されて新しいリストが
  /// 流れてきたら `didUpdateWidget` で取り込む。
  late List<Status> _ancestors;
  late List<Status> _descendants;

  StreamSubscription<LocalStatusEvent>? _localStatusEventSub;

  @override
  void initState() {
    super.initState();
    _ancestors = List<Status>.from(widget.ancestors);
    _descendants = List<Status>.from(widget.descendants);
    _localStatusEventSub = localStatusEventStream.listen(_onLocalStatusEvent);
    // ancestors には currentStatus が含まれていないので、別途 fetch する
    _fetchCurrentStatus();
  }

  @override
  void didUpdateWidget(_ThreadListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.ancestors, widget.ancestors)) {
      _ancestors = List<Status>.from(widget.ancestors);
    }
    if (!identical(oldWidget.descendants, widget.descendants)) {
      _descendants = List<Status>.from(widget.descendants);
    }
  }

  @override
  void dispose() {
    _localStatusEventSub?.cancel();
    _localStatusEventSub = null;
    super.dispose();
  }

  /// スレッド内の status (ancestors / current / descendants) に自分の
  /// 編集 / 削除を反映する。操作元アカウントが `widget.sourceAccountId`
  /// (= スレッドを取得しているアカウント) と一致するときだけ処理する。
  /// sourceAccountId が null の場合は判定できないので念のため処理する。
  void _onLocalStatusEvent(LocalStatusEvent event) {
    if (!mounted) return;
    final src = widget.sourceAccountId;
    if (src != null && event.accountId != src) return;

    switch (event) {
      case LocalStatusDeleted():
        var changed = false;
        final beforeA = _ancestors.length;
        _ancestors.removeWhere((s) => s.id == event.statusId);
        if (_ancestors.length != beforeA) changed = true;
        final beforeD = _descendants.length;
        _descendants.removeWhere((s) => s.id == event.statusId);
        if (_descendants.length != beforeD) changed = true;
        if (_currentStatus?.id == event.statusId) {
          // スレッドルート自体を消した: ローダー表示に戻す (現実的にはこの
          // 直後にユーザーが戻るボタンを押す想定。pop まではしない)。
          _currentStatus = null;
          changed = true;
        }
        if (changed) setState(() {});

      case LocalStatusEdited():
        var changed = false;
        for (var i = 0; i < _ancestors.length; i++) {
          if (_ancestors[i].id == event.updated.id) {
            _ancestors[i] = event.updated;
            changed = true;
          }
        }
        for (var i = 0; i < _descendants.length; i++) {
          if (_descendants[i].id == event.updated.id) {
            _descendants[i] = event.updated;
            changed = true;
          }
        }
        if (_currentStatus?.id == event.updated.id) {
          _currentStatus = event.updated;
          changed = true;
        }
        if (changed) setState(() {});
    }
  }

  Future<void> _fetchCurrentStatus() async {
    final auth = ref.read(authProvider);
    
    try {
      // 同じ多重アカウント解決ロジックを使用してステータスを取得
      final single = await _fetchSingleStatusFromCorrectAccount(auth, widget.currentStatusId);
      setState(() {
        _currentStatus = single;
      });
    } catch (e) {
      debugPrint('currentStatus fetch error: $e');
    }
  }

  /// 単一ステータスを適切なアカウントから取得
  Future<Status> _fetchSingleStatusFromCorrectAccount(
    AuthState auth,
    String statusId,
  ) async {
    // 投稿元サーバ直接モード: 認証なしで取得する（公開投稿のみ）。
    final override = widget.overrideInstanceUrl;
    if (override != null) {
      final uri = Uri.parse('$override/api/v1/statuses/$statusId');
      final resp = await http.get(uri);
      if (resp.statusCode == 200) {
        return Status.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
      }
      throw Exception(l10n.threadRemoteFetchFailed('${resp.statusCode}'));
    }

    // まず指定されたアカウントで試行（存在する場合）
    final sourceAccountId = widget.sourceAccountId;
    
    if (sourceAccountId != null) {
      final account = auth.accounts.firstWhere(
        (a) => a.id == sourceAccountId,
        orElse: () => auth.accounts.first,
      );
      
      try {
        debugPrint('🔄 Fetching single status with specified account: ${account.displayName}');
        final uri = Uri.parse('${account.instanceUrl}/api/v1/statuses/$statusId');
        final resp = await http.get(
          uri,
          headers: {'Authorization': 'Bearer ${account.accessToken}'},
        );
        if (resp.statusCode == 200) {
          return Status.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
        } else {
          throw Exception('Status fetch failed: ${resp.statusCode}');
        }
      } catch (e) {
        debugPrint('❌ Failed to fetch single status with specified account: $e');
      }
    }
    
    // 他のアカウントで順番に試行
    for (final account in auth.accounts) {
      if (account.id == sourceAccountId) continue; // 既に試済み
      
      try {
        debugPrint('🔄 Fetching single status with fallback account: ${account.displayName}');
        final uri = Uri.parse('${account.instanceUrl}/api/v1/statuses/$statusId');
        final resp = await http.get(
          uri,
          headers: {'Authorization': 'Bearer ${account.accessToken}'},
        );
        if (resp.statusCode == 200) {
          return Status.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
        } else {
          throw Exception('Status fetch failed: ${resp.statusCode}');
        }
      } catch (e) {
        debugPrint('❌ Failed to fetch single status with ${account.displayName}: $e');
        continue;
      }
    }
    
    throw Exception('Single status $statusId could not be fetched from any account');
  }

  @override
  Widget build(BuildContext context) {
    // ancestors → current → descendants すべて揃っていれば表示
    final allItems = <Status>[
      ..._ancestors,
      if (_currentStatus != null) _currentStatus!,
      ..._descendants,
    ];

    if (_currentStatus == null) {
      // 現在のステータスをまだ取得中なのでプログレス表示
      return const Center(child: CircularProgressIndicator());
    }

    final layout = ref.watch(settingsProvider).timelineLayout;
    return ListView.separated(
      // 下端は Android のシステムナビゲーションバー (3 ボタン / ジェスチャ
      // バー) と被らないよう viewPadding.bottom 分を追加。edge-to-edge 表示時
      // に末尾の返信タイルがバー裏に隠れてアクションがしづらくなるのを防ぐ。
      padding: EdgeInsets.fromLTRB(
        0,
        8,
        0,
        8 + MediaQuery.paddingOf(context).bottom,
      ),
      itemCount: allItems.length,
      separatorBuilder: (_, _) => timelineSeparator(layout),
      itemBuilder: (context, index) {
        final s = allItems[index];
        // タイムライン本体と同じ UI を使いたいなら PostTile を流用しても OK
        return wrapForTimelineLayout(
          context,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 簡易的に「先祖・子孫かどうか」をわかりやすく色やラベルで付けたい場合は、ここに条件分岐を入れて装飾できます
                if (index == _ancestors.length)
                  Text(context.l10n.threadCurrentPost,
                      style: TextStyle(
                          color: Colors.blue.shade700, fontSize: 12)),

                const SizedBox(height: 4),
                // PostTile を流用。投稿元サーバ直接モードでは status.id が
                // そのサーバー上の ID であることを伝える (リアクション前に
                // ホーム側 ID へ解決させる)。
                PostTile(
                  status: s,
                  statusSourceInstanceUrl: widget.overrideInstanceUrl,
                ),
              ],
            ),
          ),
          layout,
        );
      },
    );
  }
}

/// 複数アカウントから適切なアカウントを使ってステータスコンテキストを取得
/// ProfilePageと同様の解決パターンを使用
Future<StatusContext> _fetchStatusContextFromCorrectAccount(
  AuthState auth,
  String statusId,
  String? sourceAccountId,
  dynamic originalStatus, [
  String? overrideInstanceUrl,
]) async {
  // 投稿元サーバ直接モード: アカウント解決をせず、認証なしで取得する
  // （fetchStatusContext の空トークン対応を利用）。
  if (overrideInstanceUrl != null) {
    return fetchStatusContext(
      instanceUrl: overrideInstanceUrl,
      accessToken: '',
      statusId: statusId,
    );
  }

  debugPrint('=== ThreadPage: Starting status context fetch ===');
  debugPrint('Status ID: $statusId');
  debugPrint('Source Account ID: $sourceAccountId');
  debugPrint('Available accounts: ${auth.accounts.map((a) => '${a.id}:${a.displayName}@${a.instanceUrl}').join(', ')}');
  
  // 指定されたアカウントがある場合は、そのアカウントを優先的に試す
  if (sourceAccountId != null) {
    final account = auth.accounts.firstWhere(
      (a) => a.id == sourceAccountId,
      orElse: () => auth.accounts.first,
    );
    
    try {
      debugPrint('🔄 Trying specified account: ${account.displayName}@${account.instanceUrl} for status $statusId');
      final result = await fetchStatusContext(
        instanceUrl: account.instanceUrl,
        accessToken: account.accessToken,
        statusId: statusId,
      );
      debugPrint('✅ Success with specified account: ${account.displayName}');
      return result;
    } catch (e) {
      if (e.toString().contains('404')) {
        debugPrint('❌ 404 Error: Status $statusId not found on ${account.displayName}@${account.instanceUrl}');
        debugPrint('   This suggests the status ID is not accessible from this instance');
      } else {
        debugPrint('❌ Failed with specified account ${account.displayName}@${account.instanceUrl}: $e');
      }
      // 指定されたアカウントで失敗した場合、ProfilePageと同様のフォールバック処理を実行
    }
  }
  
  // ProfilePageと同様のフォールバック戦略：元のインスタンスでの解決を最優先
  if (originalStatus != null) {
    debugPrint('🔄 Trying original instance resolution (ProfilePage pattern)...');
    
    try {
      // 元のステータスの作成者のacctから元のインスタンスを判定
      final authorAcct = originalStatus.account?.acct;
      String? originalInstance;
      
      debugPrint('🔍 Author acct: $authorAcct');
      
      if (authorAcct != null && authorAcct.contains('@')) {
        // リモートユーザーの場合：@username@instance.domain
        final parts = authorAcct.split('@');
        if (parts.length >= 2) {
          originalInstance = 'https://${parts.last}';
        }
      } else if (originalStatus.url != null || originalStatus.uri != null) {
        // URLまたはURIから元のインスタンスを抽出
        originalInstance = extractInstanceFromUrl(originalStatus.url ?? originalStatus.uri);
      } else if (sourceAccountId != null) {
        // ローカルユーザーの場合は、sourceアカウントのインスタンスを使用
        final sourceAccount = auth.accounts.firstWhere(
          (a) => a.id == sourceAccountId,
          orElse: () => auth.accounts.first,
        );
        originalInstance = sourceAccount.instanceUrl;
        debugPrint('🔍 Using source account instance for local user: $originalInstance');
      }
      
      debugPrint('🔍 Detected original instance: $originalInstance');
      
      if (originalInstance != null) {
        // 元のインスタンスと同じインスタンスのアカウントを探す
        final matchingAccounts = auth.accounts.where(
          (a) => a.instanceUrl == originalInstance,
        ).toList();
        
        if (matchingAccounts.isNotEmpty) {
          final matchingAccount = matchingAccounts.first;
          debugPrint('🎯 Found matching account for original instance: ${matchingAccount.displayName}');
          
          try {
            final result = await fetchStatusContext(
              instanceUrl: originalInstance,
              accessToken: matchingAccount.accessToken,
              statusId: statusId,
            );
            debugPrint('✅ Success with original instance resolution');
            return result;
          } catch (e) {
            debugPrint('❌ Failed on original instance: $e');
            // 元のインスタンスでも失敗した場合は、他のアカウントを試す
          }
        } else {
          debugPrint('❌ No account found for original instance $originalInstance');
        }
      }
    } catch (e) {
      debugPrint('❌ Original instance resolution failed: $e');
    }
  }
  
  // 他のアカウントで順番に試す（ProfilePageと同様）
  debugPrint('🔄 Trying all other accounts...');
  for (final account in auth.accounts) {
    if (account.id == sourceAccountId) {
      debugPrint('⏭️ Skipping already tried account: ${account.displayName}');
      continue; // 既に試済み
    }
    
    try {
      debugPrint('🔄 Trying fallback account: ${account.displayName}@${account.instanceUrl} for status $statusId');
      final result = await fetchStatusContext(
        instanceUrl: account.instanceUrl,
        accessToken: account.accessToken,
        statusId: statusId,
      );
      debugPrint('✅ Success with fallback account: ${account.displayName}');
      return result;
    } catch (e) {
      if (e.toString().contains('404')) {
        debugPrint('❌ 404 Error: Status $statusId not found on ${account.displayName}@${account.instanceUrl}');
      } else {
        debugPrint('❌ Failed with fallback account ${account.displayName}@${account.instanceUrl}: $e');
      }
      continue;
    }
  }
  
  // すべて失敗した場合
  debugPrint('💥 All resolution attempts failed for status $statusId');
  throw Exception(l10n.threadStatusNotFound(statusId));
}

/// URLからステータスIDを抽出
String? extractStatusIdFromUrl(String? url) {
  if (url == null) return null;
  final regex = RegExp(r'/statuses/(\d+)');
  final match = regex.firstMatch(url);
  return match?.group(1);
}

/// ステータスURLから元のインスタンスを抽出
String? extractInstanceFromUrl(String? url) {
  if (url == null) return null;
  try {
    final uri = Uri.parse(url);
    return '${uri.scheme}://${uri.host}';
  } catch (e) {
    return null;
  }
}
