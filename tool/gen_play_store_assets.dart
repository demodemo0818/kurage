// Google Play ストア掲載用のグラフィック素材を生成する one-off スクリプト。
//
// 生成物 (いずれも store_assets/ に出力):
//   - play_icon_512.png        : アプリアイコン 512x512 (Play 要件)
//   - play_feature_1024x500.png: フィーチャーグラフィック 1024x500
//
// アイコン素材 (assets/icon/kurage_icon.png) を差し替えたときだけ再実行する。
//
// 実行:  dart run tool/gen_play_store_assets.dart
//
// 注: `image` は pubspec.yaml の dev_dependencies に宣言済み。

import 'dart:io';
import 'dart:math' as math;
import 'package:image/image.dart' as img;

const _src = 'assets/icon/kurage_icon.png';
const _outDir = 'store_assets';

void main() {
  final srcBytes = File(_src).readAsBytesSync();
  final src = img.decodePng(srcBytes);
  if (src == null) {
    stderr.writeln('PNG のデコードに失敗: $_src');
    exit(1);
  }

  Directory(_outDir).createSync(recursive: true);

  // 1) アプリアイコン 512x512。元画像をそのまま高品質縮小する。
  final icon = img.copyResize(
    src,
    width: 512,
    height: 512,
    interpolation: img.Interpolation.cubic,
  );
  final iconPath = '$_outDir/play_icon_512.png';
  File(iconPath).writeAsBytesSync(img.encodePng(icon));
  stdout.writeln('生成: $iconPath (512x512)');

  // 2) フィーチャーグラフィック 1024x500。
  //    背景: アイコン隅の紺を基準に、中央をやや明るくした放射状グラデーション
  //          (クラゲの色は拾わず、背景だけを自然に演出)。
  //    前景: 透過 (RGBA) の foreground ロゴを中央に重ねる (四角い縁が出ない)。
  const fw = 1024, fh = 500;
  final feature = img.Image(width: fw, height: fh);

  final corner = src.getPixel(0, 0);
  final er = corner.r.toDouble();
  final eg = corner.g.toDouble();
  final eb = corner.b.toDouble();
  // 中央色 = 隅色を 1.7 倍明るく (255 で頭打ち)。
  double bright(double v) => math.min(255.0, v * 1.7);
  final cr = bright(er), cg = bright(eg), cb = bright(eb);

  final cx = fw / 2, cy = fh / 2;
  final maxD = math.sqrt(cx * cx + cy * cy);
  for (var y = 0; y < fh; y++) {
    for (var x = 0; x < fw; x++) {
      final dx = x - cx, dy = y - cy;
      final t = math.sqrt(dx * dx + dy * dy) / maxD; // 0(中央)..1(隅)
      final r = (cr + (er - cr) * t).round();
      final g = (cg + (eg - cg) * t).round();
      final b = (cb + (eb - cb) * t).round();
      feature.setPixelRgb(x, y, r, g, b);
    }
  }

  // クラゲ抽出: 元アイコン (濃紺背景) を RGBA 化し、隅の背景色に近いピクセルを
  //   透明にしてクラゲのネオン線だけを残す。透過版が素材に無いのでここで作る。
  //   ネオン線は背景の濃紺と十分コントラストがあるため色距離で分離できる。
  final cutout = src.convert(numChannels: 4);
  final bgp = src.getPixel(0, 0);
  final br = bgp.r.toDouble(), bg = bgp.g.toDouble(), bb = bgp.b.toDouble();
  const tLow = 45.0; // これ以下は完全透明 (背景)
  const tHigh = 90.0; // これ以上は完全不透明 (クラゲ線)。間は線形でフェード
  for (var y = 0; y < cutout.height; y++) {
    for (var x = 0; x < cutout.width; x++) {
      final p = cutout.getPixel(x, y);
      final dr = p.r - br, dg = p.g - bg, db = p.b - bb;
      final dist = math.sqrt(dr * dr + dg * dg + db * db);
      double a;
      if (dist <= tLow) {
        a = 0;
      } else if (dist >= tHigh) {
        a = 255;
      } else {
        a = (dist - tLow) / (tHigh - tLow) * 255;
      }
      cutout.setPixelRgba(x, y, p.r, p.g, p.b, a.round());
    }
  }

  // クラゲは元画像の中央寄りに大きく入っているので、高さに収まる 460px 角で配置。
  const logoSize = 460;
  final logo = img.copyResize(
    cutout,
    width: logoSize,
    height: logoSize,
    interpolation: img.Interpolation.cubic,
  );
  img.compositeImage(
    feature,
    logo,
    dstX: (fw - logoSize) ~/ 2,
    dstY: (fh - logoSize) ~/ 2,
  );

  final featurePath = '$_outDir/play_feature_1024x500.png';
  File(featurePath).writeAsBytesSync(img.encodePng(feature));
  stdout.writeln('生成: $featurePath (1024x500)');

  stdout.writeln('完了。store_assets/ にアップロード用素材を出力しました。');
}
