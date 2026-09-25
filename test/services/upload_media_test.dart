// uploadMedia の multipart 組み立てのテスト。
//
// 大きな動画を全量メモリに載せないよう、本体は `XFile.openRead()` のストリームで
// 送る (issue #9)。押さえたい回帰:
//  - ファイルの中身がそのまま送られる (ストリーム化で欠けない)
//  - 同じ XFile を複数アカウントへ順に送っても、毎回全量が送られる
//  - filename が空にならない (空だと Mastodon が 422 "File can't be blank")
//  - Content-Type は XFile の mimeType → 拡張子の順で決まる
//
// `httpClient` を MockClient に差し替えて検証する (Hive は触らない)。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kurage/services/mastodon_api.dart';

void main() {
  const base = 'https://ex.com';
  const token = 'tok';

  // POST /api/v2/media の本体を到着順に記録する。
  late List<http.Request> uploads;

  setUp(() {
    uploads = [];
    httpClient = MockClient((req) async {
      if (req.method == 'POST') {
        uploads.add(req);
        return http.Response(jsonEncode({'id': 'm${uploads.length}'}), 200);
      }
      // 動画の処理完了待ち (GET /api/v1/media/:id) は即完了にする。
      return http.Response(jsonEncode({'url': 'https://ex.com/m.mp4'}), 200);
    });
  });

  tearDown(() {
    httpClient = http.Client();
  });

  /// multipart 本体から、ファイルパートのヘッダ部分と中身を取り出す。
  ({String headers, List<int> content}) filePart(http.Request req) {
    final boundary = req.headers['content-type']!.split('boundary=').last;
    final body = latin1.decode(req.bodyBytes);
    final part = body
        .split('--$boundary')
        .firstWhere((p) => p.contains('name="file"'));
    final sep = part.indexOf('\r\n\r\n');
    final content = part.substring(sep + 4, part.length - 2); // 末尾 CRLF を除く
    return (headers: part.substring(0, sep), content: latin1.encode(content));
  }

  test('メモリ上のファイルも中身と Content-Type をそのまま送る', () async {
    // クリップボード貼り付けと同じ XFile.fromData。io 実装は name を捨てる
    // ので filename は MIME から補われる (docs/pitfalls.md)。
    final bytes = Uint8List.fromList(List.generate(70000, (i) => i % 256));
    final file = XFile.fromData(
      bytes,
      name: 'photo.png',
      mimeType: 'image/png',
    );

    final id = await uploadMedia(
      instanceUrl: base,
      accessToken: token,
      file: file,
    );

    expect(id, 'm1');
    final part = filePart(uploads.single);
    expect(part.headers, contains('content-type: image/png'));
    expect(part.headers, contains('filename="upload.png"'));
    expect(part.content, bytes);
  });

  test('同じファイルを複数アカウントへ送っても毎回全量が送られる', () async {
    final dir = await Directory.systemTemp.createTemp('upload_media_test');
    addTearDown(() => dir.delete(recursive: true));
    final bytes = Uint8List.fromList(List.generate(200000, (i) => i * 7 % 256));
    final path = '${dir.path}/clip.mp4';
    await File(path).writeAsBytes(bytes);
    // image_picker (Android) が返すのと同じ、path だけ持つ XFile。
    final file = XFile(path);

    await Future.wait([
      uploadMedia(instanceUrl: base, accessToken: token, file: file),
      uploadMedia(instanceUrl: base, accessToken: token, file: file),
    ]);

    expect(uploads, hasLength(2));
    for (final req in uploads) {
      final part = filePart(req);
      expect(part.headers, contains('filename="clip.mp4"'));
      // mimeType が無ければ拡張子から推定する。
      expect(part.headers, contains('content-type: video/mp4'));
      expect(part.content, bytes);
    }
  });
}
