// Reads share links and opens MDP1 envelopes in the browser, matching the
// app's ShareLink.swift and ShareLinkCrypto.swift (docs/share-link-plan.md §2).
// Runs in the browser and in the Workers runtime for tests.

// The envelope format; the Worker checks uploads against these too.
export const MAGIC = [0x4d, 0x44, 0x50, 0x31]; // "MDP1"
export const HEADER_BYTES = 37;
export const TAG_BYTES = 16;
const KEY_BYTES = 32;
const ID_BYTES = 16;
const PASSWORD_FLAG = 0b1;
const MAX_ITERATIONS = 10_000_000;
/** Cap on the inflated plaintext, so a small hostile envelope cannot expand into gigabytes. */
export const MAX_PLAINTEXT_BYTES = 64 * 1024 * 1024;
const INFO = new TextEncoder().encode("md-preview share v1");

export class ShareError extends Error {
  /** @param {"malformed" | "password" | "auth" | "tooLarge"} code */
  constructor(code) {
    super(code);
    this.code = code;
  }
}

/** RFC 4648 §5 base64url without padding; null for anything non-canonical. */
export function base64urlDecode(text) {
  if (!/^[A-Za-z0-9_-]*$/.test(text) || text.length % 4 === 1) return null;
  const base64 = text.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((text.length + 3) % 4);
  let binary;
  try {
    binary = atob(base64);
  } catch {
    return null;
  }
  const bytes = Uint8Array.from(binary, (c) => c.charCodeAt(0));
  return base64urlEncode(bytes) === text ? bytes : null;
}

export function base64urlEncode(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/**
 * The share in `/s/<id>#<key>` (or `#p.<key>`), or null. Chat apps append
 * tracking parameters to the fragment, so it ends at the first `&`.
 */
export function parseLink(pathname, hash) {
  const match = /^\/s\/([A-Za-z0-9_-]+)\/?$/.exec(pathname);
  if (!match || base64urlDecode(match[1])?.length !== ID_BYTES) return null;
  const fragment = hash.replace(/^#/, "").split("&")[0];
  const hasPassword = fragment.startsWith("p.");
  const key = base64urlDecode(hasPassword ? fragment.slice(2) : fragment);
  if (!key || key.length !== KEY_BYTES) return null;
  return { id: match[1], key, hasPassword, fragment };
}

/** Decrypts and inflates an envelope; `password` is ignored when the envelope has none. */
export async function openEnvelope(envelope, key, password) {
  if (key.length !== KEY_BYTES || envelope.length < HEADER_BYTES + TAG_BYTES || !hasMagic(envelope)) {
    throw new ShareError("malformed");
  }
  const flags = envelope[4];
  const iterations = new DataView(envelope.buffer, envelope.byteOffset + 5, 4).getUint32(0);
  // Views, not copies: WebCrypto copies what it is given.
  const salt = envelope.subarray(9, 25);
  const nonce = envelope.subarray(25, 37);
  const header = envelope.subarray(0, HEADER_BYTES);
  const sealed = envelope.subarray(HEADER_BYTES);

  let inputKeyMaterial = key;
  if (flags & PASSWORD_FLAG) {
    if (password == null) throw new ShareError("password");
    if (iterations === 0 || iterations > MAX_ITERATIONS) throw new ShareError("malformed");
    const passwordKey = await crypto.subtle.importKey(
      "raw", new TextEncoder().encode(password.normalize("NFC")), "PBKDF2", false, ["deriveBits"]);
    const bits = await crypto.subtle.deriveBits(
      { name: "PBKDF2", hash: "SHA-256", salt, iterations }, passwordKey, 256);
    inputKeyMaterial = concat(key, new Uint8Array(bits));
  }

  const hkdfKey = await crypto.subtle.importKey("raw", inputKeyMaterial, "HKDF", false, ["deriveKey"]);
  const contentKey = await crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt, info: INFO },
    hkdfKey, { name: "AES-GCM", length: 256 }, false, ["decrypt"]);

  let deflated;
  try {
    deflated = new Uint8Array(await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: nonce, additionalData: header }, contentKey, sealed));
  } catch {
    throw new ShareError("auth");
  }
  return inflate(deflated, MAX_PLAINTEXT_BYTES);
}

async function inflate(bytes, limit) {
  const stream = new Response(bytes).body.pipeThrough(new DecompressionStream("deflate-raw"));
  const reader = stream.getReader();
  const chunks = [];
  let total = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.length;
      if (total > limit) {
        await reader.cancel();
        throw new ShareError("tooLarge");
      }
      chunks.push(value);
    }
  } catch (error) {
    throw error instanceof ShareError ? error : new ShareError("malformed");
  }
  return concat(...chunks);
}

function hasMagic(bytes) {
  return MAGIC.every((byte, index) => bytes[index] === byte);
}

function concat(...parts) {
  const result = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    result.set(part, offset);
    offset += part.length;
  }
  return result;
}
