import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import fixture from "../../../tests/fixtures/share-link/vectors.json";
import { purgeExpired } from "../src/index";

const ORIGIN = "https://share.example";

function hex(text: string): Uint8Array {
  return new Uint8Array(text.match(/../g)!.map((byte) => parseInt(byte, 16)));
}

const envelope = hex(fixture.vectors[0].envelope);

// Each test gets its own IP so the rate limiter does not carry over.
function call(path: string, init: RequestInit = {}, ip = crypto.randomUUID()): Promise<Response> {
  const headers = new Headers(init.headers);
  headers.set("CF-Connecting-IP", ip);
  return exports.default.fetch(new Request(ORIGIN + path, { ...init, headers }));
}

async function create(body: BodyInit = envelope, query = "") {
  const response = await call(`/api/v1/shares${query}`, { method: "POST", body });
  return { response, body: (await response.json()) as Record<string, string> };
}

const auth = (token: string) => ({ Authorization: `Bearer ${token}` });

describe("create and read", () => {
  it("stores every vector envelope and returns the same bytes", async () => {
    for (const vector of fixture.vectors) {
      const bytes = hex(vector.envelope);
      const { response, body } = await create(bytes);
      expect(response.status, vector.name).toBe(201);
      expect(body.id).toMatch(/^[A-Za-z0-9_-]{22}$/);
      expect(body.ownerToken).toMatch(/^[A-Za-z0-9_-]{43}$/);

      const read = await call(`/api/v1/shares/${body.id}`);
      expect(read.status).toBe(200);
      expect(read.headers.get("Content-Type")).toBe("application/octet-stream");
      expect(new Uint8Array(await read.arrayBuffer())).toEqual(bytes);
    }
  });

  it("defaults to seven days and accepts the other TTLs", async () => {
    const before = Date.now();
    const { body } = await create();
    const ttl = Date.parse(body.expiresAt) - before;
    expect(ttl).toBeGreaterThan(7 * 86_400_000 - 5_000);
    expect(ttl).toBeLessThanOrEqual(7 * 86_400_000 + 5_000);

    for (const value of ["1h", "1d", "30d"]) {
      expect((await create(envelope, `?ttl=${value}`)).response.status).toBe(201);
    }
    for (const value of ["never", "2d", ""]) {
      const { response, body } = await create(envelope, `?ttl=${value}`);
      expect(response.status, value).toBe(400);
      expect(body.error).toBe("invalid_ttl");
    }
  });

  it("stores only a hash of the owner token", async () => {
    const { body } = await create();
    const object = await env.SHARES.head(`shares/${body.id}`);
    expect(object?.customMetadata?.ownerHash).toMatch(/^[0-9a-f]{64}$/);
    expect(JSON.stringify(object?.customMetadata)).not.toContain(body.ownerToken);
  });

  it("rejects bodies that are not MDP1 envelopes", async () => {
    const wrongMagic = envelope.slice();
    wrongMagic[0] = 0x58;
    for (const bad of [new Uint8Array(), envelope.slice(0, 52), wrongMagic]) {
      const { response, body } = await create(bad);
      expect(response.status).toBe(400);
      expect(body.error).toBe("invalid_envelope");
    }
  });

  it("rejects bodies over 5 MB", async () => {
    const big = new Uint8Array(5 * 1024 * 1024 + 1);
    big.set(envelope);
    const { response, body } = await create(big);
    expect(response.status).toBe(413);
    expect(body.error).toBe("too_large");
  });

  it("answers 404 for unknown and malformed IDs", async () => {
    for (const id of ["AAAAAAAAAAAAAAAAAAAAAA", "short", "..%2F..%2Fsecret"]) {
      const response = await call(`/api/v1/shares/${id}`);
      expect(response.status, id).toBe(404);
    }
  });

  it("deletes a share on the first read after it expires", async () => {
    const { body } = await create();
    const key = `shares/${body.id}`;
    const object = await env.SHARES.get(key);
    await env.SHARES.put(key, await object!.arrayBuffer(), {
      customMetadata: { ...object!.customMetadata, expiresAt: new Date(Date.now() - 1).toISOString() },
    });

    expect((await call(`/api/v1/shares/${body.id}`)).status).toBe(404);
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(await env.SHARES.head(key)).toBeNull();
  });
});

describe("update and delete", () => {
  it("replaces the content and extends the expiry with the owner token", async () => {
    const { body } = await create(envelope, "?ttl=1h");
    const replacement = hex(fixture.vectors[1].envelope);
    const response = await call(`/api/v1/shares/${body.id}?ttl=30d`, {
      method: "PUT",
      headers: auth(body.ownerToken),
      body: replacement,
    });
    expect(response.status).toBe(200);
    const updated = (await response.json()) as { expiresAt: string };
    expect(Date.parse(updated.expiresAt)).toBeGreaterThan(Date.parse(body.expiresAt));

    const read = await call(`/api/v1/shares/${body.id}`);
    expect(new Uint8Array(await read.arrayBuffer())).toEqual(replacement);
  });

  it("deletes with the owner token", async () => {
    const { body } = await create();
    const response = await call(`/api/v1/shares/${body.id}`, {
      method: "DELETE",
      headers: auth(body.ownerToken),
    });
    expect(response.status).toBe(204);
    expect((await call(`/api/v1/shares/${body.id}`)).status).toBe(404);
  });

  it("refuses a missing or wrong token without revealing the share", async () => {
    const { body } = await create();
    const other = await create();
    const noToken = await call(`/api/v1/shares/${body.id}`, { method: "DELETE" });
    expect(noToken.status).toBe(401);

    for (const method of ["PUT", "DELETE"]) {
      const response = await call(`/api/v1/shares/${body.id}`, {
        method,
        headers: auth(other.body.ownerToken),
        body: method === "PUT" ? envelope : undefined,
      });
      expect(response.status, method).toBe(404);
    }
    expect((await call(`/api/v1/shares/${body.id}`)).status).toBe(200);
  });
});

describe("expiry purge", () => {
  it("deletes only expired shares", async () => {
    const live = (await create()).body.id;
    const old = (await create(envelope, "?ttl=1h")).body.id;
    const deleted = await purgeExpired(env.SHARES, Date.now() + 2 * 3_600_000);
    expect(deleted).toBeGreaterThanOrEqual(1);
    expect(await env.SHARES.head(`shares/${old}`)).toBeNull();
    expect(await env.SHARES.head(`shares/${live}`)).not.toBeNull();
  });
});

describe("headers and routing", () => {
  it("sets the privacy headers on API responses", async () => {
    const { response } = await create();
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(response.headers.get("X-Content-Type-Options")).toBe("nosniff");
    expect(response.headers.get("Referrer-Policy")).toBe("no-referrer");
  });

  it("serves the apple-app-site-association file for /s/*", async () => {
    const response = await call("/.well-known/apple-app-site-association");
    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Type")).toBe("application/json");
    expect(await response.json()).toEqual({
      applinks: {
        details: [{ appIDs: ["5P3TSMNV42.doc.md-preview"], components: [{ "/": "/s/*" }] }],
      },
    });
  });

  it("rejects other methods and paths", async () => {
    expect((await call("/api/v1/shares")).status).toBe(405);
    expect((await call("/api/v1/shares/AAAAAAAAAAAAAAAAAAAAAA", { method: "POST" })).status).toBe(405);
    expect((await call("/")).status).toBe(404);
  });

  it("rate-limits creates per IP", async () => {
    const statuses: number[] = [];
    for (let i = 0; i < 12; i++) {
      const response = await call("/api/v1/shares", { method: "POST", body: envelope }, "203.0.113.9");
      statuses.push(response.status);
    }
    expect(statuses.slice(0, 10).every((status) => status === 201)).toBe(true);
    expect(statuses.at(-1)).toBe(429);
  });
});
