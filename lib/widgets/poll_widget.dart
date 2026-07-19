// lib/widgets/poll_widget.dart

import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../models/poll.dart';
import '../services/mastodon_api.dart' as api;

class PollWidget extends StatefulWidget {
  final Poll poll;
  final String instanceUrl;
  final String accessToken;
  final VoidCallback? onVoteChanged;

  /// true なら投票ボタンを無効化する (閲覧専用)。
  ///
  /// リモートビュー (相手サーバーから匿名取得した投稿) では poll.id が
  /// 相手サーバー上の ID のため、ホームサーバーへの投票 API に渡せない
  /// (status と違い、URL 検索でホーム側 poll.id へ解決する手段も無い)。
  final bool readOnly;

  const PollWidget({
    super.key,
    required this.poll,
    required this.instanceUrl,
    required this.accessToken,
    this.onVoteChanged,
    this.readOnly = false,
  });

  @override
  State<PollWidget> createState() => _PollWidgetState();
}

class _PollWidgetState extends State<PollWidget> {
  late Poll _poll;
  bool _isVoting = false;
  Set<int> _selectedOptions = {};

  @override
  void initState() {
    super.initState();
    _poll = widget.poll;
    // 既に投票している場合は選択肢を設定
    if (_poll.ownVotes != null) {
      _selectedOptions = Set<int>.from(_poll.ownVotes!);
    }
  }

  Future<void> _vote() async {
    if (widget.readOnly || _selectedOptions.isEmpty || _isVoting) return;

    setState(() => _isVoting = true);

    try {
      await api.votePoll(
        instanceUrl: widget.instanceUrl,
        accessToken: widget.accessToken,
        pollId: _poll.id,
        choices: _selectedOptions.toList(),
      );

      // 投票後は結果を更新
      final updatedPoll = await api.fetchPoll(
        instanceUrl: widget.instanceUrl,
        accessToken: widget.accessToken,
        pollId: _poll.id,
      );

      setState(() {
        _poll = updatedPoll;
      });

      widget.onVoteChanged?.call();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.pollVoteFailed('$e'))),
        );
      }
    } finally {
      setState(() => _isVoting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalVotes = _poll.votesCount ?? _poll.votersCount;
    final hasVoted = _poll.voted ?? false;
    final isExpired = _poll.expired;
    final showResults = hasVoted || isExpired;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: RadioGroup<int>(
        groupValue: _selectedOptions.isNotEmpty ? _selectedOptions.first : null,
        onChanged: (int? value) {
          setState(() {
            _selectedOptions.clear();
            if (value != null) {
              _selectedOptions.add(value);
            }
          });
        },
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 投票選択肢
          ...List.generate(_poll.options.length, (index) {
            final option = _poll.options[index];
            final percentage = totalVotes > 0 && option.votesCount != null
                ? (option.votesCount! / totalVotes * 100)
                : 0.0;

            if (showResults) {
              // 結果表示
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            option.title,
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                        ),
                        Text(
                          '${percentage.toStringAsFixed(1)}%',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(
                      value: totalVotes > 0 ? percentage / 100 : 0,
                      backgroundColor: Colors.grey.shade200,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        _poll.ownVotes?.contains(index) == true
                            ? Theme.of(context).colorScheme.primary
                            : Colors.grey.shade400,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      context.l10n.pollVotesCount(option.votesCount ?? 0),
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              );
            } else {
              // 投票可能な状態
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                child: _poll.multiple
                    ? CheckboxListTile(
                        title: Text(option.title),
                        value: _selectedOptions.contains(index),
                        onChanged: (bool? value) {
                          setState(() {
                            if (value == true) {
                              _selectedOptions.add(index);
                            } else {
                              _selectedOptions.remove(index);
                            }
                          });
                        },
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                      )
                    : RadioListTile<int>(
                        title: Text(option.title),
                        value: index,
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                      ),
              );
            }
          }),

          const SizedBox(height: 8),

          // 投票ボタンと情報
          Row(
            children: [
              if (!showResults) ...[
                ElevatedButton(
                  onPressed: !widget.readOnly &&
                          _selectedOptions.isNotEmpty &&
                          !_isVoting
                      ? _vote
                      : null,
                  child: _isVoting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(context.l10n.pollVote),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.readOnly && !showResults)
                      Text(
                        context.l10n.pollCannotVoteRemote,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    Text(
                      context.l10n.pollPeopleVoted(totalVotes),
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                    // expiresAt は nullable (無期限投票)。null なら残り時間行を出さない
                    if (_poll.expiresAt case final expiresAt?)
                      if (expiresAt.isAfter(DateTime.now()))
                        Text(
                          _formatTimeRemaining(context, expiresAt),
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                        )
                      else
                        Text(
                          context.l10n.pollEnded,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      ),
    );
  }

  String _formatTimeRemaining(BuildContext context, DateTime expiresAt) {
    final remaining = expiresAt.difference(DateTime.now());
    if (remaining.inDays > 0) {
      return context.l10n.pollRemainingDays(remaining.inDays);
    } else if (remaining.inHours > 0) {
      return context.l10n.pollRemainingHours(remaining.inHours);
    } else if (remaining.inMinutes > 0) {
      return context.l10n.pollRemainingMinutes(remaining.inMinutes);
    } else {
      return context.l10n.pollRemainingLessThanMinute;
    }
  }
}

