// `parseNextMaxIdFromLinkHeader` の回帰テスト。
//
// `/api/v1/mutes` `/api/v1/blocks` のページングカーソルはサーバ内部の関係 ID
// であり、返ってくる Account.id とは別物。「最後の Account.id を max_id に渡す」
// 簡易方式はこの 2 エンドポイントでは壊れる (2 ページ目が空 or 重複) ため、
// Link ヘッダから本物の next カーソルを取り出すこの関数が正しさの要。
// URL クエリ内のカンマとリンク区切りのカンマを混同しないことが特に重要。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/services/mastodon_api.dart';

void main() {
  group('parseNextMaxIdFromLinkHeader', () {
    test('null / 空文字は null', () {
      expect(parseNextMaxIdFromLinkHeader(null), isNull);
      expect(parseNextMaxIdFromLinkHeader(''), isNull);
    });

    test('rel="next" 単独から max_id を取り出す', () {
      expect(
        parseNextMaxIdFromLinkHeader(
          '<https://ex.com/api/v1/mutes?limit=40&max_id=12345>; rel="next"',
        ),
        '12345',
      );
    });

    test('next と prev が両方あっても next の max_id を返す', () {
      expect(
        parseNextMaxIdFromLinkHeader(
          '<https://ex.com/api/v1/blocks?max_id=999>; rel="next", '
          '<https://ex.com/api/v1/blocks?since_id=111>; rel="prev"',
        ),
        '999',
      );
    });

    test('prev が先に来ても next を正しく拾う (順序非依存)', () {
      expect(
        parseNextMaxIdFromLinkHeader(
          '<https://ex.com/api/v1/blocks?since_id=111>; rel="prev", '
          '<https://ex.com/api/v1/blocks?max_id=777>; rel="next"',
        ),
        '777',
      );
    });

    test('URL クエリに複数パラメータ (limit と max_id) があっても max_id を返す', () {
      expect(
        parseNextMaxIdFromLinkHeader(
          '<https://ex.com/api/v1/mutes?limit=80&max_id=54321>; rel="next"',
        ),
        '54321',
      );
    });

    test('クォート無しの rel=next にも対応', () {
      expect(
        parseNextMaxIdFromLinkHeader(
          '<https://ex.com/api/v1/mutes?max_id=42>; rel=next',
        ),
        '42',
      );
    });

    test('prev のみ (= 末尾ページ) は null', () {
      expect(
        parseNextMaxIdFromLinkHeader(
          '<https://ex.com/api/v1/mutes?since_id=111>; rel="prev"',
        ),
        isNull,
      );
    });

    test('rel="next" だが max_id が無い URL は null', () {
      expect(
        parseNextMaxIdFromLinkHeader(
          '<https://ex.com/api/v1/mutes?limit=40>; rel="next"',
        ),
        isNull,
      );
    });
  });
}
