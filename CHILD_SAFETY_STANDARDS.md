# Kurage 児童の安全に関する基準（Child Safety Standards）

最終更新日：2026年6月25日

本基準は、Mastodon クライアントアプリ **Kurage**（以下「本アプリ」）における、
児童の性的虐待および搾取（Child Sexual Abuse and Exploitation, 以下「CSAE」）の
防止に関する開発者（以下「開発者」）の方針を定めるものです。

本アプリは、ユーザーが任意の Mastodon サーバーに接続して投稿の閲覧・作成を行う
クライアントです。投稿等のコンテンツは各 Mastodon サーバー上に保存・管理されており、
開発者はそれらのコンテンツをホスティングしていません。本基準は、本アプリを通じた
CSAE 行為を一切許容しないという開発者の立場と、ユーザー・関係機関が取りうる対応を
明確にすることを目的とします。

---

## 1. CSAE の全面禁止

開発者は、児童の性的虐待・搾取に関するあらゆるコンテンツおよび行為を固く禁止します。
これには以下が含まれますが、これらに限りません。

- 児童性的虐待コンテンツ（CSAM）の作成・閲覧・共有・拡散
- 児童に対する性的な誘引（グルーミング）、性的目的での接触の試み
- 児童の性的な搾取・人身取引を助長・幇助する行為

本アプリを上記の目的で使用することを一切認めません。

---

## 2. アプリ内での通報手段

本アプリには、問題のあるアカウントや投稿を Mastodon サーバーの
モデレーターへ通報できる**アプリ内通報機能**が実装されています。

- 投稿またはアカウントのメニューから「通報」を選択することで、対象の投稿・
  アカウントを、接続先 Mastodon サーバーの運営者へ報告できます。
- 通報は Mastodon 標準の通報 API（`POST /api/v1/reports`）を通じて、
  当該サーバーのモデレーションチームへ送信されます。
- 違反内容の説明や、関連する複数の投稿を添えて通報することができます。

CSAE に該当するコンテンツを発見した場合は、この通報機能を用いて速やかに
報告してください。あわせて、下記「4. 連絡先」の窓口へもご連絡いただけます。

---

## 3. 違反への対応と法令遵守

- 開発者は、適用される児童保護関連の法令を遵守します。
- CSAE に関する報告を受けた場合、内容を確認し、必要に応じて関係する
  Mastodon サーバーの運営者および法執行機関・関係当局（各国の通報窓口、
  米国の NCMEC 等を含む）への通報・協力を行います。
- 本アプリを CSAE 目的で使用していることが判明したユーザーに対しては、
  利用可能な範囲で適切な措置を講じます。

なお、投稿コンテンツの保存・配信・モデレーション（削除・アカウント停止等）は
各 Mastodon サーバーの運営者が一次的な責任を負います。開発者は、本アプリの
提供者として、通報経路の確保と関係機関への協力に努めます。

---

## 4. 連絡先（児童の安全に関する窓口）

児童の安全・CSAE に関する報告やお問い合わせは、以下までご連絡ください。
法執行機関・関係当局からのご連絡も受け付けます。

**メール**: info@demo2.jp
**アプリページ**: https://demo2.jp/kurage/

---

## 5. 基準の変更

本基準を変更する場合は、このページを更新します。

---

# Kurage Child Safety Standards (English summary)

Last updated: 2026-06-25

**Kurage** is a Mastodon client app. User-generated content is stored and
moderated on the third-party Mastodon servers that each user connects to;
the developer does not host that content.

The developer strictly prohibits any child sexual abuse and exploitation
(CSAE), including child sexual abuse material (CSAM), grooming, and
solicitation of minors.

**In-app reporting:** Users can report any post or account to the
moderators of the connected Mastodon server directly from the app via the
"Report" action, which uses Mastodon's standard reporting API
(`POST /api/v1/reports`).

**Compliance:** The developer complies with applicable child safety laws and
will, where appropriate, cooperate with and report to the relevant Mastodon
server operators and to law enforcement / authorities (including reporting
bodies such as NCMEC where applicable).

**Point of contact for child safety:** info@demo2.jp
