// lib/utils/avatar_utils.dart

import 'package:cached_network_image/cached_network_image.dart';

/// アバター画像の表示に関するユーティリティ
class AvatarUtils {
  /// アバターURLにキャッシュバスターを追加して最新の画像を強制取得
  static String addCacheBuster(String avatarUrl) {
    if (avatarUrl.isEmpty) return avatarUrl;
    
    final now = DateTime.now().millisecondsSinceEpoch;
    final separator = avatarUrl.contains('?') ? '&' : '?';
    return '$avatarUrl${separator}t=$now';
  }
  
  /// 指定されたURLのキャッシュを削除
  static Future<void> clearImageCache(String imageUrl) async {
    await CachedNetworkImage.evictFromCache(imageUrl);
  }
}