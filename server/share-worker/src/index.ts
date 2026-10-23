// Share-link API (docs/share-link-plan.md §3). Stores MDP1 envelopes in R2.
// The server never sees a key: it only checks the envelope's magic and size.

export interface Env {
  SHARES: R2Bucket;
  CREATE_LIMITER?: RateLimit;
  READ_LIMITER?: RateLimit;
  APPLE_APP_ID: string;
}

const MAGIC = new TextEncoder().encode("MDP1");
const MIN_ENVELOPE_BYTES = 53; // 37-byte header + 16-byte tag
const MAX_ENVELOPE_BYTES = 5 * 1024 * 1024;
const TTLS: Record<string, number> = {
  "1h": 3_600_000,
  "1d": 86_400_000,
  "7d": 7 * 86_400_000,
  "30d": 30 * 86_400_000,
};
const DEFAULT_TTL = "7d";
const ID_PATTERN = /^[A-Za-z0-9_-]{22}$/;
const SHARE_PATH = /^\/api\/v1\/shares\/([^/]+)$/;
const PREFIX = "shares/";

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

    if (pathname === "/api/v1/shares") {
      if (request.method !== "POST") return error(405, "method_not_allowed");
      return (await limited(env.CREATE_LIMITER, request)) ?? create(request, env, url);
    }

    const match = SHARE_PATH.exec(pathname);
    if (!match) return error(404, "not_found");
    const id = match[1];
    if (!ID_PATTERN.test(id)) return error(404, "not_found");

    switch (request.method) {
      case "GET":
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
  const object = await env.SHARES.get(PREFIX + id);
  if (!object) return error(404, "not_found");
  if (isExpired(object.customMetadata, Date.now())) {
    ctx.waitUntil(env.SHARES.delete(PREFIX + id));
    return error(404, "not_found");
  }
  return new Response(object.body, {
    headers: {
      ...BASE_HEADERS,
      "Content-Type": "application/octet-stream",
      "Content-Length": String(object.size),
    },
  });
}

async function update(id: string, request: Request, env: Env, url: URL): Promise<Response> {
  const ttl = ttlMillis(url);
  if (ttl === undefined) return error(400, "invalid_ttl");
  const existing = await authorizedShare(id, request, env);
  if (existing instanceof Response) return existing;
  const body = await envelope(request);
  if (body instanceof Response) return body;

  const expiresAt = new Date(Date.now() + ttl).toISOString();
  await env.SHARES.put(PREFIX + id, body, {
    customMetadata: { ...existing, expiresAt },
  });
  return json(200, { expiresAt });
}

async function remove(id: string, request: Request, env: Env): Promise<Response> {
  const existing = await authorizedShare(id, request, env);
  if (existing instanceof Response) return existing;
  await env.SHARES.delete(PREFIX + id);
  return new Response(null, { status: 204, headers: BASE_HEADERS });
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

// The share's metadata when the bearer token matches its owner hash.
// Missing, expired, and wrong-token shares all answer 404, so a request
// cannot tell whether an ID exists.
async function authorizedShare(
  id: string,
  request: Request,
  env: Env,
): Promise<ShareMetadata | Response> {
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
  return metadata;
}

// The request body when it is an MDP1 envelope within the size limits.
async function envelope(request: Request): Promise<ArrayBuffer | Response> {
  const declared = Number(request.headers.get("Content-Length") ?? "0");
  if (declared > MAX_ENVELOPE_BYTES) return error(413, "too_large");

  const body = await request.arrayBuffer();
  if (body.byteLength > MAX_ENVELOPE_BYTES) return error(413, "too_large");
  const bytes = new Uint8Array(body);
  if (bytes.byteLength < MIN_ENVELOPE_BYTES || !MAGIC.every((b, i) => bytes[i] === b)) {
    return error(400, "invalid_envelope");
  }
  return body;
}

async function limited(limiter: RateLimit | undefined, request: Request): Promise<Response | null> {
  if (!limiter) return null;
  const key = request.headers.get("CF-Connecting-IP") ?? "unknown";
  const { success } = await limiter.limit({ key });
  return success ? null : error(429, "rate_limited");
}

function ttlMillis(url: URL): number | undefined {
  return TTLS[url.searchParams.get("ttl") ?? DEFAULT_TTL];
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

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
