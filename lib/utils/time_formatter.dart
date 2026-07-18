import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

/// 時刻フォーマッタユーティリティ
/// 相対時間表示と絶対時間表示の関数を提供します。

/// 相対時間 (例: 5分前, 2時間前) を日本語で返します。
String formatRelative(DateTime dt) {
  final now = DateTime.now();
  final diff = now.difference(dt);
  if (diff.inSeconds < 60) return '${diff.inSeconds}秒前';
  if (diff.inMinutes < 60) return '${diff.inMinutes}分前';
  if (diff.inHours < 24) return '${diff.inHours}時間前';
  if (diff.inDays < 30) return '${diff.inDays}日前';
  final months = diff.inDays ~/ 30;
  if (months < 12) return '$monthsか月前';
  final years = diff.inDays ~/ 365;
  return '$years年前';
}

/// 絶対時間 (例: 2025/05/10 14:23) を返します。
String formatAbsolute(DateTime dt) {
  return DateFormat('yyyy/MM/dd HH:mm').format(dt.toLocal());
}

/// 時間フォーマット（相対時間を基本にし、古い場合は絶対時間）
String formatTime(DateTime dt) {
  final now = DateTime.now();
  final diff = now.difference(dt);

  // 24時間以内は相対時間
  if (diff.inHours < 24) {
    return formatRelative(dt);
  }

  // 24時間以上は絶対時間
  return formatAbsolute(dt);
}

/// `useRelative=true` のとき自動更新する時刻表示 Text。
///
/// 旧実装は `Text(formatRelative(dt))` のように毎 build で文字列を計算
/// していたが Timer を持たず、「3 秒前」のような表示が再描画契機 (ストリーミング
/// 受信 / スクロール / 設定変更) が来るまで更新されない問題があった
/// (= 「5 秒前」のまま 30 分残る)。本 Widget は `Timer` を持って自分自身だけ
/// setState することで、親の rebuild とは独立に時刻表示を最新化する。
///
/// **更新間隔は adaptive** (経過時間で粒度を変える):
///   - 1 分未満 → 10 秒ごと
///   - 1 時間未満 → 1 分ごと
///   - それ以上 → 5 分ごと
/// 細かすぎる更新で電池を食わず、かつ「3 秒前 → 30 秒前」のような大ジャンプを
/// 避けるバランス。
///
/// `useRelative=false` のときは絶対時刻文字列を表示するだけで Timer は持たない
/// (再描画する必要がないため)。
class TimeText extends StatefulWidget {
  final DateTime dt;
  final bool useRelative;
  final TextStyle? style;
  final TextAlign? textAlign;

  const TimeText({
    super.key,
    required this.dt,
    required this.useRelative,
    this.style,
    this.textAlign,
  });

  @override
  State<TimeText> createState() => _TimeTextState();
}

class _TimeTextState extends State<TimeText> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.useRelative) _scheduleNext();
  }

  @override
  void didUpdateWidget(TimeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dt != widget.dt || oldWidget.useRelative != widget.useRelative) {
      _timer?.cancel();
      _timer = null;
      if (widget.useRelative) _scheduleNext();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// 経過時間に応じた次回更新までの間隔。
  static Duration _intervalFor(Duration age) {
    if (age.inMinutes < 1) return const Duration(seconds: 10);
    if (age.inHours < 1) return const Duration(minutes: 1);
    return const Duration(minutes: 5);
  }

  void _scheduleNext() {
    final age = DateTime.now().difference(widget.dt);
    _timer = Timer(_intervalFor(age), () {
      if (!mounted) return;
      setState(() {}); // この Widget だけ再描画
      _scheduleNext();
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.useRelative
        ? formatRelative(widget.dt)
        : formatAbsolute(widget.dt);
    return Text(text, style: widget.style, textAlign: widget.textAlign);
  }
}
