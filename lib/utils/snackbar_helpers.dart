// lib/utils/snackbar_helpers.dart

import 'dart:async';
import 'package:flutter/material.dart';

/// 現在表示中のトースト。連続表示時に前のものを置き換えるための参照。
OverlayEntry? _activeToast;

/// 中央寄せ・内容幅自動の軽量トースト。SnackBar が FAB と重なる問題を
/// 避けるため、`Overlay` 上に独立した pill を浮かべる。
///
/// - 横位置: 画面中央
/// - 幅: 内容に応じて (上限は画面幅の 80%、超えると折り返し)
/// - 縦位置: 画面下から 80px (BottomNav / FAB を避ける高さ)
/// - 自動消滅 + フェードイン/アウト
///
/// `rootOverlay: true` で取り出すことで、呼び出し元のルートが pop されても
/// トーストは表示され続ける (投稿完了 → pop してメインに戻った後も見える)。
void showCenteredToast(
  BuildContext context,
  String message, {
  IconData? icon = Icons.check_circle_outline,
  Duration duration = const Duration(seconds: 2),
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  // 直前のトーストが残っていれば即時撤去 (重ね表示を避ける)
  _activeToast?.remove();
  _activeToast = null;

  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => _ToastWidget(
      message: message,
      icon: icon,
      duration: duration,
      onDismiss: () {
        if (identical(_activeToast, entry)) {
          _activeToast = null;
        }
        entry.remove();
      },
    ),
  );
  _activeToast = entry;
  overlay.insert(entry);
}

class _ToastWidget extends StatefulWidget {
  final String message;
  final IconData? icon;
  final Duration duration;
  final VoidCallback onDismiss;

  const _ToastWidget({
    required this.message,
    required this.icon,
    required this.duration,
    required this.onDismiss,
  });

  @override
  State<_ToastWidget> createState() => _ToastWidgetState();
}

class _ToastWidgetState extends State<_ToastWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  Timer? _dismissTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _controller.forward();
    _dismissTimer = Timer(widget.duration, _dismiss);
  }

  Future<void> _dismiss() async {
    if (!mounted) return;
    await _controller.reverse();
    if (!mounted) return;
    widget.onDismiss();
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    // SnackBar と同じ M3 配色を使う (inverseSurface / onInverseSurface)。
    final scheme = Theme.of(context).colorScheme;
    final bg = scheme.inverseSurface;
    final fg = scheme.onInverseSurface;
    return Positioned(
      bottom: 80,
      left: 0,
      right: 0,
      child: IgnorePointer(
        // タップ透過にして下のコンテンツを邪魔しない
        child: Center(
          child: FadeTransition(
            opacity: _opacity,
            child: Material(
              color: Colors.transparent,
              child: Container(
                constraints: BoxConstraints(maxWidth: size.width * 0.8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 8,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.icon != null) ...[
                      Icon(widget.icon, color: fg, size: 18),
                      const SizedBox(width: 8),
                    ],
                    Flexible(
                      child: Text(
                        widget.message,
                        style: TextStyle(color: fg, fontSize: 14),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 統一されたエラー SnackBar を表示する。
///
/// 赤背景 + エラーアイコン + 「閉じる」ボタン付き。アプリ全体で同じ見た目に
/// するためのラッパー。`ScaffoldMessenger` のスコープが必要なので
/// `BuildContext` を渡す。
///
/// `duration` は省略時 4 秒。エラーメッセージは読む時間が必要なため
/// 成功 SnackBar (3 秒) より少し長め。
void showErrorSnackBar(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 4),
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      backgroundColor: Colors.red.shade700,
      duration: duration,
      content: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
      action: SnackBarAction(
        label: '閉じる',
        textColor: Colors.white,
        onPressed: () => messenger.hideCurrentSnackBar(),
      ),
    ),
  );
}
