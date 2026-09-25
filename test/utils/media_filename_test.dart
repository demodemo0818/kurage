import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/utils/media_filename.dart';

void main() {
  group('extensionFromMime', () {
    test('サブタイプがそのまま拡張子にならない MIME はマッピングする', () {
      expect(extensionFromMime('image/jpeg'), 'jpg');
      expect(extensionFromMime('image/svg+xml'), 'svg');
      expect(extensionFromMime('video/quicktime'), 'mov');
      expect(extensionFromMime('video/x-matroska'), 'mkv');
      expect(extensionFromMime('audio/mpeg'), 'mp3');
    });

    test('サブタイプがそのまま拡張子になる MIME はそのまま使う', () {
      expect(extensionFromMime('image/png'), 'png');
      expect(extensionFromMime('image/gif'), 'gif');
      expect(extensionFromMime('image/webp'), 'webp');
      expect(extensionFromMime('video/mp4'), 'mp4');
      expect(extensionFromMime('video/webm'), 'webm');
    });

    test('charset 等のパラメータ付き・大文字でも解釈できる', () {
      expect(extensionFromMime('image/JPEG; charset=binary'), 'jpg');
      expect(extensionFromMime('VIDEO/MP4'), 'mp4');
    });
  });

  group('resolveMediaExtension', () {
    test('メディア系 Content-Type は MIME を優先する', () {
      expect(
        resolveMediaExtension('https://ex.jp/media/original/file', 'video/mp4'),
        'mp4',
      );
      // 拡張子なし URL でも MIME から動画と分かる (Issue #5 の本丸)
      expect(
        resolveMediaExtension('https://ex.jp/media/abcdef', 'video/quicktime'),
        'mov',
      );
    });

    test('MIME より URL の拡張子が食い違ってもメディア MIME を信用する', () {
      expect(
        resolveMediaExtension('https://ex.jp/a/b.jpg', 'video/mp4'),
        'mp4',
      );
    });

    test('汎用 MIME / MIME 欠落時は URL の path 末尾に倒す', () {
      expect(
        resolveMediaExtension(
            'https://ex.jp/media/original/x.mp4', 'application/octet-stream'),
        'mp4',
      );
      expect(resolveMediaExtension('https://ex.jp/media/x.png', null), 'png');
      // クエリ付きでも path だけ見る
      expect(
        resolveMediaExtension('https://ex.jp/media/x.webm?token=abc.jpg', null),
        'webm',
      );
    });

    test('どちらからも取れなければ jpg にフォールバックする', () {
      expect(resolveMediaExtension('https://ex.jp/media/abcdef', null), 'jpg');
      expect(
        resolveMediaExtension('https://ex.jp/media/abcdef', 'text/html'),
        'jpg',
      );
      // 拡張子らしくない長い末尾は採用しない
      expect(
        resolveMediaExtension('https://ex.jp/media/x.somethinglong', null),
        'jpg',
      );
    });
  });

  group('androidSaveDirectoryFor', () {
    test('画像・動画は Pictures、音声は Music (Pictures だと EPERM、issue #10)', () {
      expect(androidSaveDirectoryFor('jpg'), 'Pictures');
      expect(androidSaveDirectoryFor('gif'), 'Pictures');
      expect(androidSaveDirectoryFor('mp4'), 'Pictures');
      expect(androidSaveDirectoryFor('mov'), 'Pictures');
      expect(androidSaveDirectoryFor('mp3'), 'Music');
      expect(androidSaveDirectoryFor('m4a'), 'Music');
      expect(androidSaveDirectoryFor('ogg'), 'Music');
      expect(androidSaveDirectoryFor('wav'), 'Music');
      expect(androidSaveDirectoryFor('flac'), 'Music');
    });

    test('どれでもなければ Download', () {
      expect(androidSaveDirectoryFor('pdf'), 'Download');
      expect(androidSaveDirectoryFor('xyz'), 'Download');
    });
  });
}
