# Share Worker

The share-link API for Markdown Preview: a Cloudflare Worker that stores
encrypted `MDP1` envelopes in R2. The app encrypts every document before upload
and keeps the key in the link's URL fragment, so this server never sees a key
or a readable document. Design and API: [`docs/share-link-plan.md`](../../docs/share-link-plan.md) §2–3.

## Web viewer

`viewer/` is the page at `/s/<id>`. It reads the envelope the Worker puts in
the page, decrypts it in the browser with the key from the URL fragment (WebCrypto and
`DecompressionStream`, matching the app's `ShareLinkCrypto`), and shows the
document with the app's own stylesheet and renderers:

- `viewer/generated/` holds the app's `MarkdownHTML` stylesheet and its code
  and math renderers, exported by the Swift test `ShareViewerKitTests`, which
  fails when they drift. Regenerate with
  `MDP_WRITE_VIEWER_KIT=1 swift test --package-path tests/swift-tests --filter ShareViewerKitTests`.
- `npm run build:viewer` (it runs before `dev`, `test`, and `deploy`)
  bundles the viewer into `public/`, which is not committed: `boot.js`, one
  stylesheet, and one script (DOMPurify, the renderers, and `main.js`), with
  highlight.js and KaTeX from `md-preview/Vendor` next to them. They go in
  `public/s/_viewer/assets/` as `name.<content hash>.ext`, served with a
  one-year immutable `Cache-Control`, so a file keeps its name (and stays
  cached) until its content changes.
- `/s/<id>` carries the encrypted envelope at the end of the page, so a
  reader needs no second request. `/shares/<id>` still serves it to the app,
  and only to a request with `Accept: application/vnd.md-preview.envelope`:
  opened as a link in a browser, it answers `404`, so it cannot pass files on.
- The rendered HTML comes from whoever made the envelope, so the page
  sanitizes it with an explicit allowlist, allows only same-origin scripts
  (CSP in `src/viewer-csp.ts`), and blocks remote images. Images from the
  web come inside the share instead: the app downloads them when it makes
  the link, and the page shows them by their address (an asset's `source`).

Diagrams (Mermaid through Pele) draw with the app's own wiring and words from
`generated/diagrams.js`; the build joins it to `pele.global.js` as one file that loads
only for documents that have diagrams.

## Run locally

```sh
npm install
npm run dev        # http://localhost:8787, with a local R2 copy in .wrangler/
```

No Cloudflare account is needed. Round trip with a test vector:

```sh
python3 -c "import json; v = json.load(open('../../tests/fixtures/share-link/vectors.json'))['vectors'][0]; open('/tmp/envelope.bin', 'wb').write(bytes.fromhex(v['envelope']))"
curl -s -X POST --data-binary @/tmp/envelope.bin 'http://localhost:8787/shares?ttl=1d'
# → {"id":"…","ownerToken":"…","expiresAt":"…"}
curl -s -H 'Accept: application/vnd.md-preview.envelope' http://localhost:8787/shares/<id> -o /tmp/back.bin && cmp /tmp/envelope.bin /tmp/back.bin
curl -s -X DELETE -H 'Authorization: Bearer <ownerToken>' http://localhost:8787/shares/<id>
```

Cron triggers do not run locally. Trigger the expiry purge by hand with
`curl 'http://localhost:8787/cdn-cgi/local/scheduled'`.

## Test

```sh
npm test           # vitest inside the Workers runtime (local R2, rate limits, upload quota)
npm run typecheck
```

The tests upload every envelope in `tests/fixtures/share-link/vectors.json`,
the same vectors the app's Swift tests seal and open.

## Deploy

Production runs on three paths of `md-preview.app`, a domain whose other paths
redirect to the website at `markdownpreview.app`:

| Path | Purpose |
| --- | --- |
| `/s/<id>#<key>` | the link people share; a script-free page until the web viewer exists |
| `/shares`, `/shares/<id>` | the API the app calls |
| `/.well-known/apple-app-site-association` | Universal Links |

`wrangler.jsonc` declares these as Workers Routes. The `share-worker.yml`
workflow deploys `main` after the tests pass, once the secrets below exist;
without them it skips with a notice. The deploy job runs in the
`share-worker` environment, which requires a reviewer: each push to `main`
that changes the Worker waits until someone approves it in the workflow run
(Review deployments).

One-time setup in Cloudflare (the account that owns `md-preview.app`):

1. **R2 bucket:** create `md-preview-shares` (R2 › Create bucket, or
   `npx wrangler r2 bucket create md-preview-shares`).
2. **Lifecycle rule:** in the bucket's settings, add an object lifecycle rule
   that deletes objects 31 days after upload. It backs up the daily purge.
3. **Redirect rule:** Cloudflare runs Redirect Rules before Workers. Edit the
   rule that sends `md-preview.app` to `markdownpreview.app` so it skips the
   Worker's paths, for example by adding to its expression:

   ```
   and not starts_with(http.request.uri.path, "/s/")
   and not starts_with(http.request.uri.path, "/shares")
   and http.request.uri.path ne "/.well-known/apple-app-site-association"
   ```

4. **API token:** My Profile › API Tokens › Create Token › "Edit Cloudflare
   Workers", limited to this account and the `md-preview.app` zone.
5. **GitHub secrets** (repository › Settings › Secrets and variables ›
   Actions): `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`.
6. **Approval:** repository › Settings › Environments › `share-worker`, with
   required reviewers and `main` as the only deployment branch.

To deploy by hand instead: `npx wrangler login`, then `npm run deploy`.

Check after a deploy:

```sh
curl -s https://md-preview.app/.well-known/apple-app-site-association   # JSON with the app ID
curl -sI https://md-preview.app/s/AAAAAAAAAAAAAAAAAAAAAA | head -1         # 200, the link page
curl -sI https://md-preview.app/ | grep -i location                        # still the website redirect
```

Release builds of the app use `https://md-preview.app`; Debug builds use
`http://localhost:8787`. The `MarkdownPreview.shareLinkBaseURL` default
overrides both, for example to test a staging Worker.
