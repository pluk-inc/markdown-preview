import { runInDurableObject } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { expect, it } from "vitest";
import { auth, call, envelope } from "./helpers.ts";

// In a file of its own: it fills the day's quota, which every upload in
// this file's Worker then shares.

it("counts every IP's uploads against one daily limit", async () => {
  const created = await call("/shares", { method: "POST", body: envelope });
  expect(created.status).toBe(201);
  const { id, ownerToken } = (await created.json()) as Record<string, string>;

  // Another IP takes what is left of today's bytes.
  const quota = env.UPLOAD_QUOTA.getByName("global");
  expect(await quota.reserve(env.DAILY_UPLOAD_BYTES - envelope.byteLength, env.DAILY_UPLOAD_BYTES)).toBe(true);

  const refused = await call("/shares", { method: "POST", body: envelope });
  expect(refused.status).toBe(503);
  expect(await refused.json()).toEqual({ error: "quota_exceeded" });

  // An update renews the link, so it counts its full size too.
  const update = await call(`/shares/${id}`, { method: "PUT", body: envelope, headers: auth(ownerToken) });
  expect(update.status).toBe(503);
});

it("starts each UTC day from zero", async () => {
  const quota = env.UPLOAD_QUOTA.getByName("day-change");
  await runInDurableObject(quota, (_, state) => state.storage.kv.put("usage", { day: "2026-01-01", bytes: 10 }));
  expect(await quota.reserve(10, 10)).toBe(true);
  expect(await quota.reserve(1, 10)).toBe(false);
});
