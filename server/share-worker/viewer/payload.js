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
    seen.add(path);
    return { path, type, data: Uint8Array.from(atob(asset.data), (c) => c.charCodeAt(0)) };
  });
  return { title: raw.title, markdown: raw.markdown, html: raw.html, assets };
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
