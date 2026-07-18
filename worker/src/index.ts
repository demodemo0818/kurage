/**
 * Kurage Push Relay
 *
 * Mastodon Web Push (RFC 8291, aes128gcm) を受信して復号し、
 * FCM HTTP v1 API 経由で端末へ転送する Cloudflare Worker。
 *
 * リクエスト形式:
 *   POST /relay/{fcm_token}
 *   Body: aes128gcm 形式の暗号化ペイロード
 *
 * Mastodon サーバには下記 endpoint で購読登録する:
 *   https://<this-worker-url>/relay/<fcm_token>
 *
 * 環境変数 (wrangler.jsonc 参照):
 *   FIREBASE_PROJECT_ID
 *   FIREBASE_CLIENT_EMAIL
 *   FIREBASE_PRIVATE_KEY
 *   ECDH_PRIVATE_KEY_PKCS8_B64
 *   ECDH_PUBLIC_KEY_RAW_B64URL
 *   AUTH_SECRET_B64URL
 */

interface Env {
  FIREBASE_PROJECT_ID: string;
  FIREBASE_CLIENT_EMAIL: string;
  FIREBASE_PRIVATE_KEY: string;
  ECDH_PRIVATE_KEY_PKCS8_B64: string;
  ECDH_PUBLIC_KEY_RAW_B64URL: string;
  AUTH_SECRET_B64URL: string;
}

// アクセストークンを isolate ライフタイム中キャッシュ
let cachedAccessToken: { token: string; expiresAt: number } | null = null;

// FCM トークンが失効している (アプリ再インストール・トークンローテート等) ことを
// 表すエラー。Mastodon へ 410 を返して購読を自動 deactivate させるために、
// その他の一時的な失敗 (500) と区別する。
class FcmUnregisteredError extends Error {}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    // ヘルスチェック / 公開鍵公開
    if (request.method === 'GET' && url.pathname === '/pubkey') {
      return new Response(env.ECDH_PUBLIC_KEY_RAW_B64URL, {
        headers: { 'Content-Type': 'text/plain' },
      });
    }
    if (request.method === 'GET' && url.pathname === '/auth') {
      return new Response(env.AUTH_SECRET_B64URL, {
        headers: { 'Content-Type': 'text/plain' },
      });
    }
    if (request.method === 'GET' && url.pathname === '/') {
      return new Response('Kurage Push Relay OK', { status: 200 });
    }

    // リレー本体
    const match = url.pathname.match(/^\/relay\/(.+)$/);
    if (request.method === 'POST' && match) {
      // 不正な % シーケンスで decodeURIComponent が throw すると Worker
      // 例外 (1101) になるため、400 に倒す
      let fcmToken: string;
      try {
        fcmToken = decodeURIComponent(match[1]);
      } catch {
        return new Response('invalid token', { status: 400 });
      }
      try {
        const body = new Uint8Array(await request.arrayBuffer());
        const encoding =
          request.headers.get('content-encoding')?.toLowerCase() ?? 'aesgcm';
        let plaintext: string;
        if (encoding === 'aes128gcm') {
          plaintext = await decryptAes128gcm(body, env);
        } else {
          // Mastodon を含む多くの実装は aesgcm を使う
          const cryptoKey = request.headers.get('crypto-key') ?? '';
          const encryption = request.headers.get('encryption') ?? '';
          plaintext = await decryptAesgcm(body, cryptoKey, encryption, env);
        }
        const payload = JSON.parse(plaintext);
        await sendFcm(fcmToken, payload, env);
        // Mastodon は 201 を期待する
        return new Response('', { status: 201 });
      } catch (e) {
        if (e instanceof FcmUnregisteredError) {
          // トークン失効。410 を返すと Mastodon が購読を deactivate し、
          // 以後この endpoint への POST が止まる (stale 購読の掃除)
          console.log('stale subscription, telling Mastodon to drop it:', e.message);
          return new Response('gone', { status: 410 });
        }
        // 復号失敗の詳細 (パディング不正・鍵不一致等) は攻撃者に有用な
        // 情報になるため、レスポンスには含めずログにのみ残す
        console.error('relay failed:', e);
        return new Response('relay failed', { status: 500 });
      }
    }

    return new Response('Not Found', { status: 404 });
  },
};

// =================== Web Push 復号 (新形式 RFC 8291 aes128gcm) ===================

async function decryptAes128gcm(body: Uint8Array, env: Env): Promise<string> {
  // aes128gcm body header: salt(16) | rs(4) | idlen(1) | keyid(idlen=65) | ciphertext
  if (body.length < 21) throw new Error('body too short');
  const salt = body.subarray(0, 16);
  const idlen = body[20];
  if (idlen !== 65) throw new Error(`unexpected idlen: ${idlen}`);
  const senderPubRaw = body.subarray(21, 21 + 65);
  const ciphertext = body.subarray(21 + 65);

  const privateKey = await importEcdhPrivateKey(env.ECDH_PRIVATE_KEY_PKCS8_B64);
  const ecdhSecret = await deriveEcdhSecret(privateKey, senderPubRaw);

  const authSecret = b64urlDecode(env.AUTH_SECRET_B64URL);
  const uaPublic = b64urlDecode(env.ECDH_PUBLIC_KEY_RAW_B64URL);
  const info = concat(utf8('WebPush: info\0'), uaPublic, senderPubRaw);
  const ikm = await hkdf(authSecret, ecdhSecret, info, 32);

  const cek = await hkdf(salt, ikm, utf8('Content-Encoding: aes128gcm\0'), 16);
  const nonce = await hkdf(salt, ikm, utf8('Content-Encoding: nonce\0'), 12);

  const decrypted = await aesGcmDecrypt(cek, nonce, ciphertext);

  // RFC 8188 のパディング除去: 末尾の 0x02 以降を捨てる
  let end = decrypted.length;
  while (end > 0 && decrypted[end - 1] === 0x00) end--;
  if (end === 0 || decrypted[end - 1] !== 0x02) {
    throw new Error('invalid padding delimiter');
  }
  end--;
  return new TextDecoder().decode(decrypted.subarray(0, end));
}

// =================== Web Push 復号 (旧形式 aesgcm, Mastodon 含む大半が使う) ===================

async function decryptAesgcm(
  body: Uint8Array,
  cryptoKeyHeader: string,
  encryptionHeader: string,
  env: Env,
): Promise<string> {
  // ヘッダから sender pubkey と salt を取り出す
  const senderPubB64url = parseHeaderField(cryptoKeyHeader, 'dh');
  const saltB64url = parseHeaderField(encryptionHeader, 'salt');
  if (!senderPubB64url || !saltB64url) {
    throw new Error('Crypto-Key/Encryption header missing dh= or salt=');
  }
  const senderPubRaw = b64urlDecode(senderPubB64url);
  const salt = b64urlDecode(saltB64url);
  const ciphertext = body;

  const privateKey = await importEcdhPrivateKey(env.ECDH_PRIVATE_KEY_PKCS8_B64);
  const ecdhSecret = await deriveEcdhSecret(privateKey, senderPubRaw);

  const authSecret = b64urlDecode(env.AUTH_SECRET_B64URL);
  const uaPublic = b64urlDecode(env.ECDH_PUBLIC_KEY_RAW_B64URL);

  // aesgcm の context: "P-256\0" || len(uaPub)BE || uaPub || len(senderPub)BE || senderPub
  const context = concat(
    utf8('P-256\0'),
    new Uint8Array([0, 65]),
    uaPublic,
    new Uint8Array([0, 65]),
    senderPubRaw,
  );
  const cekInfo = concat(utf8('Content-Encoding: aesgcm\0'), context);
  const nonceInfo = concat(utf8('Content-Encoding: nonce\0'), context);

  // 旧形式は二段階 HKDF: まず auth_secret を salt に
  const ikm = await hkdf(
    authSecret,
    ecdhSecret,
    utf8('Content-Encoding: auth\0'),
    32,
  );
  const cek = await hkdf(salt, ikm, cekInfo, 16);
  const nonce = await hkdf(salt, ikm, nonceInfo, 12);

  const decrypted = await aesGcmDecrypt(cek, nonce, ciphertext);

  // 旧形式のパディング: 先頭 2 byte (BE) がパディング長、その後パディング、その後本文
  if (decrypted.length < 2) throw new Error('decrypted too short');
  const padLen = (decrypted[0] << 8) | decrypted[1];
  if (2 + padLen > decrypted.length) throw new Error('invalid padding');
  return new TextDecoder().decode(decrypted.subarray(2 + padLen));
}

function parseHeaderField(header: string, field: string): string | null {
  // 例: "dh=BHk2W...; p256ecdsa=BAB..." から dh の値を抽出
  for (const part of header.split(/[,;]/)) {
    const trimmed = part.trim();
    const eq = trimmed.indexOf('=');
    if (eq < 0) continue;
    const k = trimmed.substring(0, eq).trim();
    const v = trimmed.substring(eq + 1).trim();
    if (k === field) return v.replace(/^"|"$/g, '');
  }
  return null;
}

async function deriveEcdhSecret(
  privateKey: CryptoKey,
  senderPubRaw: Uint8Array,
): Promise<Uint8Array> {
  const senderPubKey = await crypto.subtle.importKey(
    'raw',
    senderPubRaw,
    { name: 'ECDH', namedCurve: 'P-256' },
    false,
    [],
  );
  return new Uint8Array(
    await crypto.subtle.deriveBits(
      // @cloudflare/workers-types は `public` を予約語回避で `$public` に
      // リネームしているが、ランタイムは標準どおり `public` を期待する
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      { name: 'ECDH', public: senderPubKey } as any,
      privateKey,
      256,
    ),
  );
}

async function aesGcmDecrypt(
  cek: Uint8Array,
  nonce: Uint8Array,
  ciphertext: Uint8Array,
): Promise<Uint8Array> {
  const aesKey = await crypto.subtle.importKey(
    'raw',
    cek,
    { name: 'AES-GCM' },
    false,
    ['decrypt'],
  );
  return new Uint8Array(
    await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: nonce },
      aesKey,
      ciphertext,
    ),
  );
}

async function importEcdhPrivateKey(b64: string): Promise<CryptoKey> {
  const der = b64Decode(b64);
  return crypto.subtle.importKey(
    'pkcs8',
    der,
    { name: 'ECDH', namedCurve: 'P-256' },
    false,
    ['deriveBits'],
  );
}

async function hkdf(
  salt: Uint8Array,
  ikm: Uint8Array,
  info: Uint8Array,
  length: number,
): Promise<Uint8Array> {
  const baseKey = await crypto.subtle.importKey(
    'raw',
    ikm,
    { name: 'HKDF' },
    false,
    ['deriveBits'],
  );
  const bits = await crypto.subtle.deriveBits(
    { name: 'HKDF', hash: 'SHA-256', salt, info },
    baseKey,
    length * 8,
  );
  return new Uint8Array(bits);
}

// =================== FCM HTTP v1 送信 ===================

interface MastodonPushPayload {
  access_token?: string;
  notification_id?: string | number;
  notification_type?: string;
  preferred_locale?: string;
  title?: string;
  body?: string;
  icon?: string;
}

async function sendFcm(
  fcmToken: string,
  payload: MastodonPushPayload,
  env: Env,
): Promise<void> {
  const accessToken = await getFcmAccessToken(env);

  // すべて文字列で送る (FCM data メッセージは string only)
  const data: Record<string, string> = {};
  for (const [k, v] of Object.entries(payload)) {
    if (v !== undefined && v !== null) data[k] = String(v);
  }

  const message = {
    message: {
      token: fcmToken,
      // notification キーを入れると OS が自動表示してしまい、Dart 側で
      // データを整形できないので data のみで送る
      data,
      android: {
        priority: 'HIGH' as const,
      },
    },
  };

  const url = `https://fcm.googleapis.com/v1/projects/${env.FIREBASE_PROJECT_ID}/messages:send`;
  const resp = await fetch(url, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(message),
  });
  if (!resp.ok) {
    const text = await resp.text();
    // 404/410 or errorCode UNREGISTERED / NOT_FOUND = このトークン宛の配送は
    // 永久に不能 (アプリ再インストール等) → 購読を消してよい。
    // 400 INVALID_ARGUMENT はペイロード側の問題の可能性があるので含めない。
    if (
      resp.status === 404 ||
      resp.status === 410 ||
      text.includes('UNREGISTERED') ||
      text.includes('NOT_FOUND')
    ) {
      throw new FcmUnregisteredError(`FCM token gone ${resp.status}: ${text}`);
    }
    throw new Error(`FCM send failed ${resp.status}: ${text}`);
  }
}

async function getFcmAccessToken(env: Env): Promise<string> {
  const now = Date.now();
  if (cachedAccessToken && cachedAccessToken.expiresAt > now + 60_000) {
    return cachedAccessToken.token;
  }

  const iat = Math.floor(now / 1000);
  const exp = iat + 3600;

  const header = { alg: 'RS256', typ: 'JWT' };
  const claim = {
    iss: env.FIREBASE_CLIENT_EMAIL,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    exp,
    iat,
  };

  const signingInput =
    b64urlEncode(utf8(JSON.stringify(header))) +
    '.' +
    b64urlEncode(utf8(JSON.stringify(claim)));

  const privateKey = await importRsaPrivateKey(env.FIREBASE_PRIVATE_KEY);
  const sig = new Uint8Array(
    await crypto.subtle.sign(
      'RSASSA-PKCS1-v1_5',
      privateKey,
      utf8(signingInput),
    ),
  );
  const jwt = signingInput + '.' + b64urlEncode(sig);

  const resp = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body:
      'grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=' +
      encodeURIComponent(jwt),
  });
  if (!resp.ok) {
    throw new Error(`token exchange failed: ${resp.status} ${await resp.text()}`);
  }
  const json = (await resp.json()) as { access_token: string; expires_in: number };
  cachedAccessToken = {
    token: json.access_token,
    expiresAt: now + json.expires_in * 1000,
  };
  return json.access_token;
}

async function importRsaPrivateKey(pem: string): Promise<CryptoKey> {
  // PEM の改行が \n でエスケープされている可能性に対応
  const cleaned = pem
    .replace(/\\n/g, '\n')
    .replace('-----BEGIN PRIVATE KEY-----', '')
    .replace('-----END PRIVATE KEY-----', '')
    .replace(/\s+/g, '');
  const der = b64Decode(cleaned);
  return crypto.subtle.importKey(
    'pkcs8',
    der,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
}

// =================== ユーティリティ ===================

function utf8(s: string): Uint8Array {
  return new TextEncoder().encode(s);
}

function concat(...parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(total);
  let off = 0;
  for (const p of parts) {
    out.set(p, off);
    off += p.length;
  }
  return out;
}

function b64Decode(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function b64urlDecode(b64url: string): Uint8Array {
  let s = b64url.replace(/-/g, '+').replace(/_/g, '/');
  while (s.length % 4) s += '=';
  return b64Decode(s);
}

function b64urlEncode(bytes: Uint8Array): string {
  let s = '';
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
