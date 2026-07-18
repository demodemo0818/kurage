// lib/services/sound_service.dart

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// アプリ表示中 (フォアグラウンド) の効果音再生。
///
/// 通知受信 / 投稿完了 / 引っ張って更新 の 3 イベントで、`assets/sounds/` に
/// 置かれた短い音を鳴らす。音源ファイル (notification.mp3 / post.mp3 /
/// refresh.mp3) はユーザーが配置する想定で、無くてもクラッシュはしない
/// (再生失敗を握りつぶす)。
///
/// 設定 (settings_provider の `soundOnNotification` 等) の ON/OFF 判定は
/// **呼び出し側の責務**。このサービスは「鳴らすだけ」に徹し、Riverpod に
/// 依存しない。既存の `AnalyticsService.instance` / `PushNotificationService`
/// と同じプレーンなシングルトン。
class SoundService {
  SoundService._();

  /// アプリ全体で共有するシングルトン。
  static final SoundService instance = SoundService._();

  // 効果音は低頻度なので 1 プレイヤーを使い回す。再生前に stop() するため、
  // 直前の音が残っていても上書きされる。ReleaseMode.stop で再生後も
  // ネイティブリソースを保持し、次回再生のレイテンシ・無音を抑える
  // (既定の release だと毎回プリペアし直しになる)。
  final AudioPlayer _player = AudioPlayer(playerId: 'kurage_sfx')
    ..setReleaseMode(ReleaseMode.stop);

  // 通知音の連打抑制。bot ブースト連打や複数アカウント運用で SSE が短時間に
  // 多数届くため、最小間隔で間引く。投稿 / 更新は単発ユーザー操作なので不要。
  DateTime? _lastNotificationAt;
  static const Duration _notificationMinInterval = Duration(milliseconds: 800);

  Future<void> _play(String assetPath) async {
    try {
      await _player.stop();
      // AssetSource は既定で 'assets/' プレフィックスを付けるため、ここでは
      // 'sounds/xxx.mp3' を渡す (先頭に assets/ を付けない)。
      await _player.play(AssetSource(assetPath));
    } catch (e) {
      // Web の autoplay 制限 / 音源ファイル欠落 / 未対応プラットフォーム等。
      // 効果音は補助機能なのでクラッシュさせず無音フォールバックにする。
      debugPrint('[Sound] 再生失敗 ($assetPath): $e');
    }
  }

  /// 通知受信音。短時間に多数届くケースを 800ms で間引く。
  Future<void> notification() async {
    final now = DateTime.now();
    final last = _lastNotificationAt;
    if (last != null && now.difference(last) < _notificationMinInterval) {
      return;
    }
    _lastNotificationAt = now;
    await _play('sounds/notification.mp3');
  }

  /// 投稿完了音。
  Future<void> post() => _play('sounds/post.mp3');

  /// 引っ張って更新音。
  Future<void> refresh() => _play('sounds/refresh.mp3');
}
