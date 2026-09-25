@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kurage/services/image_transcode.dart';

// Web の JPEG 変換 (image_transcode_web.dart: <img> + <canvas>) のテスト。
// `flutter test --platform chrome test/services/image_transcode_web_test.dart`
// で実行する (CI の `flutter test` は VM なので対象外)。

/// test/fixtures/red_top_64x48.avif (上半分が赤・下半分が青の 64x48)。
/// Web のテストからはファイルを読めないので埋め込む。
final Uint8List _avif = base64Decode(
    'AAAAIGZ0eXBhdmlmAAAAAE1pUHJhdmlmbWlhZm1pZjEAAAEhbWV0YQAAAAAAAAAh'
    'aGRscgAAAAAAAAAAcGljdAAAAAAAAAAAAAAAAAAAAAAkZGluZgAAABxkcmVmAAAA'
    'AAAAAAEAAAAMdXJsIAAAAAEAAAAOcGl0bQAAAAAAAQAAACNpaW5mAAAAAAABAAAA'
    'FWluZmUCAAAAAAEAAGF2MDEAAAAAgWlwcnAAAABgaXBjbwAAABNjb2xybmNseAAC'
    'AAIABoAAAAAMY2xsaQDLAEAAAAAUaXNwZQAAAAAAAABAAAAAMAAAAAlpcm90AAAA'
    'ABBwaXhpAAAAAAMICAgAAAAMYXYxQ4EADAAAAAAZaXBtYQAAAAAAAAABAAEGgQID'
    'BYaEAAAAHmlsb2MAAAAARAAAAQABAAAAAQAAAVEAAABKAAAAAW1kYXQAAAAAAAAA'
    'WhIACg0AAAACr/ef/wIEBA0IMjcUAGMAAACA1//s9UmlPinOW/7oRO0nAOJsHkHB'
    'TX0TFry+ok2BYOHCD+VgZj574WzIK0Vl12Gw');

Matcher _isRed() => predicate<img.Pixel>(
    (p) => p.r > 200 && p.g < 60 && p.b < 60, 'red');
Matcher _isBlue() => predicate<img.Pixel>(
    (p) => p.r < 60 && p.g < 60 && p.b > 200, 'blue');

void main() {
  test('JPEG に変換し、透過部分は白で塗る', () async {
    // 左半分が透明、右半分が不透明の赤 (8x8 の JPEG ブロック境界に揃える)。
    final src = img.Image(width: 16, height: 16, numChannels: 4);
    for (final p in src) {
      if (p.x >= 8) p.setRgba(255, 0, 0, 255);
    }
    final jpeg = await transcodeToJpeg(img.encodePng(src));

    expect(jpeg.sublist(0, 3), [0xFF, 0xD8, 0xFF]);
    final decoded = img.decodeJpg(jpeg)!;
    final left = decoded.getPixel(3, 8);
    expect([left.r, left.g, left.b], everyElement(greaterThan(240)));
    expect(decoded.getPixel(12, 8), _isRed());
  });

  test('maxPixels を超える画像は縮小する', () async {
    final png = img.encodePng(img.Image(width: 40, height: 30));
    final decoded = img.decodeJpg(await transcodeToJpeg(png, maxPixels: 300))!;
    expect((decoded.width, decoded.height), (20, 15));
  });

  test('AVIF を JPEG に変換する (dart:ui の Web デコーダでは読めない形式)', () async {
    final converted = await convertHeifFamilyToJpeg(
        XFile.fromData(_avif, name: 'red_top_64x48.avif'));

    expect(converted, isNotNull);
    expect(converted!.file.name, 'red_top_64x48.jpg');
    expect(converted.file.mimeType, 'image/jpeg');
    final decoded = img.decodeJpg(converted.bytes)!;
    expect((decoded.width, decoded.height), (64, 48));
    expect(decoded.getPixel(32, 8), _isRed());
    expect(decoded.getPixel(32, 40), _isBlue());
  });
}
