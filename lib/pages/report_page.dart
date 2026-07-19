// lib/pages/report_page.dart
//
// 通報フォーム (`POST /api/v1/reports`)。
// post_tile のメニューから呼ばれる。投稿起点で開かれた場合は対象投稿が
// プリセットされ、必要なら「他の投稿も含める」セクションで同アカウントの
// 直近投稿を追加できる。「このアカウントだけ通報」のため、対象投稿は
// チェックを外して 0 件にすることも可能。
//
// カテゴリ:
//   - spam      迷惑行為 / なりすまし / 大量投稿
//   - violation 違反 (サーバルール選択あり)
//   - legal     法的問題 (DMCA など)
//   - other     その他
//
// 投稿者がリモートアカウントのときだけ「相手サーバへ転送 (forward)」
// チェックを表示する。

import '../widgets/network_image_x.dart';
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/account.dart';
import '../models/auth_account.dart';
import '../models/instance_rule.dart';
import '../models/status.dart';
import '../services/mastodon_api.dart';
import '../utils/html_parser.dart';
import '../utils/snackbar_helpers.dart';
import '../utils/time_formatter.dart';

class ReportPage extends StatefulWidget {
  /// 通報を実行するアカウント (= 自分のアクセストークンを使う側)
  final AuthAccount authAccount;

  /// 通報対象アカウント (Mastodon の必須パラメタ `account_id`)
  final Account targetAccount;

  /// 起点になった投稿 (任意)。null なら「アカウントのみ通報」モードで開く。
  final Status? sourceStatus;

  /// Deck ポップアップで最初のページとして開かれた時だけ非 null。AppBar の
  /// 戻る (←) でポップアップ全体を閉じるのに使う。
  final VoidCallback? onDeckBack;

  const ReportPage({
    super.key,
    required this.authAccount,
    required this.targetAccount,
    this.sourceStatus,
    this.onDeckBack,
  });

  @override
  State<ReportPage> createState() => _ReportPageState();
}

class _ReportPageState extends State<ReportPage> {
  final _commentController = TextEditingController();

  /// カテゴリ。Mastodon 既定値は 'other'。
  String _category = 'other';

  /// リモートサーバへの転送 (デフォルト OFF。リモートに送られて意図せず晒される
  /// ことを避けるため、ユーザーが意識して ON する仕様にする)
  bool _forward = false;

  /// 通報に含める status id のセット。起点投稿があれば初期に入れておく。
  final Set<String> _selectedStatusIds = <String>{};

  /// サーバルール (violation 選択時に出すチェックボックス用)
  List<InstanceRule> _rules = const [];
  bool _rulesLoading = true;
  final Set<String> _selectedRuleIds = <String>{};

  /// 「他の投稿も含める」を展開したか。展開された時点で投稿を 1 ページ fetch。
  bool _moreStatusesExpanded = false;
  bool _otherStatusesLoading = false;
  String? _otherStatusesError;
  List<Status> _otherStatuses = const [];

  bool _submitting = false;

  /// Mastodon 仕様: comment は 1000 字以内。超過分はサーバ側で truncate される
  /// が、UI 上もカウンタを出して気付けるようにする。
  static const int _commentMaxChars = 1000;

  @override
  void initState() {
    super.initState();
    if (widget.sourceStatus != null) {
      // ブースト経由で起点になった場合は元投稿の id を使う。
      // (Mastodon は status_ids にローカル id を要求する。リモートのオリジナル
      //  id ではないので注意。`widget.sourceStatus` は authAccount の視点で
      //  渡されてきている前提)
      final s = widget.sourceStatus!.reblog ?? widget.sourceStatus!;
      _selectedStatusIds.add(s.id);
    }
    _loadRules();
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _loadRules() async {
    try {
      final rules = await fetchInstanceRules(
        instanceUrl: widget.authAccount.instanceUrl,
        accessToken: widget.authAccount.accessToken,
      );
      if (!mounted) return;
      setState(() {
        _rules = rules;
        _rulesLoading = false;
      });
    } catch (_) {
      // 通報フォームをルールが取れないだけで止めたくないので空配列扱い。
      if (!mounted) return;
      setState(() {
        _rules = const [];
        _rulesLoading = false;
      });
    }
  }

  Future<void> _loadOtherStatuses() async {
    setState(() {
      _otherStatusesLoading = true;
      _otherStatusesError = null;
    });
    try {
      final statuses = await fetchAccountStatuses(
        instanceUrl: widget.authAccount.instanceUrl,
        accessToken: widget.authAccount.accessToken,
        accountId: widget.targetAccount.id,
        limit: 30,
      );
      if (!mounted) return;
      // 起点投稿は既にプリセット済みなのでリストから除外する。
      final sourceId = widget.sourceStatus != null
          ? (widget.sourceStatus!.reblog ?? widget.sourceStatus!).id
          : null;
      setState(() {
        _otherStatuses = statuses
            // ブーストはここでは候補から外す (通報できるのは元投稿のみ)。
            .where((s) => s.reblog == null && s.id != sourceId)
            .toList();
        _otherStatusesLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _otherStatusesError = '$e';
        _otherStatusesLoading = false;
      });
    }
  }

  /// 通報対象アカウントがリモートか (acct に @domain が含まれる)
  bool get _isRemote => widget.targetAccount.acct.contains('@');

  Future<void> _submit() async {
    if (_submitting) return;

    // 確認ダイアログ。誤発火防止のため明示的な確認をワンクッション挟む。
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final n = _selectedStatusIds.length;
        return AlertDialog(
          title: Text(ctx.l10n.reportSendTitle),
          content: Text(
            '${ctx.l10n.reportConfirmTarget(widget.targetAccount.acct)}'
            '\n\n${n > 0 ? ctx.l10n.reportConfirmWithPosts(n) : ctx.l10n.reportConfirmNoPosts}'
            '\n\n${ctx.l10n.reportConfirmProceed}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(ctx.l10n.cancel),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(ctx.l10n.reportAction),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;

    setState(() => _submitting = true);
    try {
      await submitReport(
        instanceUrl: widget.authAccount.instanceUrl,
        accessToken: widget.authAccount.accessToken,
        accountId: widget.targetAccount.id,
        statusIds: _selectedStatusIds.toList(),
        comment: _commentController.text.trim(),
        forward: _isRemote && _forward,
        category: _category,
        ruleIds: _category == 'violation'
            ? _selectedRuleIds.toList()
            : const <String>[],
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.reportSent)),
      );
      // Deck ポップアップの最初のページのときは Navigator.pop が効かない
      // (nested Navigator の唯一のルート) ので onDeckBack で閉じる。
      if (widget.onDeckBack != null) {
        widget.onDeckBack!();
      } else {
        Navigator.pop(context);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      showErrorSnackBar(context, context.l10n.reportSendFailed('$e'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canSubmit = !_submitting;

    return Scaffold(
      appBar: AppBar(
        leading: widget.onDeckBack == null
            ? null
            : BackButton(onPressed: widget.onDeckBack),
        title: Text(context.l10n.reportAction),
        actions: [
          TextButton(
            onPressed: canSubmit ? _submit : null,
            child: _submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(context.l10n.send),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          _buildTargetHeader(),
          const SizedBox(height: 16),
          _buildCategorySection(theme),
          if (_category == 'violation') ...[
            const SizedBox(height: 16),
            _buildRulesSection(theme),
          ],
          const SizedBox(height: 16),
          _buildIncludedStatusesSection(theme),
          const SizedBox(height: 16),
          _buildCommentSection(theme),
          if (_isRemote) ...[
            const SizedBox(height: 8),
            _buildForwardSection(theme),
          ],
          const SizedBox(height: 24),
          // 注意書き。通報先 (自インスタンス管理者) を明示しておく。
          Text(
            '${context.l10n.reportModeratorNotice(Uri.parse(widget.authAccount.instanceUrl).host)}'
            '${_isRemote && _forward ? '\n${context.l10n.reportForwardNotice(widget.targetAccount.acct.split('@').last)}' : ''}',
            style: TextStyle(fontSize: 12, color: theme.hintColor),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildTargetHeader() {
    final t = widget.targetAccount;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            KurageCircleAvatar(
              imageUrl: t.avatar,
              radius: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.displayNameOrUsername,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '@${t.acct}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).hintColor,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategorySection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(context.l10n.reportReasonSection),
        RadioGroup<String>(
          groupValue: _category,
          onChanged: (v) {
            if (v == null) return;
            setState(() {
              _category = v;
              // violation を抜けたら選択を捨てる (送信側でも参照しない設計だが、
              // UI としても誤解を招かないようクリア)。
              if (v != 'violation') _selectedRuleIds.clear();
            });
          },
          child: Column(
            children: [
              _categoryRadio('spam', context.l10n.reportCategorySpam,
                  context.l10n.reportCategorySpamDesc),
              _categoryRadio('violation', context.l10n.reportCategoryViolation,
                  context.l10n.reportCategoryViolationDesc),
              _categoryRadio('legal', context.l10n.reportCategoryLegal,
                  context.l10n.reportCategoryLegalDesc),
              _categoryRadio('other', context.l10n.reportCategoryOther,
                  context.l10n.reportCategoryOtherDesc),
            ],
          ),
        ),
      ],
    );
  }

  Widget _categoryRadio(String value, String title, String? subtitle) {
    return RadioListTile<String>(
      value: value,
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle) : null,
      contentPadding: EdgeInsets.zero,
      dense: true,
    );
  }

  Widget _buildRulesSection(ThemeData theme) {
    if (_rulesLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(),
      );
    }
    if (_rules.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          context.l10n.reportNoRulesPublished,
          style: TextStyle(color: theme.hintColor),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(context.l10n.reportViolatedRules),
        for (final r in _rules)
          CheckboxListTile(
            value: _selectedRuleIds.contains(r.id),
            title: Text(r.text),
            subtitle: (r.hint != null && r.hint!.isNotEmpty)
                ? Text(r.hint!)
                : null,
            onChanged: (v) {
              setState(() {
                if (v == true) {
                  _selectedRuleIds.add(r.id);
                } else {
                  _selectedRuleIds.remove(r.id);
                }
              });
            },
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            dense: true,
          ),
      ],
    );
  }

  Widget _buildIncludedStatusesSection(ThemeData theme) {
    final source = widget.sourceStatus != null
        ? (widget.sourceStatus!.reblog ?? widget.sourceStatus!)
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(
            context.l10n.reportIncludedPosts(_selectedStatusIds.length)),
        if (source != null) _statusCheckTile(source, isSource: true),
        // 「他の投稿も含める」を tap で展開 → fetch
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: OutlinedButton.icon(
            icon: Icon(_moreStatusesExpanded
                ? Icons.expand_less
                : Icons.expand_more),
            label: Text(_moreStatusesExpanded
                ? context.l10n.reportCollapseOtherPosts
                : context.l10n.reportExpandOtherPosts),
            onPressed: () {
              setState(() => _moreStatusesExpanded = !_moreStatusesExpanded);
              if (_moreStatusesExpanded &&
                  _otherStatuses.isEmpty &&
                  !_otherStatusesLoading) {
                _loadOtherStatuses();
              }
            },
          ),
        ),
        if (_moreStatusesExpanded) _buildOtherStatusesPicker(theme),
      ],
    );
  }

  Widget _buildOtherStatusesPicker(ThemeData theme) {
    if (_otherStatusesLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_otherStatusesError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.reportPostsFetchFailed,
              style: TextStyle(color: theme.colorScheme.error),
            ),
            const SizedBox(height: 4),
            TextButton.icon(
              icon: const Icon(Icons.refresh),
              label: Text(context.l10n.retry),
              onPressed: _loadOtherStatuses,
            ),
          ],
        ),
      );
    }
    if (_otherStatuses.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          context.l10n.reportNoMorePosts,
          style: TextStyle(color: theme.hintColor),
        ),
      );
    }
    return Column(
      children: [
        for (final s in _otherStatuses) _statusCheckTile(s, isSource: false),
      ],
    );
  }

  /// 投稿 1 件を ListTile + Checkbox で並べる。`isSource` のときは「投稿起点で
  /// 開かれた = 既にプリセット済み」のラベルを付ける。両方ともチェック外しが
  /// 可能 (アカウントだけ通報も可、というユーザー要望に合わせる)。
  Widget _statusCheckTile(Status s, {required bool isSource}) {
    final selected = _selectedStatusIds.contains(s.id);
    final preview = parseHtmlToPlainText(s.content)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return CheckboxListTile(
      value: selected,
      onChanged: (v) {
        setState(() {
          if (v == true) {
            _selectedStatusIds.add(s.id);
          } else {
            _selectedStatusIds.remove(s.id);
          }
        });
      },
      title: Text(
        preview.isNotEmpty
            ? preview
            : (s.spoilerText.isNotEmpty
                ? 'CW: ${s.spoilerText}'
                : (s.mediaAttachments.isNotEmpty
                    ? context.l10n
                        .reportMediaOnlyCount(s.mediaAttachments.length)
                    : context.l10n.reportNoBody)),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${formatRelative(s.createdAt)}${isSource ? ' ・ ${context.l10n.reportSourcePost}' : ''}',
        style: const TextStyle(fontSize: 11),
      ),
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: EdgeInsets.zero,
      dense: true,
    );
  }

  Widget _buildCommentSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(context.l10n.reportCommentSection),
        TextField(
          controller: _commentController,
          minLines: 3,
          maxLines: 6,
          maxLength: _commentMaxChars,
          decoration: InputDecoration(
            hintText: context.l10n.reportCommentHint,
            border: const OutlineInputBorder(),
          ),
        ),
      ],
    );
  }

  Widget _buildForwardSection(ThemeData theme) {
    final domain = widget.targetAccount.acct.split('@').last;
    return SwitchListTile(
      value: _forward,
      onChanged: (v) => setState(() => _forward = v),
      title: Text(context.l10n.reportForwardTitle),
      subtitle: Text(context.l10n.reportForwardSubtitle(domain)),
      contentPadding: EdgeInsets.zero,
      dense: true,
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
