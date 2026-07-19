// lib/widgets/collapsible_text.dart

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../utils/bounded_collections.dart';

/// 指定した行数を超える場合に折りたたみ可能なテキストウィジェット
class CollapsibleText extends StatefulWidget {
  final List<InlineSpan> textSpans;
  final TextStyle defaultStyle;
  final int maxLines;
  final Color? buttonColor;
  final TextAlign? textAlign;
  final TextDirection? textDirection;

  /// 展開状態を State 破棄 (scrollable_positioned_list の画面外スクロールや
  /// SSE prepend による押し出し) を跨いで保持するためのキー。post_tile の
  /// `_revealedByStatusId` 等と同じ「安定キー付き static Map」パターン。
  /// null なら従来どおり State ローカルで保持する。
  final String? stateKey;

  const CollapsibleText({
    super.key,
    required this.textSpans,
    required this.defaultStyle,
    required this.maxLines,
    this.buttonColor,
    this.textAlign,
    this.textDirection,
    this.stateKey,
  });

  @override
  State<CollapsibleText> createState() => _CollapsibleTextState();
}

class _CollapsibleTextState extends State<CollapsibleText> {
  // stateKey 付き利用時の展開状態。上限は post_tile の tile 系キャッシュ
  // (_kMaxTileCache = 1500) と揃えた FIFO。
  static final BoundedMap<String, bool> _expandedByKey = BoundedMap(1500);

  bool _localExpanded = false;
  bool _shouldShowButton = false;

  bool get _isExpanded => widget.stateKey == null
      ? _localExpanded
      : (_expandedByKey[widget.stateKey!] ?? false);

  void _setExpanded(bool value) {
    final key = widget.stateKey;
    if (key == null) {
      _localExpanded = value;
    } else {
      _expandedByKey[key] = value;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.maxLines <= 0) {
      // maxLines が 0 以下の場合は折りたたみ機能を無効にする。
      // RichText ではなく Text.rich を使うことで、Web の SelectionArea に
      // 自動登録されてドラッグ選択できる (モバイルは registrar が null になり
      // 従来通り非選択)。
      return Text.rich(
        TextSpan(
          style: widget.defaultStyle,
          children: widget.textSpans,
        ),
        textAlign: widget.textAlign ?? TextAlign.start,
        textDirection: widget.textDirection,
        // RichText 時代と同じ非スケーリング挙動を維持 (フォントサイズは
        // アプリ設定側で制御しているため MediaQuery textScaler は掛けない)。
        textScaler: TextScaler.noScaling,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // WidgetSpanが含まれていない場合のみTextPainterで行数をチェック
        final hasWidgetSpan = _hasWidgetSpan(widget.textSpans);
        
        if (!hasWidgetSpan) {
          // TextPainterを使って行数をチェック
          final textSpan = TextSpan(
            style: widget.defaultStyle,
            children: widget.textSpans,
          );
          
          final textPainter = TextPainter(
            text: textSpan,
            textDirection: widget.textDirection ?? TextDirection.ltr,
            maxLines: widget.maxLines,
          );
          textPainter.layout(maxWidth: constraints.maxWidth);

          final fullTextPainter = TextPainter(
            text: textSpan,
            textDirection: widget.textDirection ?? TextDirection.ltr,
          );
          fullTextPainter.layout(maxWidth: constraints.maxWidth);

          _shouldShowButton = fullTextPainter.didExceedMaxLines || 
                            textPainter.didExceedMaxLines;
        } else {
          // WidgetSpanが含まれている場合は、実際にレンダリングして判定
          // この場合は簡易的に文字数で判定（完璧ではないが安全）
          final textLength = _calculateTextLength(widget.textSpans);
          final estimatedLines = (textLength / 50).ceil(); // 1行約50文字と仮定
          _shouldShowButton = estimatedLines > widget.maxLines;
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // テキスト部分。Text.rich で SelectionArea (Web) のドラッグ選択に
            // 対応する。
            Text.rich(
              TextSpan(
                style: widget.defaultStyle,
                children: widget.textSpans,
              ),
              textAlign: widget.textAlign ?? TextAlign.start,
              textDirection: widget.textDirection,
              maxLines: _isExpanded ? null : widget.maxLines,
              overflow: _isExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
              textScaler: TextScaler.noScaling,
            ),
            
            // 展開/折りたたみボタン
            if (_shouldShowButton)
              Padding(
                padding: const EdgeInsets.only(top: 4.0),
                child: GestureDetector(
                  onTap: () {
                    setState(() {
                      _setExpanded(!_isExpanded);
                    });
                  },
                  child: Text(
                    _isExpanded ? context.l10n.showLess : context.l10n.showMore,
                    style: widget.defaultStyle.copyWith(
                      color: widget.buttonColor ?? Colors.blue,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// TextSpanの中にWidgetSpanが含まれているかチェック
  bool _hasWidgetSpan(List<InlineSpan> spans) {
    for (final span in spans) {
      if (span is WidgetSpan) {
        return true;
      } else if (span is TextSpan && span.children != null) {
        if (_hasWidgetSpan(span.children!)) {
          return true;
        }
      }
    }
    return false;
  }

  /// TextSpanの文字数を計算（WidgetSpanは1文字として計算）
  int _calculateTextLength(List<InlineSpan> spans) {
    int length = 0;
    for (final span in spans) {
      if (span is TextSpan) {
        if (span.text != null) {
          length += span.text!.length;
        }
        if (span.children != null) {
          length += _calculateTextLength(span.children!);
        }
      } else if (span is WidgetSpan) {
        length += 1; // WidgetSpan（絵文字など）は1文字として計算
      }
    }
    return length;
  }
}