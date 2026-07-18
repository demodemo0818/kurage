# プッシュ通知セットアップガイド

プッシュ通知を実際に動作させるには、以下の設定が必要です。

## 1. Firebaseプロジェクトの作成

1. [Firebase Console](https://console.firebase.google.com/)にアクセス
2. 新しいプロジェクトを作成
3. プロジェクトにAndroidアプリを追加
   - パッケージ名: `com.example.mastodon_app`（実際のパッケージ名に合わせる）
   - SHA-1証明書フィンガープリント（デバッグ用）:
     ```bash
     keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android
     ```

## 2. Android設定

### 2.1 google-services.jsonの配置
1. Firebase ConsoleからAndroidアプリの設定ページへ
2. `google-services.json`をダウンロード
3. ファイルを`android/app/`ディレクトリに配置

### 2.2 build.gradleの設定

`android/build.gradle`:
```gradle
buildscript {
    dependencies {
        // 既存の依存関係に追加
        classpath 'com.google.gms:google-services:4.4.0'
    }
}
```

`android/app/build.gradle`:
```gradle
// ファイルの最下部に追加
apply plugin: 'com.google.gms.google-services'

dependencies {
    // Firebase BOM
    implementation platform('com.google.firebase:firebase-bom:32.7.0')
    implementation 'com.google.firebase:firebase-messaging'
}
```

### 2.3 AndroidManifest.xmlの更新
`android/app/src/main/AndroidManifest.xml.example`の内容を参考に、実際の`AndroidManifest.xml`を更新

## 3. iOS設定（将来的に必要）

### 3.1 GoogleService-Info.plistの配置
1. Firebase ConsoleからiOSアプリの設定ページへ
2. `GoogleService-Info.plist`をダウンロード
3. Xcodeでプロジェクトに追加

### 3.2 APNs証明書の設定
1. Apple Developer ConsoleでAPNs証明書を作成
2. Firebase Consoleにアップロード

### 3.3 Info.plistの更新
```xml
<key>UIBackgroundModes</key>
<array>
    <string>fetch</string>
    <string>remote-notification</string>
</array>
```

## 4. Mastodonサーバー側の考慮事項

Mastodonのプッシュ通知は、Web Push Protocol (RFC 8030) を使用します。
現在の実装では簡易的なFCMエンドポイントを使用していますが、実際には以下が必要です：

1. **VAPIDキーペアの生成**
   ```bash
   npm install -g web-push
   web-push generate-vapid-keys
   ```

2. **適切な暗号化**
   - P-256楕円曲線暗号を使用
   - ECDH (Elliptic Curve Diffie-Hellman) による鍵交換

3. **プロキシサーバー**
   - FCMとMastodonのWeb Push形式を変換するプロキシサーバーが必要な場合があります

## 5. テスト手順

1. Firebaseプロジェクトを作成し、設定ファイルを配置
2. アプリをビルド・実行
3. アプリ設定でプッシュ通知を有効化
4. 別のアカウントからメンションやフォローを行い、通知が届くことを確認

## 注意事項

- デバッグビルドとリリースビルドで異なるSHA-1証明書が必要
- プッシュ通知はエミュレーターでは完全にテストできない場合があります
- バッテリー最適化により、一部のデバイスでは通知が遅延する可能性があります