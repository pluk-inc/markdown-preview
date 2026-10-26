// The JSON document inside an envelope, matching the app's SharePayload.swift.
// Everything here is hostile input: anyone can build an envelope without the app.

const CURRENT_VERSION = 1;
const ALLOWED_ASSET_TYPES = new Set([
  "image/png", "image/jpeg", "image/gif", "image/webp", "image/avif", "image/svg+xml",
]);
const MAX_TITLE_LENGTH = 200;

/** Validates and decodes the plaintext; throws on anything the app would refuse. */
export function decodePayload(plaintext) {
  const raw = JSON.parse(new TextDecoder().decode(plaintext));
  if (raw?.v !== CURRENT_VERSION) throw new Error("unsupported version");
  for (const field of ["title", "markdown", "html"]) {
    if (typeof raw[field] !== "string") throw new Error(`missing ${field}`);
  }
  if (!Array.isArray(raw.assets)) throw new Error("missing assets");

  const seen = new Set();
  const assets = raw.assets.map((asset) => {
    const path = normalizedAssetPath(asset?.path);
    const type = typeof asset?.type === "string" ? asset.type.toLowerCase() : "";
    if (path == null) throw new Error("invalid asset path");
    if (!ALLOWED_ASSET_TYPES.has(type)) throw new Error("unsupported asset type");
    if (seen.has(path)) throw new Error("duplicate asset path");
    if (typeof asset.data !== "string") throw new Error("invalid asset data");
    // A web image's address in the document, as SharePayload.isWebSource checks it.
    if (asset.source != null && !isWebSource(asset.source)) throw new Error("invalid asset source");
    seen.add(path);
    return { path, type, data: base64Bytes(asset.data), source: asset.source ?? null };
  });
  return { title: raw.title, markdown: raw.markdown, html: raw.html, assets };
}

/** An `http` or `https` address with a host, at most 4096 characters. */
export function isWebSource(source) {
  if (typeof source !== "string" || source.length > 4096) return false;
  try {
    const url = new URL(source);
    return (url.protocol === "http:" || url.protocol === "https:") && url.hostname !== "";
  } catch {
    return false;
  }
}

/**
 * A relative path with `.` and empty segments dropped. Null for an absolute
 * path, a `..` segment, a backslash, a NUL, or nothing left.
 */
export function normalizedAssetPath(path) {
  if (typeof path !== "string" || path.startsWith("/") || /[\\\0]/.test(path)) return null;
  const segments = path.split("/").filter((segment) => segment !== "" && segment !== ".");
  if (segments.length === 0 || segments.includes("..")) return null;
  return segments.join("/");
}

/**
 * The asset path an `<img src>` in the rendered HTML points at, resolving
 * `.` and `..` the way the app's collector does; null for a URL with a
 * scheme, an absolute path, or one that leaves the document's folder.
 */
export function assetPathForSource(source) {
  if (!source || /^[a-z][a-z0-9+.-]*:/i.test(source) || source.startsWith("/") || source.startsWith("#")) {
    return null;
  }
  let path = source.split(/[?#]/)[0];
  try {
    path = decodeURIComponent(path);
  } catch {
    return null;
  }
  const resolved = [];
  for (const segment of path.split("/")) {
    if (segment === "" || segment === ".") continue;
    if (segment === "..") {
      if (resolved.length === 0) return null;
      resolved.pop();
    } else {
      resolved.push(segment);
    }
  }
  return resolved.length ? resolved.join("/") : null;
}

/** The title safe to show: control characters and path separators removed, length capped. */
export function displayTitle(title) {
  const cleaned = title.replace(/[\u0000-\u001f\u007f-\u009f/:]/g, "").trim();
  return cleaned.slice(0, MAX_TITLE_LENGTH);
}

/** Decodes base64 natively where the browser can, else in one plain loop. */
export function base64Bytes(text) {
  if (Uint8Array.fromBase64) return Uint8Array.fromBase64(text);
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}
