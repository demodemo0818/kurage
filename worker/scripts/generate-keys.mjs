/**
 * 初期セットアップ用: Web Push 用の ECDH 鍵ペアと auth_secret を生成する。
 *
 *   node scripts/generate-keys.mjs
 *
 * 出力された 3 つの値を Cloudflare Worker の Secret に登録:
 *   wrangler secret put ECDH_PRIVATE_KEY_PKCS8_B64
 *   wrangler secret put ECDH_PUBLIC_KEY_RAW_B64URL
 *   wrangler secret put AUTH_SECRET_B64URL
 *
 * Public key と auth_secret は Mastodon の購読登録時に
 * アプリ側からも参照する (Worker の /pubkey, /auth エンドポイント経由)。
 */

import { webcrypto } from 'node:crypto';

const { subtle } = webcrypto;

function b64(bytes) {
  return Buffer.from(bytes).toString('base64');
}
function b64url(bytes) {
  return Buffer.from(bytes)
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

const keyPair = await subtle.generateKey(
  { name: 'ECDH', namedCurve: 'P-256' },
  true,
  ['deriveBits'],
);

const privateKeyPkcs8 = await subtle.exportKey('pkcs8', keyPair.privateKey);
const publicKeyRaw = await subtle.exportKey('raw', keyPair.publicKey);

const authSecret = webcrypto.getRandomValues(new Uint8Array(16));

console.log('===== ECDH_PRIVATE_KEY_PKCS8_B64 =====');
console.log(b64(new Uint8Array(privateKeyPkcs8)));
console.log();
console.log('===== ECDH_PUBLIC_KEY_RAW_B64URL =====');
console.log(b64url(new Uint8Array(publicKeyRaw)));
console.log();
console.log('===== AUTH_SECRET_B64URL =====');
console.log(b64url(authSecret));
console.log();
console.log('上記 3 つを wrangler secret put で登録してください。');
