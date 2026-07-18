// Android のプッシュ通知用 small icon (白モノクロ + 透過) を
// アプリアイコン素材 (assets/icon/kurage_icon.png) から生成する one-off スクリプト。
//
// Android の通知 small icon はアルファチャンネルだけがマスクとして使われ
// 単色で描画されるため、フルカラーの ic_launcher を渡すと全面ベタ塗り
// (白い四角) になる。ここで明度 → アルファ変換した白シルエットを
// drawable-*dpi に出力し、flutter_local_notifications から
// `ic_stat_kurage` として参照する。
// アイコン素材を差し替えたときだけ再実行すればよい。
//
// 実行:  dart run tool/gen_notification_icon.dart
//
// 注: `image` は pubspec.yaml の dev_dependencies に直接宣言してある。

import 'dart:io';
import 'package:image/image.dart' as img;

const _src = 'assets/icon/kurage_icon.png';

// Android 通知アイコンの標準サイズ (24dp 基準)。
//
// ⚠️ 修飾なし 'drawable/' (キー '') は必須。Google Play の AAB は
// drawable-*dpi を density config split に分割する一方、修飾なし drawable/
// は base APK に残る。density フォルダにしか置かないと、split が期待通り
// 当たらない端末で getIdentifier が 0 を返し、通知アイコンの解決に失敗する
// (v0.15.0-beta で通知が黙って消えた / v0.16.0-beta でフォールバックの
// ic_launcher が白い四角で出た実障害)。mipmap-* が base に残るのと対照的。
const _outputs = {
  '': 96, // 修飾なし = base APK 用フォールバック (高解像度を置き縮小させる)
  'mdpi': 24,
  'hdpi': 36,
  'xhdpi': 48,
  'xxhdpi': 72,
  'xxxhdpi': 96,
};

// 明度 → アルファの変換しきい値 (0-255)。
// 背景 (#0A0620 付近, max チャンネル ~0x30) を完全透過にし、
// ネオン線 (max チャンネル 180+) を不透明にする。間はグローとして
// なだらかに落とす。
const _lo = 56;
const _hi = 176;

void main() {
  final srcFile = File(_src);
  if (!srcFile.existsSync()) {
    stderr.writeln('素材が見つかりません: $_src');
    exit(1);
  }

  final decoded = img.decodeImage(srcFile.readAsBytesSync());
  if (decoded == null) {
    stderr.writeln('画像のデコードに失敗: $_src');
    exit(1);
  }

  // フル解像度で白シルエット化してから縮小する (縮小後にしきい値処理すると
  // 細い触手がエイリアシングで飛びやすいため)。
  // ネオン線は青〜マゼンタの彩色なので、輝度でなく max(r,g,b) を明度に使う
  // (輝度だと青系の線が暗く評価されて欠ける)。
  final silhouette = img.Image(
    width: decoded.width,
    height: decoded.height,
    numChannels: 4,
  );
  for (final p in decoded) {
    final v = [p.r, p.g, p.b].reduce((a, b) => a > b ? a : b).toInt();
    final a = ((v - _lo) * 255 / (_hi - _lo)).round().clamp(0, 255);
    silhouette.setPixelRgba(p.x, p.y, 255, 255, 255, a);
  }

  for (final entry in _outputs.entries) {
    final size = entry.value;
    final resized = img.copyResize(
      silhouette,
      width: size,
      height: size,
      interpolation: img.Interpolation.average,
    );
    final dir = entry.key.isEmpty ? 'drawable' : 'drawable-${entry.key}';
    final dst = 'android/app/src/main/res/$dir/ic_stat_kurage.png';
    File(dst)
      ..createSync(recursive: true)
      ..writeAsBytesSync(img.encodePng(resized));
    stdout.writeln('OK: $dst (${size}x$size)');
  }
}
