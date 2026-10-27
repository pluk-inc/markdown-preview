// The bytes uploaded each UTC day, across every IP (docs/share-link-plan.md
// §3). The per-IP rate limit slows one sender; this caps what all senders
// together can add to the bucket, so its size and cost have a ceiling. One
// instance counts for the whole Worker, and a Durable Object runs one call at
// a time, so two uploads cannot both take the last bytes.

import { DurableObject } from "cloudflare:workers";

type Usage = { day: string; bytes: number };

export class UploadQuota extends DurableObject {
  /** Adds `bytes` to today's total and returns true, or returns false
   * without adding when the total would pass `limit`. */
  reserve(bytes: number, limit: number): boolean {
    const day = new Date().toISOString().slice(0, 10);
    const stored = this.ctx.storage.kv.get<Usage>("usage");
    const used = stored?.day === day ? stored.bytes : 0;
    if (used + bytes > limit) return false;
    this.ctx.storage.kv.put("usage", { day, bytes: used + bytes } satisfies Usage);
    return true;
  }
}
