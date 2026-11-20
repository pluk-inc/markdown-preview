// The app's update feed moved with its bundle id. Copies from before the
// move (0.0.73 and earlier) ask Amore for the feed of `doc.md-preview`, and
// that feed gets no release any more: releases go to `sh.pluk.md-preview`.
// A Workers Route sends requests for the old feed here, and this answers
// them with the new one, so those copies still find their update.
//
// Until the new feed has a release, and whenever it cannot be read, the
// request goes on to Amore untouched and the old feed answers as before.

export const FEED_HOST = "release.md-preview.app";
export const OLD_FEED_PATH = "/v1/apps/doc.md-preview/appcast.xml";
export const NEW_FEED_PATH = "/v1/apps/sh.pluk.md-preview/appcast.xml";

/// A feed with nothing to download, or one cut short, would tell an old
/// copy that there is no version at all: only a whole feed with a download
/// link takes the old feed's place.
function hasDownload(feed: string): boolean {
  return /<enclosure\b[^>]*\burl="https:\/\/[^"]+"/.test(feed) && /<\/rss>\s*$/.test(feed);
}

type Fetcher = (input: Request | URL | string, init?: RequestInit) => Promise<Response>;

export async function updateFeed(request: Request, url: URL, origin: Fetcher = fetch): Promise<Response> {
  const isRead = request.method === "GET" || request.method === "HEAD";
  if (!isRead || url.pathname !== OLD_FEED_PATH) return origin(request);

  try {
    const moved = await origin(new URL(NEW_FEED_PATH, url), { headers: { Accept: "application/xml" } });
    if (moved.ok) {
      const feed = await moved.text();
      if (hasDownload(feed)) {
        return new Response(request.method === "HEAD" ? null : feed, {
          headers: {
            "Content-Type": moved.headers.get("Content-Type") ?? "application/xml; charset=utf-8",
            "Cache-Control": "no-store",
          },
        });
      }
    }
  } catch {
    // Fall through to the old feed.
  }
  return origin(request);
}
