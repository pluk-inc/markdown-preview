// Share-link API (docs/share-link-plan.md §3). Stores MDP1 envelopes in R2.
// The server never sees a key: it only checks the envelope's magic and size.
// It also serves the web viewer (§5), which decrypts in the browser.

import { HEADER_BYTES, MAGIC, TAG_BYTES, base64Encode, base64urlEncode as base64url, concat } from "../viewer/share-crypto.js";
import { VIEWER_CSP } from "./viewer-csp.ts";
import { ENVELOPE_MARKER } from "./viewer-page.ts";
import type { UploadQuota } from "./upload-quota.ts";

export { UploadQuota } from "./upload-quota.ts";

export interface Env {
  SHARES: R2Bucket;
  ASSETS: Fetcher;
  CREATE_LIMITER?: RateLimit;
  READ_LIMITER?: RateLimit;
  UPLOAD_QUOTA: DurableObjectNamespace<UploadQuota>;
  DAILY_UPLOAD_BYTES: number;
  APPLE_APP_ID: string;
}

const MIN_ENVELOPE_BYTES = HEADER_BYTES + TAG_BYTES;
const MAX_ENVELOPE_BYTES = 5 * 1024 * 1024;
const TTLS: Record<string, number> = {
  "1h": 3_600_000,
  "1d": 86_400_000,
  "7d": 7 * 86_400_000,
  "30d": 30 * 86_400_000,
};
const DEFAULT_TTL = "7d";
const ID_PATTERN = /^[A-Za-z0-9_-]{22}$/;
const SHARE_PATH = /^\/shares\/([^/]+)$/;
const VIEWER_PATH = /^\/s\/([^/]+)\/?$/;
const PREFIX = "shares/";
// The app asks for an envelope with this Accept header. A browser that opens
// /shares/<id> as a link cannot send it, so the route is no file host: the
// bytes reach the app, and readers in a browser use /s/<id>.
export const ENVELOPE_TYPE = "application/vnd.md-preview.envelope";

const BASE_HEADERS = {
  "Cache-Control": "no-store",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
};

type ShareMetadata = { ownerHash: string; expiresAt: string; createdAt: string };

export default {
  async fetch(request, env, ctx): Promise<Response> {
    const url = new URL(request.url);
    const { pathname } = url;

    if (pathname === "/.well-known/apple-app-site-association") {
      return request.method === "GET" || request.method === "HEAD"
        ? appleAppSiteAssociation(env)
        : error(405, "method_not_allowed");
    }

    if (pathname.startsWith("/s/")) {
      return request.method === "GET" || request.method === "HEAD"
        ? viewerPage(request, env, ctx)
        : error(405, "method_not_allowed");
    }

    if (pathname === "/shares") {
      if (request.method !== "POST") return error(405, "method_not_allowed");
      return (await limited(env.CREATE_LIMITER, request)) ?? create(request, env, url);
    }

    const match = SHARE_PATH.exec(pathname);
    if (!match) return error(404, "not_found");
    const id = match[1];
    if (!ID_PATTERN.test(id)) return error(404, "not_found");

    switch (request.method) {
      case "GET":
        if (request.headers.get("Accept") !== ENVELOPE_TYPE) return error(404, "not_found");
        return (await limited(env.READ_LIMITER, request)) ?? read(id, env, ctx);
      case "PUT":
        return (await limited(env.CREATE_LIMITER, request)) ?? update(id, request, env, url);
      case "DELETE":
        return (await limited(env.CREATE_LIMITER, request)) ?? remove(id, request, env);
      default:
        return error(405, "method_not_allowed");
    }
  },

  // Daily backstop for shares nobody fetched after they expired.
  async scheduled(_controller, env): Promise<void> {
    await purgeExpired(env.SHARES, Date.now());
  },
} satisfies ExportedHandler<Env>;

// MARK: - Routes

async function create(request: Request, env: Env, url: URL): Promise<Response> {
  const ttl = ttlMillis(url);
  if (ttl === undefined) return error(400, "invalid_ttl");
  const body = await envelope(request);
  if (body instanceof Response) return body;
  const full = await overQuota(env, body.byteLength);
  if (full) return full;

  const id = base64url(randomBytes(16));
  const ownerToken = base64url(randomBytes(32));
  const now = Date.now();
  const expiresAt = new Date(now + ttl).toISOString();
  const metadata: ShareMetadata = {
    ownerHash: await sha256Hex(ownerToken),
    expiresAt,
    createdAt: new Date(now).toISOString(),
  };
  await env.SHARES.put(PREFIX + id, body, { customMetadata: metadata });
  return json(201, { id, ownerToken, expiresAt });
}

async function read(id: string, env: Env, ctx: ExecutionContext): Promise<Response> {
  const object = await liveShare(id, env, ctx);
  if (!object) return error(404, "not_found");
  return new Response(object.body, {
    headers: {
      ...BASE_HEADERS,
      "Content-Type": ENVELOPE_TYPE,
      "Content-Length": String(object.size),
    },
  });
}

async function update(id: string, request: Request, env: Env, url: URL): Promise<Response> {
  const ttl = ttlMillis(url);
  if (ttl === undefined) return error(400, "invalid_ttl");
  // The owner check and the upload do not wait for each other.
  const [existing, body] = await Promise.all([authorizedShare(id, request, env), envelope(request)]);
  if (existing instanceof Response) return existing;
  if (body instanceof Response) return body;
  // The full size counts, not the growth: an update also renews the expiry,
  // and the quota bounds the bucket only if every renewal pays for its bytes.
  const full = await overQuota(env, body.byteLength);
  if (full) return full;

  const expiresAt = new Date(Date.now() + ttl).toISOString();
  // Only replace the object that was checked: a Stop Sharing (or another
  // update) that lands while this upload is read must not be undone.
  const written = await env.SHARES.put(PREFIX + id, body, {
    customMetadata: { ...existing.metadata, expiresAt },
    onlyIf: { etagMatches: existing.etag },
  });
  if (written) return json(200, { expiresAt });
  // The object changed after the check: gone means revoked; still there
  // means another update won, and the link is still live and owned.
  return (await env.SHARES.head(PREFIX + id)) ? error(409, "conflict") : error(404, "not_found");
}

async function remove(id: string, request: Request, env: Env): Promise<Response> {
  const existing = await authorizedShare(id, request, env);
  if (existing instanceof Response) return existing;
  await env.SHARES.delete(PREFIX + id);
  return new Response(null, { status: 204, headers: BASE_HEADERS });
}

// /s/<id> answers with the viewer page; the page reads the key from the URL
// fragment, which never reaches this Worker. Its files under /s/_viewer/
// are static assets and never reach the Worker either.
//
// The page carries the encrypted envelope, so the reader needs one request,
// not a page and then a fetch. The head goes out at once, so the browser
// gets the scripts and styles while R2 is read; the envelope follows at the
// end of the body as a data block, which runs nothing and so passes the CSP.
async function viewerPage(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const headers = {
    ...BASE_HEADERS,
    "Content-Type": "text/html; charset=utf-8",
    "Content-Security-Policy": VIEWER_CSP,
    "X-Frame-Options": "DENY",
    "Cross-Origin-Opener-Policy": "same-origin",
  };
  // The share lookup does not wait for the page file.
  const id = VIEWER_PATH.exec(new URL(request.url).pathname)?.[1] ?? "";
  const share = request.method === "HEAD" ? null : pageShare(id, request, env, ctx);
  const page = await env.ASSETS.fetch(new URL("/s/_viewer/index.html", request.url));
  if (!page.ok) return error(404, "not_found");
  if (!share) return new Response(null, { headers });

  // build.mjs checks that the page has the marker exactly once.
  const [head, tail] = (await page.text()).split(ENVELOPE_MARKER);
  const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>();
  const writer = writable.getWriter();
  const encoder = new TextEncoder();
  const write = (text: string) => writer.write(encoder.encode(text));
  ctx.waitUntil((async () => {
    await write(head);
    const found = await share;
    await write(`<script id="mdp-envelope" type="application/octet-stream" data-status="${found.status}">`);
    if (found.status === "ok") {
      for await (const piece of base64Pieces(found.object.body)) await write(piece);
    }
    await write(`</script>${tail}`);
    await writer.close();
  })().catch((reason) => writer.abort(reason)));
  return new Response(readable, { headers });
}

type PageShare = { status: "ok"; object: R2ObjectBody } | { status: "not_found" | "unavailable" };

// The share for /s/<id>, or the status the page shows instead.
async function pageShare(id: string, request: Request, env: Env, ctx: ExecutionContext): Promise<PageShare> {
  if (!ID_PATTERN.test(id)) return { status: "not_found" };
  try {
    if (await limited(env.READ_LIMITER, request)) return { status: "unavailable" };
    const object = await liveShare(id, env, ctx);
    return object ? { status: "ok", object } : { status: "not_found" };
  } catch {
    return { status: "unavailable" };
  }
}

// The stream as base64, piece by piece, as R2 delivers it. Each piece ends on
// a multiple of 3 bytes, so the pieces join into one valid base64 text.
async function* base64Pieces(stream: ReadableStream<Uint8Array>): AsyncGenerator<string> {
  const reader = stream.getReader();
  let carry = new Uint8Array(0);
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      const bytes = carry.byteLength > 0 ? concat([carry, value]) : value;
      const whole = bytes.byteLength - (bytes.byteLength % 3);
      if (whole > 0) yield base64Encode(bytes.subarray(0, whole));
      carry = bytes.slice(whole);
    }
    if (carry.byteLength > 0) yield base64Encode(carry);
  } finally {
    // A reader that closed the page stops the loop early: stop the R2 read too.
    await reader.cancel().catch(() => {});
  }
}

function appleAppSiteAssociation(env: Env): Response {
  const body = {
    applinks: {
      details: [{ appIDs: [env.APPLE_APP_ID], components: [{ "/": "/s/*" }] }],
    },
  };
  return new Response(JSON.stringify(body), {
    headers: { "Content-Type": "application/json", "X-Content-Type-Options": "nosniff" },
  });
}

// MARK: - Checks

// The share's object, or null when it is missing or expired; an expired
// one is deleted on the way.
async function liveShare(id: string, env: Env, ctx: ExecutionContext): Promise<R2ObjectBody | null> {
  const object = await env.SHARES.get(PREFIX + id);
  if (!object) return null;
  if (isExpired(object.customMetadata, Date.now())) {
    ctx.waitUntil(env.SHARES.delete(PREFIX + id));
    return null;
  }
  return object;
}

// The share's metadata when the bearer token matches its owner hash.
// Missing, expired, and wrong-token shares all answer 404, so a request
// cannot tell whether an ID exists.
async function authorizedShare(
  id: string,
  request: Request,
  env: Env,
): Promise<{ metadata: ShareMetadata; etag: string } | Response> {
  const header = request.headers.get("Authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : "";
  if (!token) return error(401, "unauthorized");

  const object = await env.SHARES.head(PREFIX + id);
  const metadata = object?.customMetadata as ShareMetadata | undefined;
  if (!metadata?.ownerHash || isExpired(metadata, Date.now())) return error(404, "not_found");

  const given = new TextEncoder().encode(await sha256Hex(token));
  const stored = new TextEncoder().encode(metadata.ownerHash);
  if (given.byteLength !== stored.byteLength || !crypto.subtle.timingSafeEqual(given, stored)) {
    return error(404, "not_found");
  }
  return { metadata, etag: object!.etag };
}

// The request body when it is an MDP1 envelope within the size limits.
async function envelope(request: Request): Promise<Uint8Array | Response> {
  const declared = Number(request.headers.get("Content-Length") ?? "0");
  if (declared > MAX_ENVELOPE_BYTES) return error(413, "too_large");

  const bytes = await readCapped(request, MAX_ENVELOPE_BYTES);
  if (!bytes) return error(413, "too_large");
  if (bytes.byteLength < MIN_ENVELOPE_BYTES || !MAGIC.every((b, i) => bytes[i] === b)) {
    return error(400, "invalid_envelope");
  }
  return bytes;
}

// The body, or null once it passes `limit`. Read in chunks, so a request
// without Content-Length cannot make the Worker hold an oversized upload.
async function readCapped(request: Request, limit: number): Promise<Uint8Array | null> {
  if (!request.body) return new Uint8Array();
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > limit) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  return concat(chunks);
}

async function limited(limiter: RateLimit | undefined, request: Request): Promise<Response | null> {
  if (!limiter) return null;
  const key = request.headers.get("CF-Connecting-IP") ?? "unknown";
  const { success } = await limiter.limit({ key });
  return success ? null : error(429, "rate_limited");
}

// 503 once today's uploaded bytes, from every IP together, would pass the limit.
async function overQuota(env: Env, bytes: number): Promise<Response | null> {
  const quota = env.UPLOAD_QUOTA.getByName("global");
  return (await quota.reserve(bytes, env.DAILY_UPLOAD_BYTES)) ? null : error(503, "quota_exceeded");
}

function ttlMillis(url: URL): number | undefined {
  const ttl = url.searchParams.get("ttl") ?? DEFAULT_TTL;
  return Object.hasOwn(TTLS, ttl) ? TTLS[ttl] : undefined;
}

function isExpired(metadata: Record<string, string> | undefined, now: number): boolean {
  const expiresAt = Date.parse(metadata?.expiresAt ?? "");
  return Number.isNaN(expiresAt) || expiresAt <= now;
}

// MARK: - Expiry

export async function purgeExpired(bucket: R2Bucket, now: number): Promise<number> {
  let deleted = 0;
  let cursor: string | undefined;
  do {
    const page = await bucket.list({ prefix: PREFIX, cursor, include: ["customMetadata"] });
    const expired = page.objects
      .filter((object) => isExpired(object.customMetadata, now))
      .map((object) => object.key);
    if (expired.length > 0) {
      await bucket.delete(expired);
      deleted += expired.length;
    }
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  return deleted;
}

// MARK: - Helpers

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...BASE_HEADERS, "Content-Type": "application/json" },
  });
}

function error(status: number, code: string): Response {
  return json(status, { error: code });
}

function randomBytes(count: number): Uint8Array {
  return crypto.getRandomValues(new Uint8Array(count));
}

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
