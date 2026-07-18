// Status モデルの引用リノート検出 / HTML 除去ロジックのテスト。
//
// Misskey / Fedibird は公式引用フィールドを持たず、本文中の "RE: URL" /
// "QT: URL" マーカーで引用を表現する。Mastodon 4.4+ の公式引用も
// status.quote として別経路で来るが、それ以前 / 未対応サーバ向けに
// 本文パースで拾うフォールバックがある。このフォールバックは
// `lib/widgets/post_tile.dart` の引用描画とリンク先解決の前提なので、
// パターンを壊すと引用が表示されなくなる。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/models/account.dart';
import 'package:kurage/models/status.dart';

/// 引用検出ロジックだけ動かせれば良いので、content 以外は最小値で埋めた
/// Status を組み立てる。`Status.fromJson` だと Account 等のネストも含めて
/// 完全な JSON を用意する必要があり、引用テストの本質と無関係なため避ける。
Status _statusWithContent(String content) {
  final account = Account(
    id: '1',
    username: 'alice',
    acct: 'alice',
    url: '',
    displayName: 'Alice',
    avatarUrl: '',
    headerUrl: '',
    note: '',
    fields: const [],
    followersCount: 0,
    followingCount: 0,
    statusesCount: 0,
    createdAt: DateTime(2024, 1, 1),
    locked: false,
    bot: false,
    emojis: const [],
  );
  return Status(
    id: '1',
    content: content,
    createdAt: DateTime(2024, 1, 1),
    account: account,
    visibility: 'public',
    favourited: false,
    reblogged: false,
    bookmarked: false,
  );
}

void main() {
  group('isQuoteRenote', () {
    test('"RE: <url>" を先頭に含む本文は true', () {
      final s = _statusWithContent('RE: https://example.com/notes/123');
      expect(s.isQuoteRenote, isTrue);
    });

    test('"QT: <url>" を先頭に含む本文は true', () {
      final s = _statusWithContent('QT: https://example.com/users/bob/statuses/456');
      expect(s.isQuoteRenote, isTrue);
    });

    test('本文末尾の "RE: <url>" も検出', () {
      final s = _statusWithContent('本文です RE: https://example.com/notes/789');
      expect(s.isQuoteRenote, isTrue);
    });

    test('HTML タグで囲まれた "RE: <url>" も検出', () {
      // Mastodon は本文を HTML で返すため、`<p>RE: https://...</p>` のような
      // 形でも検出できる必要がある (HTML タグを除去してからマッチ判定)。
      final s = _statusWithContent('<p>RE: https://example.com/notes/123</p>');
      expect(s.isQuoteRenote, isTrue);
    });

    test('"RE:" だけで URL が無いものは false', () {
      // 単なる "RE: " 接頭は引用ではない。誤検出を避ける。
      final s = _statusWithContent('RE: ありがとうございます');
      expect(s.isQuoteRenote, isFalse);
    });

    test('通常投稿 (マーカー無し) は false', () {
      final s = _statusWithContent('今日はいい天気です');
      expect(s.isQuoteRenote, isFalse);
    });

    test('空文字本文は false', () {
      final s = _statusWithContent('');
      expect(s.isQuoteRenote, isFalse);
    });
  });

  group('quotedUrl', () {
    test('"RE: <url>" から URL を抽出', () {
      final s = _statusWithContent('RE: https://example.com/notes/123');
      expect(s.quotedUrl, 'https://example.com/notes/123');
    });

    test('"QT: <url>" から URL を抽出', () {
      final s = _statusWithContent('QT: https://example.com/notes/456');
      expect(s.quotedUrl, 'https://example.com/notes/456');
    });

    test('本文中の "RE: <url>" からも URL を抽出', () {
      final s = _statusWithContent('良い記事 RE: https://example.com/posts/9');
      expect(s.quotedUrl, 'https://example.com/posts/9');
    });

    test('引用でない投稿は null', () {
      final s = _statusWithContent('普通の投稿');
      expect(s.quotedUrl, isNull);
    });
  });

  group('cleanedContent', () {
    test('HTML タグを除去', () {
      final s = _statusWithContent('<p>Hello <strong>world</strong></p>');
      expect(s.cleanedContent, 'Hello world');
    });

    test('タグの無い本文はそのまま', () {
      final s = _statusWithContent('plain text');
      expect(s.cleanedContent, 'plain text');
    });
  });

  group('Status.fromJson の防御的パース', () {
    // Pleroma / Akkoma は ID を JSON int で返し、フォークによっては
    // content / created_at が欠落することがある。1 件のパース失敗が
    // タイムライン全体を巻き込まないよう、耐性を固定する。
    Map<String, dynamic> statusJson() => {
          'id': '100',
          'content': '<p>hello</p>',
          'created_at': '2024-01-01T00:00:00.000Z',
          'account': {
            'id': '1',
            'username': 'alice',
            'display_name': 'Alice',
            'created_at': '2024-01-01T00:00:00.000Z',
          },
        };

    test('数値 ID を文字列に正規化する (in_reply_to_id も同様)', () {
      final json = statusJson();
      json['id'] = 100;
      json['in_reply_to_id'] = 99;
      final s = Status.fromJson(json);
      expect(s.id, '100');
      expect(s.inReplyToId, '99');
    });

    test('content / created_at 欠落でもクラッシュしない', () {
      final json = statusJson();
      json.remove('content');
      json.remove('created_at');
      final s = Status.fromJson(json);
      expect(s.content, '');
    });

    test('ID 欠落は FormatException (リストデコーダが 1 件単位で skip する)', () {
      final json = statusJson();
      json['id'] = null;
      expect(() => Status.fromJson(json), throwsFormatException);
    });
  });
}
