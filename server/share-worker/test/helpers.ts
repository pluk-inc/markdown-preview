import { exports } from "cloudflare:workers";
import fixture from "../../../tests/fixtures/share-link/vectors.json";

export const ORIGIN = "https://share.example";

export function hex(text: string): Uint8Array {
  return new Uint8Array(text.match(/../g)!.map((byte) => parseInt(byte, 16)));
}

export const envelope = hex(fixture.vectors[0].envelope);

// Each test gets its own IP so the rate limiter does not carry over.
export function call(path: string, init: RequestInit = {}, ip = crypto.randomUUID()): Promise<Response> {
  const headers = new Headers(init.headers);
  headers.set("CF-Connecting-IP", ip);
  return exports.default.fetch(new Request(ORIGIN + path, { ...init, headers }));
}

export const auth = (token: string) => ({ Authorization: `Bearer ${token}` });
