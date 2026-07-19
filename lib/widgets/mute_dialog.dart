// lib/widgets/mute_dialog.dart
//
// アカウントをミュートする際の確認ダイアログ。Mastodon 公式 Web UI に倣い
// 「ミュート期間」と「このユーザーからの通知も非表示にするか」を選ばせる。
//
// 戻り値は record:
//   - null              → キャンセル (ミュートしない)
//   - (duration, hideNotifications) → 実行
// `duration` は秒。無期限を選んだときは null (API には duration を渡さない)。
// `hideNotifications` は `muteAccount(notifications: ...)` にそのまま渡す。

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

/// ミュートダイアログの選択結果。
typedef MuteChoice = ({int? duration, bool hideNotifications});

/// ミュート期間の選択肢 (公式 Web UI の mute modal に合わせた値)。
/// value が null のものは「無期限」。ラベルは表示言語に依存するため
/// 呼び出し時に組み立てる。
List<({String label, int? value})> _muteDurations(AppLocalizations l10n) => [
      (label: l10n.muteDurationIndefinite, value: null),
      (label: l10n.durationMinutes(5), value: 300),
      (label: l10n.durationMinutes(30), value: 1800),
      (label: l10n.durationHours(1), value: 3600),
      (label: l10n.durationHours(6), value: 21600),
      (label: l10n.durationHours(12), value: 43200),
      (label: l10n.durationDays(1), value: 86400),
      (label: l10n.durationDays(3), value: 259200),
      (label: l10n.durationDays(7), value: 604800),
    ];

/// `@acct` をミュートするか確認するダイアログを表示する。
/// 確定時は選んだ期間と通知トグルを返し、キャンセル時は null を返す。
Future<MuteChoice?> showMuteDialog(
  BuildContext context, {
  required String acct,
}) {
  return showDialog<MuteChoice>(
    context: context,
    builder: (ctx) {
      int? selectedDuration; // null = 無期限
      bool hideNotifications = true;
      return StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(ctx.l10n.muteTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(ctx.l10n.muteConfirmMessage(acct)),
              const SizedBox(height: 20),
              Text(ctx.l10n.muteDurationLabel),
              const SizedBox(height: 4),
              DropdownButtonFormField<int?>(
                initialValue: selectedDuration,
                isExpanded: true,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                items: [
                  for (final d in _muteDurations(ctx.l10n))
                    DropdownMenuItem<int?>(
                      value: d.value,
                      child: Text(d.label),
                    ),
                ],
                onChanged: (v) => setState(() => selectedDuration = v),
              ),
              const SizedBox(height: 4),
              CheckboxListTile(
                value: hideNotifications,
                onChanged: (v) =>
                    setState(() => hideNotifications = v ?? true),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(ctx.l10n.muteNotificationsToo),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(ctx.l10n.cancel),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(
                ctx,
                (
                  duration: selectedDuration,
                  hideNotifications: hideNotifications,
                ),
              ),
              child: Text(ctx.l10n.muteTitle),
            ),
          ],
        ),
      );
    },
  );
}
