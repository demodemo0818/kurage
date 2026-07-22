# リリース手順とバージョニング

Kurage のバージョン番号とリリース手順の取り決め。

> **現在の状況**: v1.0.0 (2026-07-17) で正式版に到達済み。以降は SemVer 厳密運用
> (MAJOR=破壊的、MINOR=後方互換の機能追加、PATCH=バグ修正。安定版は suffix なし、
> リリース候補を挟む場合のみ `-rc.N`)。本ドキュメント内の 0.x / alpha / beta の
> 記述は当時の取り決めの記録として残している。

## バージョン形式

```
MAJOR.MINOR.PATCH[-PRERELEASE]+BUILD
```

- SemVer 2.0.0 準拠 (https://semver.org/lang/ja/)
- 末尾の `+BUILD` は Flutter の規約 (`pubspec.yaml` の `version:` に書く)。
  Android では `versionCode`、iOS では `CFBundleVersion` に使われる。

このプロジェクトは **「0.x 期間中は永続的に -alpha / -beta を付与し、
PATCH / MINOR 自体を上げていく」** スキームを採用する。
代表例: Minecraft の `Alpha v1.0.x → Beta 1.x → 1.0` 進行。

### 0.x フェーズ (1.0.0 到達前) の運用

このフェーズ中は **正式リリース版 (suffix なし) を出さない**。
1.0.0 が最初の安定リリース。0.x の中は全部 `-alpha` または `-beta`。

数字の意味 (`-alpha` / `-beta` 中も):

- **PATCH を上げる**: バグ修正・性能改善のみ
  - 例: `0.1.0-alpha` → `0.1.1-alpha`
- **MINOR を上げる**: 機能追加 / 機能除去 / 仕様変更 / 破壊的変更
  - 0.x 期間中は SemVer の 0.y.z 慣例で破壊的変更も MINOR で許容
  - 例: `0.1.5-alpha` → `0.2.0-alpha`
- **MAJOR を上げる**: 0.x 中は 0 で固定。1.0.0 到達時に初めて 1 になる

つまりバージョン番号を見れば「前回からバグ修正だけか、機能セットが入ったか」
が一目で判別できる。これが現行 (B 案: alpha.N で番号だけ回す) との大きな違い。

### PRERELEASE ラベル

| ラベル        | 用途                                                                      |
| ------------- | ------------------------------------------------------------------------- |
| `-alpha`      | 0.x 期間の前半 / 不安定期。仕様変更・破壊的変更を含む                       |
| `-beta`       | 0.x 期間の後半。主要仕様が固まりテスター拡大に十分と判断した段階            |
| `-rc.N`       | 1.0.0 直前のリリース候補。バグ修正のみ                                     |
| (省略)        | 1.0.0 以降の安定版                                                         |

**alpha → beta への切り替え判断**:
- 主要機能が一通り揃った
- データ形式・SharedPreferences キー名の破壊的変更が当面起きない確信が持てた
- テスター層を広げて構わない品質に達した

切り替え後は `0.X.Y-beta` のように prefix の数字はそのまま、suffix だけ
変える (例: `0.4.7-alpha` → `0.4.8-beta`)。

> **決定 (2026-06-08)**: 後方互換 (データ形式 / SharedPreferences キー) を
> 当面守れる目処が立ったため、**次のリリースから `-beta` に移行**する。
> フェーズの節目として MINOR 境界で切り替え、移行版は **`0.10.0-beta`** を予定
> (`v0.9.0-alpha` が直近の alpha)。以降 1.0.0-rc まで `-beta`。
> 移行リリース以降は「ルーティンでの再ログイン強制 / データ消去はしない」を
> 約束とするため、リリースノート冒頭の従来警告
> 「まれに再ログイン・データ消去が起こる」は外し、
> 「原則データは保持されます (やむを得ない場合は事前告知)」に置き換える。

**`-alpha` / `-beta` の中で番号サフィックスは付けない**:
- 旧: `0.1.0-alpha.1, 0.1.0-alpha.2, 0.1.0-alpha.3, ...`
- 新: `0.1.1-alpha, 0.1.2-alpha, 0.2.0-alpha, ...`

ただし、SemVer 的には `0.1.1-alpha` の後にさらに同じ PATCH で版を分けたい
特殊ケース (= リリースから 1 時間以内に致命的不具合発覚で `-alpha.2` を
挟みたい等) では `0.1.1-alpha.2` のような書き方も合法。基本は PATCH を
上げる運用で、緊急時のみ番号サフィックスを許容する。

### +BUILD (ビルド番号)

- **通し番号** (1, 2, 3, …)。リリースのたびに +1
- alpha / beta / rc / 安定版を跨いでも **連続** させる
  (Android / iOS は monotonic 整数を要求するため)
- 同一 SemVer 内で複数ビルドを配布した場合も +1 する

### Git タグ

- `vMAJOR.MINOR.PATCH[-PRERELEASE]` (`v` プレフィックス付き)
- `+BUILD` はタグに含めない
- 例: `v0.1.1-alpha`、`v0.5.0-beta`、`v1.0.0-rc.2`、`v1.0.0`

## 進行例

```
v0.1.0-alpha+1     ← 最初のクローズドアルファ (※ 旧タグは alpha.1/2/3 形式)
v0.1.1-alpha+4     ← バグ修正
v0.1.2-alpha+5     ← バグ修正
v0.2.0-alpha+6     ← リスト機能追加 (機能セット)
v0.2.1-alpha+7     ← バグ修正
v0.3.0-alpha+8     ← 検索拡張 (機能セット)
…
v0.5.0-beta+15     ← テスター拡大、仕様凍結
v0.5.1-beta+16     ← バグ修正
v0.6.0-beta+17     ← 小機能追加
…
v1.0.0-rc.1+30
v1.0.0-rc.2+31
v1.0.0+32          ← 初の安定リリース、ここから厳密 SemVer 運用へ
v1.0.1+33          ← バグ修正 (PATCH)
v1.1.0+34          ← 機能追加 (MINOR、後方互換)
v2.0.0+50          ← 破壊的変更 (MAJOR)
```

## 既存タグとの互換

旧スキーム時代に切ったタグ (`v0.1.0-alpha.1` / `v0.1.0-alpha.2` /
`v0.1.0-alpha.3`) は **そのまま残す**。歴史的経緯として残し、新しいタグは
`v0.1.1-alpha` から始める。

SemVer 的に `0.1.0-alpha.3 < 0.1.1-alpha` で順序が保たれるので問題なし。

## 1.0.0 到達条件 (努力目標)

- 主要機能が一通り入って実用に耐える
- データ移行を含む破壊的変更が当面起きない確信
- alpha → beta 段階を経て一定期間広いテスターから OK が出ている

到達したら `v1.0.0-rc.N` でリリース候補を回し、十分テストできたら `v1.0.0`。
以降は SemVer 厳密運用 (MAJOR=破壊的、MINOR=後方互換機能追加、PATCH=バグ修正)。

## Android 署名

Kurage の release APK は **本番用 keystore で署名する** ことを前提とする。
keystore は **絶対に紛失しない / 漏らさない**。失うと同 applicationId
(`jp.demo2.kurage`) で更新版を出せなくなる。

### 仕組み

- 署名情報は [android/key.properties](android/key.properties) に記述
  (`.gitignore` 済み)。テンプレート: [android/key.properties.example](android/key.properties.example)
- keystore 自体はリポジトリ外 (推奨: `%USERPROFILE%\.kurage\upload-keystore.jks`)
- [android/app/build.gradle.kts](android/app/build.gradle.kts) は
  `key.properties` があれば release 鍵を使い、なければ debug 鍵にフォールバック
  する設計 (= 他マシンでも `flutter run --release` が動くようにするため)
- **配布する APK は必ず `key.properties` が解決できる環境でビルドする**

### 初回セットアップ (1 度だけ)

#### ① keystore を生成

```powershell
mkdir "$env:USERPROFILE\.kurage" -Force | Out-Null
& "C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe" `
  -genkey -v `
  -keystore "$env:USERPROFILE\.kurage\upload-keystore.jks" `
  -keyalg RSA -keysize 2048 -validity 10000 `
  -alias kurage
```

対話で聞かれる項目:
- **キーストアパスワード**: パスマネージャ管理の長いランダム文字列
- **鍵パスワード**: Enter で keystore と同じにしてよい
- **氏名 / 組織 / 市 / 県 / 国 (CN, OU, O, L, ST, C)**: 後から変更不可。
  Play Store には影響しないので適当でも実害なし。CN だけ `kurage` 等にしておけば十分

#### ② key.properties を作成

`android/key.properties.example` を `android/key.properties` にコピーして
各値を埋める。`storeFile` は `C:/Users/<ユーザー名>/.kurage/upload-keystore.jks`
のように `/` 区切りで書く。

#### ③ バックアップ

- `upload-keystore.jks` を別ストレージ (クラウド / 外部 HDD 等) にコピー
- パスワードはパスマネージャに保管
- 復旧不可な状況にならないよう、両方を **別々の場所** に保管する

### 動作確認

```powershell
flutter build apk --release
```

成果物の署名を確認:

```powershell
$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"
$env:PATH = "$env:JAVA_HOME\bin;$env:PATH"
& "$env:LOCALAPPDATA\Android\Sdk\build-tools\36.0.0\apksigner.bat" `
  verify --print-certs build\app\outputs\flutter-apk\app-release.apk
```

`Signer #1 certificate DN: CN=kurage, ...` のように本番鍵の DN が表示されれば OK。
`CN=Android Debug` のままだと debug 鍵で署名されている。

## リリース手順 (Google Play 製品版 / AAB)

**現在の Android 配布の主経路**。Google Play の製品版トラックへ **AAB (App Bundle)** をアップロードする。APK ではアップロードできない。

> **Play App Signing**: アップロード鍵はこのプロジェクトの本番鍵 (`CN=kurage`)。
> Play は配信用 APK を **Google 管理のアプリ署名鍵で再署名**するため、Play 配信版の
> 署名は直接配布 APK (アップロード鍵署名) とは**別物**になる。よって同一端末で
> 「直接配布 APK ⇄ Play 版」を行き来するとアンインストールが必要 (署名衝突)。
> 詳細・経緯は別 PC 同期メモ参照。アプリ署名鍵は Google 生成なので秘密鍵は取得不可
> (= 自前鍵で署名を一致させることはできない)。

1. `pubspec.yaml` の `version:` を更新 (`+BUILD` は必ず +1。**Play は同一 versionCode を弾く**)。判定ルールは APK 節と同じ。
2. `flutter analyze` クリーン確認 + リリースノート作成 (下記「リリースノート」節)。
3. `pubspec.yaml` + リリースノート md をコミット → タグ `vX.Y.Z[-PRERELEASE]` → push (APK 節の手順 3〜5 と同じ)。
4. AAB ビルド:
   ```powershell
   flutter build appbundle --release
   ```
   成果物は `build\app\outputs\bundle\release\app-release.aab`。末尾の
   `failed to strip debug symbols` 警告は**無害** (AAB は正常生成される)。
5. 署名検証 (`CN=kurage` を確認):
   ```bash
   "/c/Program Files/Android/Android Studio/jbr/bin/keytool.exe" \
     -printcert -jarfile build/app/outputs/bundle/release/app-release.aab \
     2>&1 | tr -d '\0' | grep -aoE "CN=kurage[^,]*"
   ```
   ※ Git Bash で `export PATH=".../jbr/bin:$PATH"` は Windows パスの `C:` の `:` が
   PATH 区切りと衝突して効かない。keytool はフルパスで直接叩く。
6. AAB を `dist/kurage-vX.Y.Z[-PRERELEASE].aab` にコピー。
7. **Play Console での操作はユーザー側**: 製品版 → 新しいリリースを作成 →
   AAB をアップロード → 公開。Claude 側はアップロードしない (`adb install` と同じ扱い)。

### Play の一回もの設定 (通常リリースでは触らない)

データセーフティ / 子どもの安全基準 (CSAE, [CHILD_SAFETY_STANDARDS.md](CHILD_SAFETY_STANDARDS.md)) /
権限申告は初回セットアップ済み。**`AndroidManifest.xml` に `uses-permission` を増やした時だけ**
Play の申告見直しが必要 (例: 写真/動画権限を足すと「写真と動画の権限」申告が要求される)。
逆に不要な権限は付けない (image_picker = フォトピッカー / file_selector = SAF なので
メディア選択にストレージ権限は不要)。

## リリース手順 (APK 直接配布) ※現在ストップ中

> **現在は行っていない**。Android は上記 Google Play (AAB) のみ。
> 再開する場合はこの手順で APK を作り `dist/*.apk` に置く。
> (過去のクローズドアルファ / ベータ期間は LINE / Discord などで APK を直接共有していた)

1. `pubspec.yaml` の `version:` を次のバージョンに書き換える
   - バグ修正のみ → PATCH を上げる: `0.1.0-alpha+1` → `0.1.1-alpha+4`
   - 機能追加 / 破壊的変更 → MINOR を上げる: `0.1.5-alpha+10` → `0.2.0-alpha+11`
   - alpha → beta 切り替え時: `0.4.7-alpha+20` → `0.4.8-beta+21`
     (PATCH を 1 進めるか同じにするかは任意。タグ衝突を避けるため進めるのが
     無難)
2. `flutter analyze` がクリーンで通ることを確認
2.5. **テスター向けリリースノートを `release_notes/vX.Y.Z[-PRERELEASE].md` に作成**
   (詳細は下記「リリースノート」節)。次の手順 3 のコミットに含める。
3. コミット: `pubspec.yaml` とリリースノート md を一緒にコミット。
   `git commit -F` で `.git/COMMIT_MSG_TMP` 経由
   (PowerShell の here-string では特殊文字 `<`, `>`, `@` でクォート解釈が
   壊れることがあるため、ファイル経由が安全)
4. タグ付け: `git tag -a vX.Y.Z[-PRERELEASE] -m "..."`
5. push: `git push origin main && git push origin vX.Y.Z[-PRERELEASE]`
6. APK ビルド:
   ```powershell
   flutter build apk --release
   ```
   成果物は `build/app/outputs/flutter-apk/app-release.apk`
7. 署名検証 (上記の `apksigner verify --print-certs` で `CN=kurage` を確認)
8. APK を `dist/kurage-vX.Y.Z[-PRERELEASE].apk` にコピー
9. 端末への `adb install` 等の配布作業はユーザー側で実施
   (Claude 側では実行しない)

## Windows 配布 (Zip ポータブル)

Windows 版は **ポータブル zip** (解凍して `kurage.exe` を実行) と
**インストーラー** (Inno Setup 製 `-setup.exe`。ユーザー単位インストール・UAC 昇格なし・
スタートメニュー登録・アンインストーラー付き) の 2 形式で配布する。
バージョン・`+BUILD` は APK と同じ `pubspec.yaml` から取るので、Android とは
常に同一バージョンになる。

### 前提
- Windows ビルド環境 (VS2022 + C++ ワークロード + ATL コンポーネント、NuGet
  ソース設定)。詳細は [CLAUDE.md](CLAUDE.md)「プラットフォーム固有の注意 > Windows」。
- exe 名 / ウィンドウタイトル / 製品メタデータ / アイコンは「Kurage」ブランドに
  設定済み ([windows/CMakeLists.txt](windows/CMakeLists.txt) `BINARY_NAME=kurage`、
  [windows/runner/Runner.rc](windows/runner/Runner.rc)、
  [windows/runner/resources/app_icon.ico](windows/runner/resources/app_icon.ico))。
  exe のバージョン情報は `FLUTTER_VERSION` (= pubspec) から自動で入る。アイコン
  素材を差し替えたら `dart run tool/gen_windows_icon.dart` で .ico を再生成する。

### 手順
1. APK と同じく `pubspec.yaml` の `version:` を更新済みであること (Android と共通)。
2. zip 生成:
   ```powershell
   pwsh tool\package_windows.ps1
   ```
   - `flutter build windows --release` → Release 一式 + VC++ ランタイム DLL
     (`msvcp140.dll` / `vcruntime140.dll` / `vcruntime140_1.dll`) を app-local 同梱
     → `dist\kurage-vX.Y.Z[-PRERELEASE]-windows.zip` を出力。
   - VC++ ランタイムを同梱するので、テスターは VC++ 再頒布可能パッケージ未導入でも
     起動できる。zip には日本語の `お読みください.txt` も同梱される。
   - 続けて **Inno Setup が導入済みの環境なら** `dist\kurage-vX.Y.Z[-pre]-setup.exe`
     (インストーラー、[tool/installer.iss](tool/installer.iss)) も生成する。無ければ警告して
     zip のみ (ローカル導入は `winget install JRSoftware.InnoSetup`。GitHub Actions の
     windows ランナーには導入済み)。`-SkipInstaller` で明示的に省略も可。
   - ビルド済みなら `pwsh tool\package_windows.ps1 -SkipBuild` で zip だけ作る。
3. 配布は **GitHub Releases** から (下記の自動ビルド参照)。ローカル生成の zip は
   動作確認・緊急時の手動配布用 (`dist/` は `.gitignore` 済みでローカルに残るだけ)。

### GitHub Actions 自動ビルド (配布の主経路)

`v*` タグを push すると
[.github/workflows/release-windows.yml](.github/workflows/release-windows.yml) が
windows ランナーで `tool/package_windows.ps1` を実行し、生成した zip と
インストーラー (`-setup.exe`) を添付した **GitHub Release** を自動作成する。

- Release 本文には `release_notes/v<X.Y.Z>[-pre].md` があればそれを使う (無ければ
  コミットログから自動生成)。プレリリースタグ (`-` 入り) は prerelease 扱いになる。
- Firebase 設定は CI と同じく example のダミーを使用 (Windows は実行時に Firebase を
  使わないので機能差なし)。
- ユーザーへの配布リンクは GitHub Releases のダウンロード URL を案内する
  (従来の Discord 手動配布から移行)。
- 手動確認したい時は Actions タブから workflow_dispatch で実行できる (この場合
  Release は作られず artifact に保存される)。
- **Discord 通知**: Release 作成に成功すると、リポジトリ Secret
  `DISCORD_WEBHOOK_URL` が設定されていればリリースノート本文 (先頭 3800 字) と
  Release URL を Discord Webhook に POST する。**タイミングは Windows 自動ビルド
  完了時点** (Android AAB / Web デプロイはローカル運用のため含まれない、ズレは
  許容)。Secret 未設定なら黙ってスキップし CI は失敗しない。
  - 設定手順 (ユーザー側の一回もの): Discord サーバーの通知したいチャンネルで
    「連携サービスを編集」→「ウェブフックを作成」→ URL をコピー →
    GitHub リポジトリの Settings → Secrets and variables → Actions →
    `New repository secret` で名前 `DISCORD_WEBHOOK_URL` として登録。

### 署名 (未対応) と SmartScreen
- 現状 **コード署名なし**。テスターは初回に「Windows によって PC が保護されました」
  → 「詳細情報」→「実行」が必要 (zip 内の `お読みください.txt` に同手順を記載済み)。
- 将来コード署名証明書を導入する場合は、ビルド後の `kurage.exe` に `signtool sign`
  を挟む (この zip フローの手順 2 と 3 の間)。

## リリースノート

リリースごとに **`release_notes/vX.Y.Z[-PRERELEASE].md`** をリポジトリに保存する
(コミット対象)。タグ push 時に
[.github/workflows/release-windows.yml](.github/workflows/release-windows.yml) が
このファイルを **GitHub Release の本文としてそのまま使う**。

- **一般ユーザー向けの公開文書**として書く (公開リポジトリ上で全世界に見える。
  内輪の連絡先や特定コミュニティ前提の表現は書かない)。書式の見本は
  [release_notes/v1.0.0.md](release_notes/v1.0.0.md)。
- 読みやすい日本語にまとめる (生のコミット件名の羅列にしない)。
  「✨ 新機能 / 🛠 改善・修正 / 📝 既知の注意点」等のカテゴリに整理。
- 元ネタは `git log <前回タグ>..HEAD`。ただし **前回タグをビルドしたが一般公開せず
  スキップした場合は、最後に公開したバージョンまで遡って全部込みで書く**。
- 冒頭付近に配布先 (Android: Google Play / Windows: GitHub Releases の Assets /
  Web: https://kurage.demo2.jp) が分かる記述を置く。Windows は未署名なので初回
  SmartScreen 回避手順 (「詳細情報」→「実行」) を添える。
- 既定 OFF の新機能は「設定でオンにする必要がある」ことを書く。
- バグ報告・要望の導線は GitHub Issues。
- 手順 3 のリリースコミットに含めて、タグにノートも入るようにする。
