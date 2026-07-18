// Windows ランナー用アイコン (windows/runner/resources/app_icon.ico) を
// アプリアイコン素材 (assets/icon/kurage_icon.png) から生成する one-off スクリプト。
//
// flutter_launcher_icons は Windows の .ico を生成しないため、ここで
// 依存に含まれている `image` パッケージを使って多サイズ .ico を組み立てる。
// アイコン素材を差し替えたときだけ再実行すればよい。
//
// 実行:  dart run tool/gen_windows_icon.dart
//
// 注: `image` は pubspec.yaml の dev_dependencies に直接宣言してある。

import 'dart:io';
import 'package:image/image.dart' as img;

const _src = 'assets/icon/kurage_icon.png';
const _dst = 'windows/runner/resources/app_icon.ico';

// Windows のアイコンとして一般的なサイズ群 (小サイズ〜タスクバー〜高DPI)。
const _sizes = [16, 24, 32, 48, 64, 128, 256];

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

  final frames = [
    for (final s in _sizes)
      img.copyResize(
        decoded,
        width: s,
        height: s,
        interpolation: img.Interpolation.average,
      ),
  ];

  // image 4 でトップレベルの encodeIcoImages() は削除された → IcoEncoder を直接使う
  final ico = img.IcoEncoder().encodeImages(frames);
  File(_dst)
    ..createSync(recursive: true)
    ..writeAsBytesSync(ico);

  stdout.writeln(
      'OK: $_dst を生成 (${ico.length} bytes, ${_sizes.length} サイズ: ${_sizes.join("/")})');
}
