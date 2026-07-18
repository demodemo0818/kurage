# 効果音ファイル (assets/sounds/)

アプリ表示中 (フォアグラウンド) の効果音をここに置く。
[lib/services/sound_service.dart](../../lib/services/sound_service.dart) が再生する。

| ファイル名 | 鳴るタイミング |
| --- | --- |
| `notification.mp3` | 通知を受信したとき (SSE) |
| `post.mp3` | 投稿が完了したとき |
| `refresh.mp3` | タイムラインを引っ張って更新したとき |

## 注意

- ファイル名は上記固定 (変える場合は `sound_service.dart` のパスも合わせる)。
- `mp3` / `wav` などが使える。短い (1 秒前後の) 音が望ましい。
- ファイルが無くても**クラッシュはしない** (再生失敗を握りつぶす) が、当然音は鳴らない。
- 設定の「サウンド（効果音）」で各イベント個別に ON/OFF できる (既定は OFF)。
- `pubspec.yaml` で `assets/sounds/` をディレクトリ宣言しているため、
  この README が存在することでディレクトリが実在し、音源未配置でもビルドが通る。
