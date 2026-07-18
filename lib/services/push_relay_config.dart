// lib/services/push_relay_config.dart

/// Cloudflare Worker のリレー URL
///
/// この URL の `/relay/<fcm_token>` を Mastodon の Web Push の endpoint として
/// 登録する。Worker 側のソースは ../../worker/ ディレクトリ。
///
/// 公開鍵 / auth_secret は Worker の `/pubkey`, `/auth` から取得する。
const String pushRelayBaseUrl = 'https://kurage-push-relay.demodemo2.workers.dev';
