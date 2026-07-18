// lib/widgets/network_image_x.dart

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// プラットフォーム共通のネットワーク画像ウィジェット。
///
/// - **mobile / desktop**: `CachedNetworkImage` を使い、ディスクキャッシュ +
///   memory キャッシュで高速に再表示。
/// - **Web**: `Image.network` を `WebHtmlElementStrategy.fallback` で呼ぶ。
///   まず通常の CanvasKit パス (XHR で bytes を取得して canvas に decode) を
///   試み、それが失敗したとき (= `Access-Control-Allow-Origin` を返さない
///   Mastodon インスタンス CDN で CORS により bytes を読めない) だけ HTML
///   `<img>` 要素にフォールバックする (`<img>` タグは CORS チェック対象外)。
///
///   **なぜ `prefer` ではなく `fallback` か**: HTML `<img>` 要素は Flutter の
///   canvas とは別の DOM レイヤーに合成され、canvas に描かれるオーバーレイ
///   (Deck ポップアップ / ダイアログ等) の「上」に浮いてしまう。`prefer` だと
///   全画像が `<img>` になり、ポップアップを開いた時に下のカラムの画像/アバターが
///   手前に抜けて見える不具合が起きた。`fallback` なら CORS OK の画像 (大多数)
///   は canvas 描画になりオーバーレイに正しく隠れる。CORS 不可の画像のみ
///   `<img>` にフォールバックして表示は維持する (この少数は依然浮き得る)。
///   配信側の Cache-Control が機能していればブラウザ HTTP キャッシュで十分実用的。
///
/// CachedNetworkImage の代表的なパラメタを揃えているので、既存コードからは
/// 名前を置き換えるだけで概ね動く。`imageBuilder` は Web では完全に再現
/// できない (Image.network が ImageProvider を builder に渡す経路を持た
/// ない) ため、その場合は `NetworkImage(url)` を builder に渡してフォール
/// バックする — 結果として Web ではその経路だけ CORS 影響を受け得るので、
/// imageBuilder の利用は最小限に留めるのが望ましい。
class KurageNetworkImage extends StatelessWidget {
  final String imageUrl;
  final double? width;
  final double? height;
  final int? memCacheWidth;
  final int? memCacheHeight;
  final BoxFit? fit;
  final Widget Function(BuildContext, String)? placeholder;
  final Widget Function(BuildContext, String, Object)? errorWidget;
  final Widget Function(BuildContext, ImageProvider)? imageBuilder;
  final Alignment alignment;
  final Duration? fadeInDuration;
  final Duration? fadeOutDuration;

  const KurageNetworkImage({
    super.key,
    required this.imageUrl,
    this.width,
    this.height,
    this.memCacheWidth,
    this.memCacheHeight,
    this.fit,
    this.placeholder,
    this.errorWidget,
    this.imageBuilder,
    this.alignment = Alignment.center,
    this.fadeInDuration,
    this.fadeOutDuration,
  });

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      if (imageBuilder != null) {
        // 厳密一致は不可能なので NetworkImage を builder に渡す。
        // 描画パスは CanvasKit 経由 = CORS 影響あり (このパスを使うのは
        // ImageProvider が必要な特殊ケースだけにすること)。
        return imageBuilder!(context, NetworkImage(imageUrl));
      }
      return Image.network(
        imageUrl,
        width: width,
        height: height,
        cacheWidth: memCacheWidth,
        cacheHeight: memCacheHeight,
        fit: fit,
        alignment: alignment,
        webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
        errorBuilder: errorWidget == null
            ? null
            : (ctx, error, stack) => errorWidget!(ctx, imageUrl, error),
        loadingBuilder: placeholder == null
            ? null
            : (ctx, child, progress) {
                if (progress == null) return child;
                return placeholder!(ctx, imageUrl);
              },
      );
    }
    return CachedNetworkImage(
      imageUrl: imageUrl,
      width: width,
      height: height,
      memCacheWidth: memCacheWidth,
      memCacheHeight: memCacheHeight,
      fit: fit ?? BoxFit.cover,
      placeholder: placeholder,
      errorWidget: errorWidget,
      imageBuilder: imageBuilder,
      alignment: alignment,
      fadeInDuration:
          fadeInDuration ?? const Duration(milliseconds: 500),
      fadeOutDuration:
          fadeOutDuration ?? const Duration(milliseconds: 1000),
    );
  }
}

/// CircleAvatar の置き換えヘルパー。
///
/// CircleAvatar.backgroundImage は **ImageProvider** を要求し、ImageProvider
/// は常に bytes 経由で decode するため、Web の CORS 制約を避けられない。
/// このウィジェットは Web では ClipOval + [KurageNetworkImage] (= HTML <img>
/// 経由) に切り替えることで、CORS 未対応インスタンスのアバターも表示可能に
/// する。mobile/desktop は従来通り CircleAvatar + CachedNetworkImageProvider。
class KurageCircleAvatar extends StatelessWidget {
  final String? imageUrl;
  final double radius;
  final Color? backgroundColor;

  /// 画像が無い (URL 空) ときに表示する子。
  final Widget? fallbackChild;

  const KurageCircleAvatar({
    super.key,
    required this.imageUrl,
    this.radius = 20,
    this.backgroundColor,
    this.fallbackChild,
  });

  @override
  Widget build(BuildContext context) {
    final url = imageUrl;
    if (url == null || url.isEmpty) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: backgroundColor ?? Colors.grey.shade300,
        child: fallbackChild,
      );
    }
    final size = radius * 2;
    if (kIsWeb) {
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final cacheSide = (size * dpr).round();
      return ClipOval(
        child: SizedBox(
          width: size,
          height: size,
          child: ColoredBox(
            color: backgroundColor ?? Colors.grey.shade300,
            child: KurageNetworkImage(
              imageUrl: url,
              width: size,
              height: size,
              memCacheWidth: cacheSide,
              memCacheHeight: cacheSide,
              fit: BoxFit.cover,
              errorWidget: (_, _, _) => Container(
                width: size,
                height: size,
                color: backgroundColor ?? Colors.grey.shade300,
              ),
            ),
          ),
        ),
      );
    }
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cacheSide = (size * dpr).round();
    return CircleAvatar(
      radius: radius,
      backgroundColor: backgroundColor ?? Colors.grey.shade300,
      backgroundImage: ResizeImage(
        CachedNetworkImageProvider(url),
        width: cacheSide,
        height: cacheSide,
        policy: ResizeImagePolicy.fit,
      ),
    );
  }
}
