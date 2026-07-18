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

/// ミュートダイアログの選択結果。
typedef MuteChoice = ({int? duration, bool hideNotifications});

/// ミュート期間の選択肢 (公式 Web UI の mute modal に合わせた値)。
/// value が null のものは「無期限」。
const List<({String label, int? value})> _muteDurations = [
  (label: '無期限', value: null),
  (label: '5分', value: 300),
  (label: '30分', value: 1800),
  (label: '1時間', value: 3600),
  (label: '6時間', value: 21600),
  (label: '12時間', value: 43200),
  (label: '1日', value: 86400),
  (label: '3日', value: 259200),
  (label: '7日', value: 604800),
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
          title: const Text('ミュート'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '@$acctをミュートしますか？\n\n'
                'ミュートすると、そのユーザーの投稿がタイムラインに表示されなくなります。',
              ),
              const SizedBox(height: 20),
              const Text('期間'),
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
                  for (final d in _muteDurations)
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
                title: const Text('このユーザーからの通知も非表示にする'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('キャンセル'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(
                ctx,
                (
                  duration: selectedDuration,
                  hideNotifications: hideNotifications,
                ),
              ),
              child: const Text('ミュート'),
            ),
          ],
        ),
      );
    },
  );
}
