# Share Worker

The share-link API for Markdown Preview: a Cloudflare Worker that stores
encrypted `MDP1` envelopes in R2. The app encrypts every document before upload
and keeps the key in the link's URL fragment, so this server never sees a key
or a readable document. Design and API: [`docs/share-link-plan.md`](../../docs/share-link-plan.md) §2–3.

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
curl -s http://localhost:8787/shares/<id> -o /tmp/back.bin && cmp /tmp/envelope.bin /tmp/back.bin
curl -s -X DELETE -H 'Authorization: Bearer <ownerToken>' http://localhost:8787/shares/<id>
```

Cron triggers do not run locally. Trigger the expiry purge by hand with
`curl 'http://localhost:8787/cdn-cgi/local/scheduled'`.

## Test

```sh
npm test           # vitest inside the Workers runtime (local R2, rate limits)
npm run typecheck
```

The tests upload every envelope in `tests/fixtures/share-link/vectors.json`,
the same vectors the app's Swift tests seal and open.

## Deploy

Not wired yet. It needs the Cloudflare account, the `md-preview-shares` R2
bucket, the share domain as a custom domain on the Worker, and an R2 lifecycle
rule that deletes objects after 31 days as a backstop for the daily purge.
