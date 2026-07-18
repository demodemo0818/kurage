// MediaAttachment のパースと種別判定のテスト。
//
// aspectRatio は `_PostMediaGallery` のレイアウト (横長は最大 2:1、縦長/正方形
// は正方形のまま) に直結する。Mastodon の `meta.original.aspect` →
// `width/height` → 1.0 の多段フォールバックを固定する。
// isVideo が gifv を含むこと (タイムラインで自動再生しない設計の前提) も守る。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/models/media_attachment.dart';

Map<String, dynamic> _mediaJson({
  String type = 'image',
  String? previewUrl = 'https://example.com/preview.png',
  Map<String, dynamic>? meta,
}) =>
    {
      'id': 'm1',
      'type': type,
      'url': 'https://example.com/original.png',
      if (previewUrl != null) 'preview_url': previewUrl,
      if (meta != null) 'meta': meta,
    };

void main() {
  group('MediaAttachment.fromJson', () {
    test('preview_url 欠落時は url にフォールバックする', () {
      final media = MediaAttachment.fromJson(_mediaJson(previewUrl: null));
      expect(media.previewUrl, 'https://example.com/original.png');
    });

    test('description は null 許容', () {
      final media = MediaAttachment.fromJson(_mediaJson());
      expect(media.description, isNull);
    });

    test('url が null (サーバ処理中) は remote_url → 空文字に倒す', () {
      // 非同期アップロード直後やリモート未取得時、Mastodon は url を null で返す
      final json = _mediaJson(previewUrl: null);
      json['url'] = null;
      json['remote_url'] = 'https://remote.example/orig.png';
      final media = MediaAttachment.fromJson(json);
      expect(media.url, 'https://remote.example/orig.png');
      expect(media.previewUrl, 'https://remote.example/orig.png');

      json['remote_url'] = null;
      final empty = MediaAttachment.fromJson(json);
      expect(empty.url, '');
      expect(empty.previewUrl, '');
    });

    test('数値 ID と type 欠落を許容する', () {
      final json = _mediaJson();
      json['id'] = 42;
      json.remove('type');
      final media = MediaAttachment.fromJson(json);
      expect(media.id, '42');
      expect(media.type, 'unknown');
    });
  });

  group('MediaAttachment aspectRatio', () {
    test('meta.original.aspect (double) をそのまま使う', () {
      final media = MediaAttachment.fromJson(_mediaJson(meta: {
        'original': {'aspect': 1.7777},
      }));
      expect(media.aspectRatio, closeTo(1.7777, 0.0001));
    });

    test('meta.original.aspect (int) も num として受け付ける', () {
      final media = MediaAttachment.fromJson(_mediaJson(meta: {
        'original': {'aspect': 2},
      }));
      expect(media.aspectRatio, 2.0);
    });

    test('aspect が 0 以下なら width/height にフォールバックする', () {
      final media = MediaAttachment.fromJson(_mediaJson(meta: {
        'original': {'aspect': 0, 'width': 1920, 'height': 1080},
      }));
      expect(media.aspectRatio, closeTo(16 / 9, 0.0001));
    });

    test('aspect 無しでも width/height から算出する', () {
      final media = MediaAttachment.fromJson(_mediaJson(meta: {
        'original': {'width': 1080, 'height': 1920},
      }));
      expect(media.aspectRatio, closeTo(9 / 16, 0.0001));
    });

    test('height が 0 なら 1.0 にフォールバックする', () {
      final media = MediaAttachment.fromJson(_mediaJson(meta: {
        'original': {'width': 1920, 'height': 0},
      }));
      expect(media.aspectRatio, 1.0);
    });

    test('meta 無し / original 無しは 1.0', () {
      expect(MediaAttachment.fromJson(_mediaJson()).aspectRatio, 1.0);
      expect(
        MediaAttachment.fromJson(_mediaJson(meta: {})).aspectRatio,
        1.0,
      );
    });
  });

  group('種別判定 getter', () {
    test('isVideo は video と gifv の両方で true', () {
      expect(MediaAttachment.fromJson(_mediaJson(type: 'video')).isVideo, true);
      expect(MediaAttachment.fromJson(_mediaJson(type: 'gifv')).isVideo, true);
      expect(
          MediaAttachment.fromJson(_mediaJson(type: 'image')).isVideo, false);
    });

    test('isGif は gifv のみ true (通常の video と区別する)', () {
      expect(MediaAttachment.fromJson(_mediaJson(type: 'gifv')).isGif, true);
      expect(MediaAttachment.fromJson(_mediaJson(type: 'video')).isGif, false);
    });

    test('isImage / isAudio は対応する type のみ true', () {
      expect(MediaAttachment.fromJson(_mediaJson(type: 'image')).isImage, true);
      expect(MediaAttachment.fromJson(_mediaJson(type: 'audio')).isAudio, true);
      expect(MediaAttachment.fromJson(_mediaJson(type: 'image')).isAudio, false);
    });
  });
}
