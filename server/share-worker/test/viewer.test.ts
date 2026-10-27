// The web viewer's decryption and payload checks, run in the Workers runtime,
// which has the same WebCrypto and DecompressionStream as browsers. The
// vectors are the ones the app's Swift tests seal.
import { describe, expect, it } from "vitest";
import fixture from "../../../tests/fixtures/share-link/vectors.json";
import { hex } from "./helpers.ts";
import { ShareError, openEnvelope, parseLink } from "../viewer/share-crypto.js";
import { assetPathForSource, decodePayload, displayTitle, normalizedAssetPath } from "../viewer/payload.js";
import { LANGUAGES, pickLanguage, strings } from "../viewer/strings.js";

describe("page text", () => {
  it("has every string in every language", () => {
    const keys = Object.keys(strings("en")).sort();
    expect(LANGUAGES.sort()).toEqual(["en", "fa", "ja", "pl", "zh-Hans"]);
    for (const language of LANGUAGES) {
      const table = strings(language) as Record<string, string>;
      expect(Object.keys(table).sort(), language).toEqual(keys);
      expect(table.hiddenImageMany, language).toContain("{count}");
    }
  });

  it("picks the reader's language, falling back to English", () => {
    expect(pickLanguage(["ja-JP", "en-US"])).toBe("ja");
    expect(pickLanguage(["zh-CN"])).toBe("zh-Hans");
    expect(pickLanguage(["zh-TW", "fa-IR"])).toBe("fa");
    expect(pickLanguage(["de-DE", "fr"])).toBe("en");
    expect(pickLanguage([])).toBe("en");
  });
});

function linkParts(link: string) {
  const url = new URL(link);
  return parseLink(url.pathname, url.hash);
}

describe("share links", () => {
  it("parses every vector link and keeps the password marker", () => {
    for (const vector of fixture.vectors) {
      const link = linkParts(vector.link);
      expect(link, vector.name).not.toBeNull();
      expect(link!.hasPassword).toBe(vector.password !== null);
    }
  });

  it("drops tracking parameters after the key", () => {
    const { link } = fixture.vectors[0];
    expect(linkParts(`${link}&utm_source=chat`)).toEqual(linkParts(link));
  });

  it("rejects links without a valid id or key", () => {
    const { link } = fixture.vectors[0];
    const url = new URL(link);
    expect(parseLink(url.pathname, "")).toBeNull();
    expect(parseLink(url.pathname, url.hash.slice(0, -1))).toBeNull();
    expect(parseLink("/s/short", url.hash)).toBeNull();
    expect(parseLink("/x/" + url.pathname.slice(3), url.hash)).toBeNull();
  });
});

describe("envelopes", () => {
  it("opens every vector to the app's plaintext", async () => {
    for (const vector of fixture.vectors) {
      const link = linkParts(vector.link)!;
      const plaintext = await openEnvelope(hex(vector.envelope), link.key, vector.password);
      expect(new TextDecoder().decode(plaintext), vector.name).toBe(vector.plaintext);
    }
  });

  it("asks for a password before decrypting a password envelope", async () => {
    const vector = fixture.vectors.find((v) => v.password !== null)!;
    const envelope = hex(vector.envelope);
    await expect(openEnvelope(envelope, linkParts(vector.link)!.key, null))
      .rejects.toMatchObject({ code: "password" });
  });

  it("fails authentication for a wrong key or an altered byte", async () => {
    const vector = fixture.vectors[0];
    const envelope = hex(vector.envelope);
    const key = linkParts(vector.link)!.key;
    await expect(openEnvelope(envelope, new Uint8Array(32), null)).rejects.toMatchObject({ code: "auth" });
    const altered = envelope.slice();
    altered[40] ^= 1;
    await expect(openEnvelope(altered, key, null)).rejects.toBeInstanceOf(ShareError);
  });
});

describe("payloads", () => {
  it("decodes every vector plaintext with its assets", () => {
    for (const vector of fixture.vectors) {
      const payload = decodePayload(new TextEncoder().encode(vector.plaintext));
      expect(payload.markdown.length, vector.name).toBeGreaterThan(0);
    }
    const withAsset = fixture.vectors.find((v) => v.name === "with-asset")!;
    const payload = decodePayload(new TextEncoder().encode(withAsset.plaintext));
    expect(payload.assets.map((a: { path: string }) => a.path)).toEqual(["img/dot.png"]);
    expect(payload.assets[0].data[1]).toBe(0x50); // "P" of the PNG signature
  });

  it("keeps a web image's source and refuses one that is not a web address", () => {
    const payload = (source: string) => new TextEncoder().encode(JSON.stringify({
      v: 1, title: "a.md", markdown: "m", html: "h",
      assets: [{ path: "web/1.png", type: "image/png", data: "AQ==", source }],
    }));
    expect(decodePayload(payload("https://example.com/x.png")).assets[0].source).toBe("https://example.com/x.png");
    for (const source of ["javascript:alert(1)", "file:///etc/passwd", "img/x.png", "https://"]) {
      expect(() => decodePayload(payload(source)), source).toThrow();
    }
  });

  it("refuses asset paths that leave the document's folder", () => {
    for (const path of ["../x.png", "/x.png", "a\\b.png", "", "./", "a/../../x.png"]) {
      expect(normalizedAssetPath(path), path).toBeNull();
    }
    expect(normalizedAssetPath("./img//x.png")).toBe("img/x.png");
  });

  it("maps image sources to asset paths the way the app collects them", () => {
    expect(assetPathForSource("img/My%20Photo.jpg?v=2")).toBe("img/My Photo.jpg");
    expect(assetPathForSource("img/../x.png")).toBe("x.png");
    expect(assetPathForSource("../x.png")).toBeNull();
    expect(assetPathForSource("https://example.com/x.png")).toBeNull();
    expect(assetPathForSource("data:image/png;base64,AA")).toBeNull();
  });

  it("cleans titles for display", () => {
    expect(displayTitle(" ../evil\n/name:\u0007.md ")).toBe("..evilname.md");
  });
});
