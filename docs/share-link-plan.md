# Share via link — plan

Status: draft, 2026-10-16; revised 2026-10-23. Built behind the hidden
`MarkdownPreview.shareLinksEnabled` default: the format and crypto (§2), the
Worker API and its deploy setup on `md-preview.app` (§3), and sharing from the
app (§4.1–4.4). Still planned: opening links in the app and Universal Links
(§4.5) and the web viewer (§5).

Goal: from an open Markdown document, the user creates a random link. Anyone
with the link can read the document in a browser, or open it in Markdown
Preview. The server stores only ciphertext and can never read a document.
**When the app is installed, the link opens in the app, not the browser**
(Universal Links, §4.5).

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
    { "path": "img/diagram.png", "type": "image/png", "data": "<base64>" }
  ]
}
```

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
| `GET` | `/shares/<id>` | — | — | `200` envelope, or `404` |
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
  (create, update, delete) and 300 reads per minute. Log nothing beyond what Cloudflare already
  logs; never log request bodies or the `Authorization` header.
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
  - **Copy Link** while the file has no live link.
  - **Manage Shared Document…** while it has one.
- **Copy Link** → `NSAlert` sheet "Copy Link to Share" (Continue / Cancel).
  On macOS 26 a sheet alert hides the default app icon, matching ShareKit's
  own Copy Link alert, which is also a plain `NSAlert`.
- **Upload progress:** AppKit's private `NSProgressPanel` (from AppKit's
  `NSProgressPanel.nib`, the standard progress sheet) with a bold caption
  "Uploading Document…" and a round ✕ in place of its Cancel button, as in
  Pages' own progress panel. Shown only when the upload takes over 0.5 s;
  falls back to an `NSAlert` with a bar if the class or nib disappears. No
  "copied" message afterwards.
- **Manage sheet:** document icon, words · size, "Shared · Link expires …";
  Permissions pop-ups "Anyone with the link" / "can view only" with "People
  you choose" / "can edit" shown disabled; Stop Sharing (red), Copy Link
  (re-uploads the current text, briefly reads "Copied"), Done.
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
  references, confined to the document's folder. Remote image URLs stay links.

**Not possible without collaboration (investigated, rejected):** Pages' Copy
Link sits next to Copy because Pages adds its rows to an iCloud collaboration
item, and the popover then runs in a collaboration mode. For our own link the
only route is a Shared with You item (`SWCollaborationMetadata`), which needs
the restricted `com.apple.developer.shared-with-you[.collaboration]`
entitlements, a Developer ID profile in release signing, and crashes inside
ShareKit whenever the user has turned off the Messages share extension. The
test code is kept as a patch outside the repo.

### 4.5 Opening a share in the app

- `ExternalOpenScheme` gains a `share` host; `AppDelegate.application(_:open:)`
  (`AppDelegate.swift:255-291`) gets a branch for it. Keep the existing
  malformed-link alert for anything else.
- File › "Open Shared Link…" with a field that accepts the `https://` form.
- Flow: fetch → ask for password if `#p.` → decrypt → write markdown and
  assets into `Caches/SharedLinks/<id>/` (paths confined to that folder) →
  open as a **read-only** document with that folder as the asset base. The
  window title shows the share title and a "Shared" badge. "Save As…" copies it
  out.
- Opening a share needs a new app version, shipped through Sparkle: the
  current app does not know the format. It needs no new sandbox capability for
  the download — `network.client` is already granted.

#### Universal Links (phase 1)

Goal: when the app is installed, `https://md-preview.app/s/<id>#<key>` opens in
the app, not the browser. The same link falls back to the web viewer when the
app is missing.

- Entitlement `com.apple.developer.associated-domains` =
  `applinks:md-preview.app` in `md-preview.entitlements`. **Entitlement change —
  needs the maintainer's approval (AGENTS.md).** A Developer ID app needs a
  Developer ID provisioning profile with Associated Domains, and the Amore
  signing setup must embed it; read the `release-process` skill first.
- The share domain (open question 1) is baked into the entitlement, so it must
  be decided before this work starts.
- The app receives the link through
  `application(_:continue:restorationHandler:)` with
  `NSUserActivityTypeBrowsingWeb`; `webpageURL` includes the `#<key>` fragment.
  Route it into the same open flow as `md-preview://share`.
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
  Worker runs in production.

## 5. Web — phase 2

- Viewer at `GET /s/<id>`: static HTML + one JS bundle from the same origin.
  It reads the fragment, fetches `/shares/<id>`, decrypts with
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
  tracking pixels); show a note when the document has some.
- **No analytics or third-party scripts on the viewer.** Any script on the page
  can read the key from `location.hash`.
- Buttons: "Open in Markdown Preview" (`md-preview://share/…`), "Download .md",
  "Report". The open button is always visible at the top: it is the only path
  into the app from Chrome and Firefox. **Never redirect to `md-preview://`
  automatically** — a page cannot tell whether the app is installed, and Safari
  shows an error alert when it is not.
- Burn after reading: a Durable Object per share makes "read once" atomic;
  confirm step before fetch. Not in phase 1.
- Report: form posts the ID (and optionally the full link, which lets us read
  it) to an abuse queue; admin delete by ID.

## 6. Abuse

Firefox Send closed because of malware abuse. Our defences:

- Short expiry (max 30 days), 5 MB limit, IP rate limits.
- The viewer renders sanitised Markdown only; it never serves raw HTML or
  arbitrary files, so it is a poor phishing or malware host.
- Uploads need the `MDP1` envelope — trivial to fake, but it stops casual
  misuse of the bucket as a file host.
- Report button, abuse e-mail, terms of use, privacy-policy update.
- Option: limit link sharing to licensed users through Amore licensing. Strongest
  control; product decision.

## 7. Delivery

| PR | Content | Verify |
| --- | --- | --- |
| 1 | This plan → format spec in `docs/`, `ShareLinkCrypto`, `ShareLink`, `SharePayload`, test vectors | `swift test` |
| 2 | Worker API + R2 + cron + rate limits, `share-worker.yml` deploy workflow, CI path filters, staging deploy | Worker unit tests, `curl` round trip with the app's test vectors |
| 3 | App: client, Keychain store, share sheet, Shared Links list (hidden default) | `swift test`, app build, runtime check against staging |
| 4 | App: open shares (`md-preview://share`, Open Shared Link…, Universal Links + `apple-app-site-association`) | runtime check: create → open → images show; a Safari click on the `https://` link opens the app |
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
