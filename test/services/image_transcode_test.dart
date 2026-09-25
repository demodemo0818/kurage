@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kurage/services/image_transcode.dart';

/// ISO BMFF の ftyp ボックス (major brand + compatible brands) を組む。
Uint8List _ftyp(String major, List<String> compatible) {
  final size = 16 + compatible.length * 4;
  return Uint8List.fromList([
    (size >> 24) & 0xFF, (size >> 16) & 0xFF, (size >> 8) & 0xFF, size & 0xFF,
    ...'ftyp'.codeUnits,
    ...major.codeUnits,
    0, 0, 0, 0, // minor version
    for (final b in compatible) ...b.codeUnits,
  ]);
}

/// JPEG をデコードして (x, y) の画素を返す。
img.Pixel _pixelAt(Uint8List jpeg, int x, int y) =>
    img.decodeJpg(jpeg)!.getPixel(x, y);

Matcher _isRed() => predicate<img.Pixel>(
    (p) => p.r > 200 && p.g < 60 && p.b < 60, 'red');
Matcher _isBlue() => predicate<img.Pixel>(
    (p) => p.r < 60 && p.g < 60 && p.b > 200, 'blue');

// HEIC / AVIF のデコードは Flutter エンジンが OS のデコーダに任せる部分なので、
// 読めるのは macOS / Android のみ (CI の Linux では skip)。
final _skipUnlessHeifDecodable =
    Platform.isMacOS ? false : 'HEIC / AVIF をデコードできるのは macOS のみ';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('isHeifFamilyImage', () {
    test('HEIC / AVIF / HEIF (mif1) の major brand を検出する', () {
      expect(isHeifFamilyImage(_ftyp('heic', ['mif1', 'heic'])), isTrue);
      expect(isHeifFamilyImage(_ftyp('avif', ['avif', 'mif1'])), isTrue);
      expect(isHeifFamilyImage(_ftyp('mif1', ['heic'])), isTrue);
    });

    test('major brand が別でも compatible brands に HEIF 系があれば検出する', () {
      expect(isHeifFamilyImage(_ftyp('miaf', ['miaf', 'mif1'])), isTrue);
    });

    test('MP4 / QuickTime の動画は対象外', () {
      expect(
          isHeifFamilyImage(_ftyp('isom', ['isom', 'iso2', 'avc1', 'mp41'])),
          isFalse);
      expect(isHeifFamilyImage(_ftyp('qt  ', ['qt  '])), isFalse);
    });

    test('JPEG / PNG や短すぎる入力は対象外', () {
      final png = img.encodePng(img.Image(width: 1, height: 1));
      final jpeg = img.encodeJpg(img.Image(width: 1, height: 1));
      expect(isHeifFamilyImage(png), isFalse);
      expect(isHeifFamilyImage(jpeg), isFalse);
      expect(isHeifFamilyImage(Uint8List(8)), isFalse);
    });

    test('ftyp ボックスの外にあるバイトはブランドとして読まない', () {
      final head = Uint8List.fromList(
          [..._ftyp('isom', []), ...'heic'.codeUnits, 0, 0, 0, 0]);
      expect(isHeifFamilyImage(head), isFalse);
    });
  });

  group('fitWithinPixels', () {
    test('上限以内ならそのまま', () {
      expect(fitWithinPixels(3840, 2160, kMastodonMaxImagePixels),
          (width: 3840, height: 2160));
    });

    test('上限を超えたらアスペクト比を保って上限以下に縮める', () {
      final s = fitWithinPixels(4032, 3024, kMastodonMaxImagePixels);
      expect(s.width * s.height, lessThanOrEqualTo(kMastodonMaxImagePixels));
      expect(s.width * s.height, greaterThan(kMastodonMaxImagePixels * 0.99));
      expect(s.width / s.height, closeTo(4032 / 3024, 0.01));
    });
  });

  group('transcodeToJpeg', () {
    test('JPEG に変換し、透過部分は白で塗る', () async {
      // 左半分が透明、右半分が不透明の赤 (8x8 の JPEG ブロック境界に揃える)。
      final src = img.Image(width: 16, height: 16, numChannels: 4);
      for (final p in src) {
        if (p.x >= 8) p.setRgba(255, 0, 0, 255);
      }
      final jpeg = await transcodeToJpeg(img.encodePng(src));

      expect(jpeg.sublist(0, 3), [0xFF, 0xD8, 0xFF]);
      final left = _pixelAt(jpeg, 3, 8);
      expect([left.r, left.g, left.b], everyElement(greaterThan(240)));
      expect(_pixelAt(jpeg, 12, 8), _isRed());
    });

    test('maxPixels を超える画像は縮小する', () async {
      final png = img.encodePng(img.Image(width: 40, height: 30));
      final jpeg = await transcodeToJpeg(png, maxPixels: 300);
      final decoded = img.decodeJpg(jpeg)!;
      expect((decoded.width, decoded.height), (20, 15));
    });
  });

  group('convertHeifFamilyToJpeg', () {
    test('HEIF 系でなければ null (変換しない)', () async {
      final png = img.encodePng(img.Image(width: 2, height: 2));
      final file = XFile.fromData(png, name: 'a.png', mimeType: 'image/png');
      expect(await convertHeifFamilyToJpeg(file), isNull);
    });

    test('デコードできない HEIF は ImageTranscodeException', () async {
      final broken = Uint8List.fromList(
          [..._ftyp('heic', ['mif1', 'heic']), ...List.filled(64, 0)]);
      final file = XFile.fromData(broken, name: 'broken.heic');
      await expectLater(convertHeifFamilyToJpeg(file),
          throwsA(isA<ImageTranscodeException>()));
    });

    test('HEIC を回転を反映した JPEG に変換し、拡張子を .jpg にする', () async {
      // 上半分が赤・下半分が青の 64x48 に、EXIF Orientation 6 (時計回りに
      // 90° 回して表示) を付けたもの。変換後は 48x64 で右半分が赤になる。
      final converted = await convertHeifFamilyToJpeg(
          XFile('test/fixtures/red_top_64x48_rot6.heic'));

      expect(converted, isNotNull);
      expect(converted!.file.name, 'red_top_64x48_rot6.jpg');
      expect(converted.file.mimeType, 'image/jpeg');
      expect(await converted.file.readAsBytes(), converted.bytes);
      final decoded = img.decodeJpg(converted.bytes)!;
      expect((decoded.width, decoded.height), (48, 64));
      expect(decoded.getPixel(40, 32), _isRed());
      expect(decoded.getPixel(8, 32), _isBlue());
    }, skip: _skipUnlessHeifDecodable);

    test('AVIF も JPEG に変換する', () async {
      final converted = await convertHeifFamilyToJpeg(
          XFile('test/fixtures/red_top_64x48.avif'));

      expect(converted, isNotNull);
      expect(converted!.file.name, 'red_top_64x48.jpg');
      final decoded = img.decodeJpg(converted.bytes)!;
      expect((decoded.width, decoded.height), (64, 48));
      expect(decoded.getPixel(32, 8), _isRed());
      expect(decoded.getPixel(32, 40), _isBlue());
    }, skip: _skipUnlessHeifDecodable);
  });
}
