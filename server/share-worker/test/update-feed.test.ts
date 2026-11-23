import { describe, expect, it } from "vitest";
import { NEW_FEED_PATH, OLD_FEED_PATH, updateFeed } from "../src/update-feed";

const HOST = "https://release.md-preview.app";
const NEW_FEED = `<rss><channel><item><enclosure url="https://cdn.example/new.dmg"/></item></channel></rss>`;
const OLD_FEED = `<rss><channel><item><enclosure url="https://cdn.example/old.dmg"/></item></channel></rss>`;

/** Amore, with `newFeed` as what it has at the new path. */
function origin(newFeed: Response | Error) {
  const seen: string[] = [];
  const fetcher = async (input: Request | URL | string) => {
    const url = new URL(input instanceof Request ? input.url : input);
    seen.push(url.pathname + url.search);
    if (url.pathname === NEW_FEED_PATH) {
      if (newFeed instanceof Error) throw newFeed;
      return newFeed;
    }
    return new Response(url.pathname === OLD_FEED_PATH ? OLD_FEED : "other", { status: 200 });
  };
  return { fetcher, seen };
}

function ask(path: string, fetcher: ReturnType<typeof origin>["fetcher"], init: RequestInit = {}) {
  const request = new Request(HOST + path, init);
  return updateFeed(request, new URL(request.url), fetcher);
}

describe("the update feed of the earlier bundle id", () => {
  it("answers with the new feed once it has a release", async () => {
    const { fetcher } = origin(new Response(NEW_FEED, { headers: { "Content-Type": "application/xml" } }));
    const response = await ask(`${OLD_FEED_PATH}?osVersion=15.0`, fetcher);
    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Type")).toBe("application/xml");
    expect(await response.text()).toBe(NEW_FEED);
  });

  it("keeps the old feed while the new one has no release", async () => {
    const unusable = [
      new Response("<rss><channel></channel></rss>"),
      new Response("no", { status: 404 }),
      // An enclosure with no link, and a feed cut short.
      new Response("<rss><channel><item><enclosure/></item></channel></rss>"),
      new Response(NEW_FEED.slice(0, NEW_FEED.indexOf("</item>"))),
    ];
    for (const empty of unusable) {
      const { fetcher } = origin(empty);
      expect(await (await ask(OLD_FEED_PATH, fetcher)).text()).toBe(OLD_FEED);
    }
  });

  it("keeps the old feed when the new one cannot be read", async () => {
    const { fetcher } = origin(new Error("network"));
    expect(await (await ask(OLD_FEED_PATH, fetcher)).text()).toBe(OLD_FEED);
  });

  it("answers HEAD without a body", async () => {
    const { fetcher } = origin(new Response(NEW_FEED));
    const response = await ask(OLD_FEED_PATH, fetcher, { method: "HEAD" });
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("");
  });

  it("passes every other request on to the host", async () => {
    const { fetcher, seen } = origin(new Response(NEW_FEED));
    expect(await (await ask("/v1/apps/other/appcast.xml", fetcher)).text()).toBe("other");
    expect(await (await ask(OLD_FEED_PATH, fetcher, { method: "POST" })).text()).toBe(OLD_FEED);
    expect(seen).not.toContain(NEW_FEED_PATH);
  });
});
