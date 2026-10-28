# Share via link — plan

Status: draft, 2026-10-16; revised 2026-10-27. On for everyone since 0.0.70,
with no switch: the format and crypto (§2), the
Worker API and its deploy setup on `md-preview.app` (§3), and sharing from the
app (§4.1–4.4), the web viewer (§5), and opening links
in the app (§4.5). Universal Links (§4.5) are blocked: the `doc.md-preview`
App ID belongs to another team.

Goal: from an open Markdown document, the user creates a random link. Anyone
with the link can read the document in a browser, or open it in Markdown
Preview. The server stores only ciphertext and can never read a document.
When the app is installed, the viewer's "Open in Markdown Preview" button
opens the link in the app. Opening it in the app directly needs Universal
Links (§4.5), which are blocked for now.

Order of work: **the app first, the web viewer later.** Phase 1 ships a small
API Worker (the app cannot upload without one) and the full app side. Links
created in phase 1 open in the app only. Phase 2 adds the browser viewer at the
same URLs, so phase 1 links start to work in browsers without any change.

Reference studied: PrivateBin (HEAD `a0533e5`, 2026-10-14). We copy its design,
not its code or its wire format — see "Why not the PrivateBin format".

### Build, don't deploy an existing service (decided 2026-10-23)

We looked for an open-source service to deploy as-is: PrivateBin, a PrivateBin
v2–compatible Workers port (ZeroBin), DedPaste (Workers + R2), binthere
(Workers + KV + Durable Object), Cryptgeon (Docker + in-memory Redis), and
CloudPaste (Workers + R2, password only — the server can read documents). None
fits: the PrivateBin-compatible ones force the wire format we reject in §2, and
none gives us the app side or a viewer that renders like the app. The Worker
API in §3 is four routes; the real work is the app (§4) and the viewer (§5).
Use these projects as references for R2 expiry, rate limits, and viewer CSP
only, after checking their licences.

---

## 1. Threat model

| We protect against | How |
| --- | --- |
| Our server, Cloudflare, or an R2 leak reading documents | Encryption in the client; the key lives only in the URL fragment, which browsers never send |
| Guessing links | 128-bit random ID **and** a 256-bit key; either one alone is useless |
| A stranger deleting or replacing a share | Random owner token per share; the server stores only `SHA-256(token)` |
| The server swapping or altering a blob | AES-GCM authentication; the header is authenticated data |
| XSS through attacker-written Markdown (phase 2) | Sanitizer with an explicit allowlist, strict CSP, separate origin, no third-party scripts |
| Link-preview bots consuming a burn-after-reading share (phase 2) | Confirm step before fetch (PrivateBin's `#-` lesson) |

We do **not** protect against: a person who has the link (the link *is* the
secret), a compromised viewer page served by us (same trust model as
PrivateBin — the README must say this), or metadata (we see IPs, sizes, times).

Lesson from PrivateBin's CVE history: almost every bug was in rendering
decrypted, attacker-controlled content and file names — not in the crypto.
Spend review effort there.

## 2. Format (`mdp1`)

### Link

```
https://md-preview.app/s/<id>#<key>
```

- `id`: 16 random bytes from the server, base64url, no padding (22 chars).
- `key`: 32 random bytes from the client, base64url, no padding (43 chars).
- Password-protected shares use `#p.<key>` so the viewer knows to ask first.
- On parse, cut the fragment at the first `&` (social sites append tracking
  params — PrivateBin CHANGELOG).
- In-app form: `md-preview://share/<id>#<key>` (same fragment).

### Key derivation

- No password: `contentKey = HKDF-SHA256(ikm: K, salt: header.salt, info: "md-preview share v1")`.
- Password: `pw = PBKDF2-HMAC-SHA256(UTF-8(NFC(password)), salt: header.salt, iterations: 600_000, 32 bytes)`,
  then `contentKey = HKDF-SHA256(ikm: K ‖ pw, salt: header.salt, info: "md-preview share v1")`.
- Swift: CryptoKit `HKDF<SHA256>`; CommonCrypto `CCKeyDerivationPBKDF` for PBKDF2.
  Web: WebCrypto `HKDF` and `PBKDF2`. No extra libraries on either side.

### Envelope (binary, what the server stores)

| Bytes | Field |
| --- | --- |
| 4 | magic `MDP1` |
| 1 | flags (bit 0 = password) |
| 4 | PBKDF2 iterations, big-endian (0 when no password) |
| 16 | salt |
| 12 | nonce |
| rest | AES-256-GCM ciphertext ‖ 16-byte tag |

Authenticated data = the first 37 bytes (magic through nonce). A new nonce and
salt on every upload, including updates.

### Plaintext

Raw DEFLATE (Swift `NSData.compressed(using: .zlib)`; web
`DecompressionStream("deflate-raw")`) of UTF-8 JSON:

```json
{
  "v": 1,
  "title": "README.md",
  "markdown": "# Hello…",
  "html": "<rendered body from MarkdownHTML>",
  "assets": [
    { "path": "img/diagram.png", "type": "image/png", "data": "<base64>" },
    { "path": "web/1.png", "type": "image/png", "data": "<base64>",
      "source": "https://example.com/chart.png" }
  ]
}
```

An asset with `source` is an image from the web, downloaded by the app when
it made the link; `source` is the address the document uses for it (`http`
or `https` only). The web viewer shows the asset wherever the HTML uses that
address, so the image travels inside the encrypted share and no other server
learns who opened the link. Not yet: a share opened in the app does not show
these images. The app blocks web content in a received share and does not
write these assets to disk, because the Markdown names them by their web
address; showing them needs the app's renderer to map each address to its
asset, as the viewer does.

`html` is the body the app's own renderer (`MarkdownHTML`, swift-markdown)
produced at upload time. Only the web viewer uses it (§5), so the browser shows
what the app shows without a second Markdown parser. The app ignores it and
renders `markdown` again when it opens a share. A share keeps the render of its
upload time; renderer changes reach it only on "Update Link Content".

`title`, `path`, and `html` are hostile input on the reading side: anyone can
build an envelope without the app. Never use them as a
file system path without normalising and confining them; never put them into
HTML without escaping.

### Why not the PrivateBin format

Compatibility would let PrivateBin instances host our shares, but the format has
traps that cost more than they give:

- It keeps only the low byte of each password character (`"€"` → `0xAC`).
- It uses a 16-byte GCM nonce; CryptoKit support for that is unverified.
- It runs 100k PBKDF2 rounds even without a password.
- Its AAD is `JSON.stringify(adata)`, which Swift must reproduce byte for byte.
- The paste ID is a 64-bit hash of the ciphertext, and deletion uses `GET`.

We control both ends, so a small clean format is safer. A "custom PrivateBin
server" option can come later as a separate feature if people ask.

### Test vectors

Commit fixed vectors (key, salt, nonce, password, plaintext → envelope bytes)
in `tests/fixtures/share-link/`. The Swift tests and (phase 2) a Node/WebCrypto
test both read them, so the two implementations cannot drift.

## 3. Server API (Cloudflare Worker + R2)

Lives in `server/share-worker/` in this repo (decided 2026-10-23), at least
until phase 2 is done. Reasons:

- The test vectors in `tests/fixtures/share-link/` are read by both the Swift
  and the Worker tests; one repo lets one PR change format, app, and Worker
  together, so they cannot drift.
- The phase 2 viewer reuses app files — `md-preview/Vendor/`, the DOMPurify
  config, the stylesheet — directly instead of keeping copies in sync.
- The repo is public, so anyone can read that the server stores only
  ciphertext; this backs the trust model in the README.

Move it to its own repo only if the server needs private code (abuse detection,
admin tools), different owners or access rights, or starts serving more than
this app.

Repo setup:

- `.github/workflows/share-worker.yml`: runs on changes to
  `server/share-worker/**` and `tests/fixtures/share-link/**`; runs the Worker
  tests, then `wrangler deploy`. The Cloudflare API token lives in GitHub
  Actions secrets only. (Built in PR 2 with the test job only; the deploy job
  waits for the Cloudflare account, bucket, and share domain.)
- Path filters on `swift-tests.yml` and `performance.yml` so Worker-only
  changes do not run them.
- Worker deploys are separate from app releases: no `release` label, no
  `Version.xcconfig` bump, no `scripts/release.sh`.
- Rate-limit thresholds: the Rate Limiting binding takes its limits from
  `wrangler.jsonc`, so they are public. Accepted: they are coarse per-IP
  limits, and Cloudflare WAF rules (configured in the dashboard, not the repo)
  can add private ones later.

The Cloudflare API token is only for `wrangler deploy`; it never goes into the
app or the Worker. The Worker reaches R2 through a binding.

| Method | Path | Auth | Body | Result |
| --- | --- | --- | --- | --- |
| `POST` | `/shares?ttl=7d` | — | envelope (`application/octet-stream`) | `201 {id, ownerToken, expiresAt}` |
| `GET` | `/shares/<id>` | `Accept: application/vnd.md-preview.envelope` | — | `200` envelope, or `404` (also without that `Accept`) |
| `PUT` | `/shares/<id>?ttl=7d` | `Authorization: Bearer <ownerToken>` | envelope | `200 {expiresAt}` |
| `DELETE` | `/shares/<id>` | `Authorization: Bearer <ownerToken>` | — | `204` |
| `GET` | `/.well-known/apple-app-site-association` | — | — | `200` JSON, `Content-Type: application/json`, no redirect |

Routes carry no `/api` prefix and no version number (decided 2026-10-23).
The format is versioned inside the data instead: the envelope's `MDP1` magic
and the payload's `"v"`. A breaking API change would add a new route name
rather than a `/v2` prefix.

The `apple-app-site-association` file claims `/s/*` for
`5P3TSMNV42.doc.md-preview` (Universal Links, §4.5). Apple's CDN fetches and
caches it, so a change can take hours to reach users.

**Storage: R2, not KV (decided 2026-10-23).** Main reason: storage must not
limit users. R2 has no practical cap on object count or total size, and a
single object can be far larger than our upload limit, so the 5 MB limit is a
product choice we can raise later (the Worker's request body limit, 100 MB on
the Free and Pro plans, is the next ceiling). KV would also fit (25 MiB values,
native `expirationTtl`, 1 KB metadata), but KV writes take up to ~60 s to reach
other locations: after "Stop Sharing" a link could still open elsewhere for a
minute, and a fresh link could `404` far away. R2 is strongly consistent, so
"Stop Sharing" and "Update Link Content" take effect at once, and its free tier
holds 10 GB against KV's 1 GB (≈200 shares near the 5 MB limit). The cost is
the cron and lifecycle rule below, which KV's TTL would have replaced.

- Real HTTP status codes; errors are `{ "error": "<code>" }`.
- R2 object key `shares/<id>`; `customMetadata`: `ownerHash`, `expiresAt`, `createdAt`.
- Owner token: 32 random bytes; compare hashes in constant time. A missing
  token answers `401`; a wrong token answers `404`, like a missing or expired
  share, so a request cannot tell whether an ID exists.
- Validation: body starts with `MDP1`, length ≥ 53, size ≤ **5 MB** (after
  compression), `ttl` in `{1h, 1d, 7d, 30d}`, default `7d`. No "never" in v1.
- Expiry: `GET` returns `404` once `expiresAt` has passed and deletes the
  object; a daily Cron Trigger deletes the rest; an R2 lifecycle rule (31 days)
  is the backstop. (PrivateBin's list+HEAD purge does not scale — avoid it.)
- Headers on every response: `Cache-Control: no-store`,
  `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`.
- Rate limits: Cloudflare Rate Limiting binding, keyed by IP. The binding only
  counts over 10 s or 60 s, so "per hour" limits are not possible: 10 writes
  (create, update, delete) and 300 reads per minute. Log nothing beyond what
  Cloudflare already logs; never log request bodies or the `Authorization`
  header.
- Daily upload quota: a Durable Object (`src/upload-quota.ts`) counts the
  bytes that all IPs together upload each UTC day, creates and updates
  alike. An update counts its full size, because it also renews the link's
  expiry: every object then lives on bytes counted in the last 30 days. Past
  `DAILY_UPLOAD_BYTES` (5 GB) uploads answer `503 {"error":"quota_exceeded"}`
  until the next day. A 30-day link spans at most 31 UTC days, so live links
  hold at most 31 × 5 GB (155 GB), plus expired ones until a read or the
  daily purge deletes them. The trade-off:
  an abuser who reaches the quota stops new links for everyone until
  midnight UTC.
- No CORS on write routes. `GET` needs CORS only if the viewer is on another
  origin (phase 2 decision).

## 4. App — phase 1

All new code in `md-preview/Features/ShareLink/` (the project uses
synchronized folders, so no `project.pbxproj` edits). The app already has
`com.apple.security.network.client`; **no entitlement changes in phase 1.**

### 4.1 Pure logic (testable, no AppKit)

- `ShareLinkCrypto.swift` — seal and open envelopes, HKDF/PBKDF2, compression.
- `ShareLink.swift` — parse and build `https://…/s/<id>#<key>` and
  `md-preview://share/<id>#<key>`; fragment `&` stripping; base64url.
- `SharePayload.swift` — the JSON model, size checks, asset path
  normalisation (reject `..`, absolute paths, and anything outside the
  document folder).

Symlink these into `tests/swift-tests/Sources/MarkdownHelpers/` and add
`ShareLinkCryptoTests`, `ShareLinkTests`, `SharePayloadTests` (XCTest, like
`ExternalOpenSchemeTests`). Run with `swift test --package-path tests/swift-tests`.

### 4.2 Network client

- `ShareLinkClient.swift` — `async` create / update / delete / fetch.
  Ephemeral `URLSession` like `UsageAnalyticsReporter.swift:21-28` (no cookies,
  no cache), 30 s timeout.
- Base URL from `Info.plist` key `ShareLinkBaseURL` so Debug can point at a
  local `wrangler dev`.
- Tests through a stub `URLProtocol`.

### 4.3 Storage of the user's shares

- Secrets (key, owner token) in the **Keychain**, one generic-password item per
  share, service `doc.md-preview.share-link`, account = share ID. This is the
  first Keychain use in the app.
- Metadata (ID, title, source file path, created, expires, has password) in a
  JSON file in Application Support. The Core Data model is empty and unused;
  do not start using it for this.
- Expired entries are removed from the list on launch.

### 4.4 UI (built, 2026-10-23)

The user asked for a minimal UI: one row in the existing Share popover, no
options sheet. Links always last 7 days, have no password, and carry the
document's local images when they fit (5 MB). Every surface below is a native
AppKit control; the custom options sheet, the "Shared Links" settings list,
and the File menu item from the first draft are dropped.

- **Share popover row** (last row of the app's section, right above the
  system's Copy; the popover gives app rows one section, and apps cannot add
  rows next to Copy — checked against Pages and ShareKit, see below):
  - **Publish to Web** while the file has no live link.
  - **Manage Shared Document…** while it has one.
- **Publish to Web** → `NSAlert` sheet "Publish to Web" (Publish / Keep Document Private).
  On macOS 26 a sheet alert hides the default app icon, matching ShareKit's
  own Copy Link alert, which is also a plain `NSAlert`.
- **Upload progress:** AppKit's private `NSProgressPanel` (from AppKit's
  `NSProgressPanel.nib`, the standard progress sheet) with a bold caption
  "Uploading Document…" and a round ✕ in place of its Cancel button, as in
  Pages' own progress panel. Shown only when the upload takes over 0.5 s;
  falls back to an `NSAlert` with a bar if the class or nib disappears.
  Once the link is copied, the Manage sheet opens, so the user sees the
  document is shared and where to stop sharing.
- **Manage sheet:** document icon, words · size, "Shared · Link expires …";
  Permissions pop-ups "Anyone with the link" / "can view only" with "People
  you choose" / "can edit" shown disabled; Stop Sharing (red), Copy Link
  (copies the link at once and briefly reads "Copied"; then uploads the
  current text under the same link only when it changed since the last
  upload, so an unchanged copy leaves the expiry as it was), Done.
- **Stop Sharing** → `NSAlert` "Stop sharing this document?" with the app icon
  set explicitly (sheet alerts hide it otherwise).
- **Window subtitle:** "Shared", or "Shared · Edited", while the file has a
  live link. The subtitle is not clickable. A Pages-style "Shared" toolbar
  button that opens the manage content as a popover was considered and
  declined (2026-10-23): Share → Manage Shared Document… is enough.
- **Share popover header:** the document's own Finder icon, drawn 1.3× so the
  page fills the system's white tile.
- Read the text from `DocumentWindowController.currentMarkdown` /
  `currentFileURL`, not `document.markdown` (the sidebar can switch files).
- Images: `ShareLinkAssets` collects the local images the rendered HTML
  references, confined to the document's folder, and downloads up to 50 web
  images (`http` ones over `https`; no cookies, six at a time, 20 s and 5 MB
  each, supported types only) as assets
  with a `source`. An image that cannot be downloaded stays a link. When the
  envelope is too large, the largest web images are left out first (each
  costs about its own size: DEFLATE takes back most of base64), then the local
  ones.

**Not possible without collaboration (investigated, rejected):** Pages' Copy
Link sits next to Copy because Pages adds its rows to an iCloud collaboration
item, and the popover then runs in a collaboration mode. For our own link the
only route is a Shared with You item (`SWCollaborationMetadata`), which needs
the restricted `com.apple.developer.shared-with-you[.collaboration]`
entitlements, a Developer ID profile in release signing, and crashes inside
ShareKit whenever the user has turned off the Messages share extension. The
test code is kept as a patch outside the repo.

### 4.5 Opening a share in the app

Built (2026-10-23), except Universal Links:

- `AppDelegate.application(_:open:)` sends `md-preview://share/…` and web
  links to `ShareLinkOpener` before `ExternalOpenScheme`; anything else keeps
  the malformed-link alert.
- There is no File menu item to paste a link; links open from a click.
  File › "Publish to Web…" (after Export as PDF…) runs the Share popover's
  row: it publishes, or shows Manage Shared Document… once the file has a link.
- Flow: fetch → ask for the password when the link or envelope has one →
  decrypt → write the Markdown and its assets into
  `Caches/SharedLinks/<id>/<title>/` (asset paths confined to that folder) →
  open it. Opening the same link again brings its window forward.
- The window is **read-only**: subtitle "Read only", Edit disabled, checkbox
  clicks do not save, no Copy Link. The sidebar starts on Table of Contents
  for that window only. Saving an editable copy is not built yet.
- Remote images, styles, fonts, and media do not load in that window (a
  WebKit content rule list), as in the web viewer: they would tell the
  sender's server who opened the link. Link clicks still work.
- Opening a share needs a new app version, shipped through Sparkle: the
  current app does not know the format. It needs no new sandbox capability for
  the download — `network.client` is already granted.

#### Universal Links (phase 1)

Goal: when the app is installed, `https://md-preview.app/s/<id>#<key>` opens in
the app, not the browser. The same link falls back to the web viewer when the
app is missing.

**Blocked, and removed from the app (2026-10-28).** Built in #573, then taken
out before 0.0.70 shipped: Apple refuses to register the `doc.md-preview` App
ID for team 5P3TSMNV42 ("not available" — another team holds it), and the
entitlement needs a Developer ID profile for that App ID. Apple Developer
Support may be able to move it; until then share links open through the viewer's button.
Restoring this means reverting the PR that removed it. The Worker still serves
`apple-app-site-association`; it is harmless without the entitlement.

As built:

- Entitlement `com.apple.developer.associated-domains` =
  `applinks:md-preview.app`, in **Release builds only**:
  `md-preview.release.entitlements` is `md-preview.entitlements` plus that key
  (`EntitlementsParityTests` keeps them otherwise equal). Debug builds cannot
  carry it: the restricted entitlement needs a profile, and
  `doc.md-preview.dev` belongs to another team, so no profile can be made.
- A Developer ID app with this entitlement must embed a Developer ID
  provisioning profile with Associated Domains, or it does not launch.
  `scripts/release.sh` stops in preflight unless it gets
  `--provisioning-profile <file>`, `AMORE_PROVISIONING_PROFILE`, or an App
  Store Connect API key (`ASC_API_KEY_ID`), which Amore uses to sign.
  Account setup: enable Associated Domains on the `doc.md-preview` App ID and
  create a Developer ID profile for it.
- The app receives the link through
  `application(_:continue:restorationHandler:)` with
  `NSUserActivityTypeBrowsingWeb` and routes it into the same open flow as
  `md-preview://share`. If share links are off in that build, it hands the
  link to the default browser (by app, so macOS does not send it back). Still
  to confirm on a real link: that `webpageURL` keeps the `#<key>` fragment.
- Works from Safari and from apps that open links through macOS (Messages,
  Mail, Notes). **Chrome and Firefox on macOS open the page themselves** — the
  viewer's "Open in Markdown Preview" button covers them (§5). A link typed or
  pasted into the address bar, or one the user chose to "Open in Safari", also
  stays in the browser.

#### Older app versions

- No Associated Domains entitlement → the link opens in the browser and the web
  viewer shows it. The viewer is the fallback for old versions.
- `md-preview://share/…` opens an old app, which shows its malformed-link
  alert. Acceptable; it is why the release order in §7 ships "open" first.

### 4.6 Strings, docs, analytics

- New strings in all five `Localizable.strings` (en, fa, ja, pl, zh-Hans).
- README section and a CHANGELOG entry in the same PR that makes the feature
  visible (AGENTS.md rule). The README must state the trust model.
- Analytics: at most a `"share link created"` count with no content, title,
  size, or ID — or none at all (open question).
- Ship behind a hidden default (`MarkdownPreview.shareLinksEnabled`) until the
  Worker runs in production. Done: 0.0.70 removed the default and turned
  sharing on for everyone.

## 5. Web — phase 2

**Status (2026-10-23):** the viewer is built in `server/share-worker/viewer/`
(see its README). Done: decrypt, sanitize with an allowlist, the app's
stylesheet and code/math renderers (exported and checked by
`ShareViewerKitTests`), the app's code block header (language, Wrap, Copy)
with code on its own surface (white with a hairline edge in light, a step
above the sheet in dark), local and downloaded web images as `blob:` URLs,
web images the app could not download blocked with a note, Open in Markdown Preview, Download .md, Copy link (with a
"Link copied" toast), an Aa panel in a popover with the app's
controls and words (text size, Appearance Automatic/Light/Dark, width; remembered per
browser), a Contents rail (always in place, "No headings" when empty, its
shown or hidden state and its width remembered; drag its edge, or focus it
and use the arrow keys, to resize it; double-click or Enter for the default
width), error states (the open
button stays), and the app icon as the tab and home-screen icon. In a narrow window the Contents open as a drawer
over the dimmed page. On phones and
tablets, which have no app, the open button reads "Get Mac App" and copies
the link to markdownpreview.app. Select All selects only the document (the page's
controls are not selectable), and copying whole blocks puts their Markdown
source on the clipboard with the app's own code (`markdownSelectionScript`,
exported in `renderers.js`). No layout shift while loading (CLS 0 in Chrome):
`boot.js`, a blocking script in the head, applies the saved layout before
the first paint; highlight.js and KaTeX load only for documents with code
or math. One request carries the document: the Worker sends the page's
head at once and streams the encrypted envelope into the end of the body
(a `<script type="application/octet-stream">` data block, which runs
nothing), so the scripts download while R2 is read. The page loads three
files (`boot.js`, one stylesheet, one script) whose names carry a hash of
their content, cached for a year as immutable. A slow load shows only
the text "Loading…", faded in after 1 s. Not
yet: password links, Report, burn after reading. Diagrams draw with the app's wiring
(`mermaidWiringFunction`, in the kit's `diagrams.js` with the app's words in each of its
languages) on Pele, loaded together only for documents with diagrams and after the text,
with the app's HUD less its window button. A link to another of the author's files (a
relative or root path), in the text or in a diagram, stays as text with a note, since the
share does not carry it. Table columns resize with the app's own code
(`tableColumnResizeScript`, exported as `enableTableColumnResize`): drag a header edge,
double-click it to fit the header. Deviation
from the text below: `style-src-attr 'unsafe-inline'` is allowed because KaTeX sets
inline styles; scripts stay `'self'` only.

- Viewer at `GET /s/<id>`: static HTML + one JS bundle from the same origin.
  It reads the fragment, takes the envelope from the page, decrypts with
  WebCrypto, inflates with `DecompressionStream`, and renders.
- Rendering: **the same output as the app, without a second parser.** The
  viewer takes `html` from the payload (rendered by `MarkdownHTML` at upload)
  and runs the app's own page pipeline on it: DOMPurify with the app's config
  (`MarkdownHTML+HostBridge.swift:713`), then Highlight, KaTeX, and Pele from
  `md-preview/Vendor/`, with the app's stylesheet. Rejected: markdown-it
  (output differs on footnotes, math, line breaks, heading IDs) and
  swift-markdown compiled to WebAssembly (large bundle, new toolchain).
- `html` is attacker-controlled: **always** sanitize it. DOMPurify with an
  **explicit** `ALLOWED_TAGS`/`ALLOWED_ATTR` list and **without**
  `USE_PROFILES` (PrivateBin's config is affected by the DOMPurify behaviour
  where `USE_PROFILES` resets `ALLOWED_ATTR`); check that the app's config
  meets this before reusing it. Links get `rel="noopener noreferrer nofollow"`.
  Assets become `blob:` URLs. Diagrams render in strict mode.
- Headers (from PrivateBin, tightened):
  `Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' blob: data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`,
  plus `Referrer-Policy: no-referrer`, `X-Frame-Options: DENY`,
  `X-Content-Type-Options: nosniff`, `Cross-Origin-Opener-Policy: same-origin`,
  `Cache-Control: no-store`. Remote images are blocked by `img-src` (stops
  tracking pixels); the app downloads them into the share instead, and the
  page shows a note for any it could not.
- **No analytics or third-party scripts on the viewer.** Any script on the page
  can read the key from `location.hash`.
- Buttons: "Open in Markdown Preview" (`md-preview://share/…`), "Download .md",
  "Report". The open button is always visible at the top: it is the only path
  into the app from Chrome and Firefox. The page never opens the app by
  itself: an automatic open after the button had worked once (2026-10-25)
  was removed on 2026-10-26, because readers found the browser's prompt on
  every link annoying.
- Burn after reading: a Durable Object per share makes "read once" atomic;
  confirm step before fetch. Not in phase 1.
- Report: form posts the ID (and optionally the full link, which lets us read
  it) to an abuse queue; admin delete by ID.

## 6. Abuse

Firefox Send closed because of malware abuse. Our defences:

- Short expiry (max 30 days), 5 MB limit, IP rate limits.
- The viewer renders sanitised Markdown only; it never serves raw HTML or
  arbitrary files, so it is a poor phishing or malware host.
- Uploads need the `MDP1` envelope — trivial to fake, so it does not stop
  the bucket being used as a file host by itself. `/shares/<id>` answers only
  a request with the app's `Accept` header, so its URL opened in a browser
  downloads nothing, and `/s/<id>` shows the envelope only as base64 inside
  the page. A client that sends the header still gets the bytes: this removes
  the one-click download a file host needs, not every way to fetch a file.
- A daily upload quota across all IPs (§3) caps the bucket's size and so its
  storage cost. It does not limit reads: those are R2 operations, limited
  only per IP.
- Report button, abuse e-mail, terms of use, privacy-policy update.
- Option: limit link sharing to licensed users through Amore licensing. Strongest
  control; product decision.

## 7. Delivery

| PR | Content | Verify |
| --- | --- | --- |
| 1 | This plan → format spec in `docs/`, `ShareLinkCrypto`, `ShareLink`, `SharePayload`, test vectors | `swift test` |
| 2 | Worker API + R2 + cron + rate limits, `share-worker.yml` deploy workflow, CI path filters, staging deploy | Worker unit tests, `curl` round trip with the app's test vectors |
| 3 | App: client, Keychain store, share sheet, Shared Links list (hidden default) | `swift test`, app build, runtime check against staging |
| 4 | App: open shares (`md-preview://share`, Universal Links + `apple-app-site-association`) | runtime check: create → open → images show; a Safari click on the `https://` link opens the app |
| 5 | Enable by default, README, CHANGELOG, privacy policy | release PR |
| 6+ | Phase 2: viewer, report flow, burn after reading | browser tests, XSS corpus against the sanitiser |

### Release order

People who receive a link should already have an app that can open it:

1. Release the version that can **open** shares (PRs 1–4), with "create" behind
   the hidden default.
2. Wait until most users have updated through Sparkle.
3. Turn "create" on for everyone (PR 5).

Until phase 2 ships, a recipient with an old version has no way to read a
share, so either ship the viewer before step 3 or accept that gap.

## 8. Open questions

1. ~~**Share domain.**~~ Decided 2026-10-23: paths on **`md-preview.app`**
   (`/s/<id>` links, `/shares` API, the Universal Links file), served by the
   Worker through Workers Routes. That domain only redirects to the website at
   `markdownpreview.app`, so it carries no website cookies or scripts, it is
   free, and every link shows the app's name. Accepted risk: shared content
   that gets the domain flagged (e.g. by Safe Browsing) could put browser
   warnings on `release.md-preview.app`; Sparkle fetches the feed in the app,
   so updates themselves are not blocked. The Universal Links entitlement is
   `applinks:md-preview.app`. Setup: `server/share-worker/README.md`, "Deploy".
2. **Who can share:** everyone, or licensed users only?
3. **Images in v1:** bundle them (plan default) or text only?
4. ~~**Worker location:** `server/` in this repo, or a separate repo?~~
   Decided 2026-10-23: `server/share-worker/` in this repo (§3).
5. **Analytics:** a content-free "share link created" count, or nothing?
