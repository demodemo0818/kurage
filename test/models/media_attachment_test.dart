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

    // Misskey は GIF を mp4 に変換せず type だけ gifv で返す (URL は .gif の
    // まま)。GIF は動画コーデックではなくどのプラットフォームの動画
    // プレイヤーでも再生できないため、表示側が画像経路に倒す判定を固定する。
    test('isAnimatedImageFile: gifv + .gif URL (Misskey 未変換) で true', () {
      MediaAttachment media({required String type, required String url}) =>
          MediaAttachment(id: 'm1', type: type, url: url, previewUrl: url);

      expect(
        media(type: 'gifv', url: 'https://mk.example/files/abc.gif')
            .isAnimatedImageFile,
        true,
      );
      // クエリ付き URL でも path で判定する
      expect(
        media(type: 'gifv', url: 'https://mk.example/files/abc.gif?sensitive=1')
            .isAnimatedImageFile,
        true,
      );
      expect(
        media(type: 'gifv', url: 'https://mk.example/files/a.apng')
            .isAnimatedImageFile,
        true,
      );
      expect(
        media(type: 'video', url: 'https://mk.example/files/a.webp')
            .isAnimatedImageFile,
        true,
      );
      // mp4 変換済みの正規 gifv は動画プレイヤーのまま
      expect(
        media(type: 'gifv', url: 'https://mastodon.example/media/abc.mp4')
            .isAnimatedImageFile,
        false,
      );
      // 画像 type は対象外 (元々画像経路)
      expect(
        media(type: 'image', url: 'https://mk.example/files/abc.gif')
            .isAnimatedImageFile,
        false,
      );
    });

    // Mastodon が連合時に GIF を mp4 (gifv) に変換したケース。url は .mp4 に
    // なるが remote_url は連合元の元 .gif を指す。video_player 実装が無い
    // Linux ではこれを画像デコーダで再生するため、判定を固定する。
    test('animatedRemoteOriginalUrl: mp4 変換済み gifv の元 .gif を返す', () {
      MediaAttachment media({
        String type = 'gifv',
        String url = 'https://mastodon.example/media/abc.mp4',
        String? remoteUrl,
      }) =>
          MediaAttachment(
            id: 'm1',
            type: type,
            url: url,
            previewUrl: url,
            remoteUrl: remoteUrl,
          );

      expect(
        media(remoteUrl: 'https://media.misskeyusercontent.jp/io/abc.gif')
            .animatedRemoteOriginalUrl,
        'https://media.misskeyusercontent.jp/io/abc.gif',
      );
      // remote_url 無し (ローカル投稿) は null
      expect(media().animatedRemoteOriginalUrl, isNull);
      // remote_url が動画のままなら null (通常の video の連合)
      expect(
        media(
          type: 'video',
          remoteUrl: 'https://remote.example/media/abc.mp4',
        ).animatedRemoteOriginalUrl,
        isNull,
      );
      // 画像 type は対象外
      expect(
        media(
          type: 'image',
          url: 'https://mastodon.example/media/abc.png',
          remoteUrl: 'https://mk.example/files/abc.gif',
        ).animatedRemoteOriginalUrl,
        isNull,
      );
    });

    test('fromJson は remote_url を保持する', () {
      final json = _mediaJson(type: 'gifv');
      json['remote_url'] = 'https://mk.example/files/abc.gif';
      final media = MediaAttachment.fromJson(json);
      expect(media.remoteUrl, 'https://mk.example/files/abc.gif');
      expect(
        media.animatedRemoteOriginalUrl,
        'https://mk.example/files/abc.gif',
      );
    });
  });
}
