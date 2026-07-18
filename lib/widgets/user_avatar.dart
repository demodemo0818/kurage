// lib/widgets/user_avatar.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/settings_provider.dart';
import 'network_image_x.dart';

/// ユーザーアバター表示用の共通ウィジェット。
///
/// 外観設定の `isAvatarSquare` を読み、true なら角丸四角、false なら丸で
/// 描画する。`avatarUrl` を表示するすべての箇所はこの widget を使う。
///
/// 既存の `CircleAvatar(backgroundImage: ResizeImage(CachedNetworkImage
/// Provider(url), ...))` 系を置き換える想定。
class UserAvatar extends ConsumerWidget {
  final String url;

  /// 半径 (CircleAvatar の radius と同義: 直径 = radius * 2)。
  final double radius;

  /// 四角表示時の角の丸み。デフォルトは radius の 0.1 倍 (= ほんのり丸い)。
  /// null なら radius * 0.1 にフォールバック。
  final double? squareBorderRadius;

  /// 画像読み込み失敗時に表示するアイコン。
  final IconData fallbackIcon;

  const UserAvatar({
    super.key,
    required this.url,
    required this.radius,
    this.squareBorderRadius,
    this.fallbackIcon = Icons.person,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isSquare =
        ref.watch(settingsProvider.select((s) => s.isAvatarSquare));
    final size = radius * 2;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cacheSide = (size * dpr).round();
    final borderRadius = squareBorderRadius ?? (radius * 0.1).clamp(2.0, 12.0);

    if (url.isEmpty) {
      // URL 無しは fallback アイコンだけ描画 (円/角丸はそれぞれの形で)。
      final placeholder = Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        color: Colors.grey.shade300,
        child: Icon(fallbackIcon, size: size * 0.6, color: Colors.white),
      );
      return isSquare
          ? ClipRRect(
              borderRadius: BorderRadius.circular(borderRadius),
              child: placeholder,
            )
          : ClipOval(child: placeholder);
    }

    if (isSquare) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: KurageNetworkImage(
          imageUrl: url,
          width: size,
          height: size,
          memCacheWidth: cacheSide,
          memCacheHeight: cacheSide,
          fit: BoxFit.cover,
          placeholder: (_, _) => Container(
            width: size,
            height: size,
            color: Colors.grey.shade200,
          ),
          errorWidget: (_, _, _) => Container(
            width: size,
            height: size,
            color: Colors.grey.shade300,
            alignment: Alignment.center,
            child: Icon(fallbackIcon, size: size * 0.6, color: Colors.white),
          ),
        ),
      );
    }

    return KurageCircleAvatar(
      imageUrl: url,
      radius: radius,
      backgroundColor: Colors.grey.shade300,
    );
  }
}
