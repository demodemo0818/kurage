// lib/services/app_lock_service.dart

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// アプリロック機能の PIN ハッシュ管理 + 生体認証ラッパー。
///
/// - PIN は SHA-256 + ランダムソルトでハッシュ化して
///   `flutter_secure_storage` (Android Keystore / iOS Keychain) に保存する。
///   平文 PIN や `SharedPreferences` には保存しない。
/// - 生体認証は `local_auth` を使い、利用可否の判定 + 認証実行のみ責務を持つ。
class AppLockService {
  AppLockService._();
  static final AppLockService instance = AppLockService._();

  // SecureStorage キー
  static const _pinHashKey = 'app_lock_pin_hash';
  static const _pinSaltKey = 'app_lock_pin_salt';

  // flutter_secure_storage 10 で encryptedSharedPreferences オプションは廃止
  // (Jetpack Crypto 廃止に伴い新 cipher が既定化)。既存データは既定の
  // migrateOnAlgorithmChange: true で初回アクセス時に自動移行される。
  static const _storage = FlutterSecureStorage();

  final LocalAuthentication _localAuth = LocalAuthentication();

  // ---- PIN ----

  /// PIN が設定済みかどうか
  Future<bool> hasPin() async {
    final hash = await _storage.read(key: _pinHashKey);
    return hash != null && hash.isNotEmpty;
  }

  /// PIN を設定 (既存の値は上書き)
  Future<void> setPin(String pin) async {
    final salt = _generateSalt();
    final hash = _hashPin(pin, salt);
    await _storage.write(key: _pinSaltKey, value: salt);
    await _storage.write(key: _pinHashKey, value: hash);
  }

  /// 入力された PIN がハッシュと一致するか検証
  Future<bool> verifyPin(String pin) async {
    final salt = await _storage.read(key: _pinSaltKey);
    final hash = await _storage.read(key: _pinHashKey);
    if (salt == null || hash == null) return false;
    return _hashPin(pin, salt) == hash;
  }

  /// PIN を完全に削除 (アプリロックを無効化したとき等)
  Future<void> clearPin() async {
    await _storage.delete(key: _pinHashKey);
    await _storage.delete(key: _pinSaltKey);
  }

  /// コールドスタート時、永続化された設定からロックすべきかを返す。
  /// `main()` で `runApp` 前に呼び、戻り値で AppLockNotifier の初期状態を決める。
  ///
  /// 直接 SharedPreferences の `appearanceSettings` JSON を覗くため
  /// settings_provider の `Settings.fromJson` のロードを待たずに同期的に
  /// 結論を出せる (=最初のフレームから正しくロック状態で描画できる)。
  Future<bool> shouldStartLocked() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('appearanceSettings');
      if (raw == null) return false;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return json['appLockEnabled'] == true;
    } catch (e) {
      debugPrint('shouldStartLocked error: $e');
      return false;
    }
  }

  String _generateSalt() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64Encode(bytes);
  }

  String _hashPin(String pin, String salt) {
    final bytes = utf8.encode('$salt:$pin');
    return sha256.convert(bytes).toString();
  }

  // ---- 生体認証 ----

  /// 端末で生体認証が利用可能か
  Future<bool> canUseBiometrics() async {
    // local_auth は Web 未対応 (MissingPluginException が出る)。catch でも
    // 拾えるが、無駄なコール + ログ汚しを避けるため明示的に短絡する。
    if (kIsWeb) return false;
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      final isSupported = await _localAuth.isDeviceSupported();
      if (!canCheck || !isSupported) return false;
      final available = await _localAuth.getAvailableBiometrics();
      return available.isNotEmpty;
    } catch (e) {
      debugPrint('canUseBiometrics error: $e');
      return false;
    }
  }

  /// 生体認証で解除を試みる。成功時 true。
  /// ユーザーがキャンセルした、または失敗した場合は false を返す
  /// (PIN フォールバックに任せる)。
  Future<bool> authenticateWithBiometrics() async {
    try {
      // local_auth 3 で AuthenticationOptions は廃止され名前付き引数に変わった。
      // stickyAuth → persistAcrossBackgrounding (ダイアログ閉じるとプロセスが
      // 死ぬ端末対策)。useErrorDialogs は代替なしで廃止 (失敗時は下の catch →
      // PIN フォールバックに任せる)。
      return await _localAuth.authenticate(
        localizedReason: 'アプリのロックを解除',
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
    } catch (e) {
      debugPrint('authenticateWithBiometrics error: $e');
      return false;
    }
  }
}
