# Deploying our own badge host

Status at the time of writing: **built here, not deployed.** The apps still open
`https://badges.simplex.chat/#/tier?app=…`, which is operated by SimpleX Chat and which this fork
does not control. Renaming that host in the clients without putting bytes behind a host we own
would 404 the purchase flow, so the host is held until section (e) lands together with a live
server.

Everything below was measured on this checkout, not recalled:
`npm run build` → `build 28ba4afbe2af92b0: 29 files in dist/assets/28ba4afbe2af92b0/, with
index.html and sw.js`; `npm test` → **525 tests, 525 pass, 0 fail**; `du -sh dist` → **1.8M**,
31 files. Two builds in a row are byte-identical (`diff -r` clean), so the deploy tree is
reproducible from a clean checkout.

## (a) Prerequisites only the operator can do

1. **A DNS name.** Pick the origin, e.g. `badges.popopx.chat`, and point an A/AAAA record at the
   box. The page calls the API same-origin and relative (`/api/invoice`, `src/api.ts:158,187,191`),
   so one name serves the page and the RPC; there is no second API host to arrange.
2. **A TLS certificate.** The page hands over a badge code and mounts Stripe.js; HTTPS is not
   optional. `trustedHost` at `src/embed.ts:46` refuses any origin whose scheme is not `https:`
   (`:54`).
3. **Stripe, if cards are to be sold.** A restricted key (`rk_`, Payment Intents write + Charges
   read — never `sk_`), its publishable twin (`pk_`), and a Dashboard webhook aimed at
   `https://<host>/webhooks/stripe` whose signing secret (`whsec_`) goes in `[stripe]`. Plus the
   payout account, which nothing in this repo can see. Omit `[stripe]` and the page shows the
   provider-unavailable screen for Card — deliberately, not by accident.
4. **BTCPay + Monero, if BTC/XMR are to be sold.** A store: `host` (https), `api_key`, `store_id`,
   `webhook_secret` for `https://<host>/webhooks/btcpay`, and the Monero payment method enabled on
   that store. Omit `[btcpay]` and both crypto methods fall to the same screen.
5. **Whether to deploy the Haskell service at all.** Without it the page is a shell: the tiers
   render, `POST /api/invoice` has nothing to answer, and nothing can be bought. With it, note the
   blocker on issuing: `[issuer] private_key` is checked at startup against the public key already
   compiled into the apps — `checkIssuerKey` at `apps/popopx-badge-service/src/BadgeService/Service.hs:126-139`
   refuses to start on a fresh `badge keygen` pair, and the app only accepts a credential whose key
   index is in `badgePublicKeys` (`src/Popopx/Chat.hs:73`, verified at
   `src/Popopx/Chat/Library/Commands.hs:5322-5325`). **A brand-new issuer key means an app release
   carrying its public half**; until then codes bought from a key the apps do not know cannot be
   redeemed.
6. **The service's own footprint.** `badgeService` starts `popopxChatCore` unconditionally, so a run
   opens or creates a chat database and does agent network work (`web/README.md:109-114`). Plan the
   data directory, the user it runs as, and `--no-address`.

## (b) Building `dist/` reproducibly

```bash
git clone <this repo> && cd popopx-chat/apps/popopx-badge-service/web
npm ci            # or npm install; dev deps are typescript + @types/node only
npm run build     # prints: build <hash>: 29 files in dist/assets/<hash>/, with index.html and sw.js
npm test          # 525 pass, 0 fail
```

Toolchain this was verified with: node v26.13.0, npm 11.20.0, `tsc` 6.0.3.

The deploy tree is `dist/` and nothing else: `index.html`, `sw.js`, `assets/<hash>/` (29 files: the
compiled modules, `styles.css`, the four brand SVGs, the two hero PNGs, five woff2 faces). 1.8M on
disk, unminified, no runtime dependencies.

Two rules, both from `web/README.md:33-36`:

- **Anything edited under `src/` requires `npm run build`**, which rewrites the content hash inside
  the tracked `public/index.html` and `public/sw.js`. Commit those two files with the source change.
  `npm test` recomputes the hash and fails when they do not name the build — that tripwire is the
  cheapest signal here, so never "fix" the test instead of rebuilding.
- Do not hand-edit the hash. Read it from the build output, or from the page itself:
  `grep -o 'assets/[0-9a-f]*/main\.js' dist/index.html`.

Ship it:

Ship it. In shape A this directory is what nginx never touches and the service serves; in shape B it
is `static_dir`, the copy source, and nginx serves the export instead:

```bash
rsync -a --delete dist/ <operator>@<host>:/srv/badges.dist/
ssh <operator>@<host> 'sudo restorecon -Rv /srv/badges.dist; \
  sudo systemctl restart popopx-badge-service; \
  sudo restorecon -Rv /srv/badges.popopx.chat'
```

`--delete` matters: an old `assets/<old-hash>/` left in the tree is merely dead weight, but an old
`sw.js` would keep serving a stale precache list. A buyer who loads mid-rsync gets either the old
shell with the old assets or the new with the new, because the shell and the hash land in the same
tree and the shell is `no-cache`; if that window matters, rsync to `/srv/badges.dist.new` and `mv`
it into place. In shape B the restart is what rewrites the nginx root (`exportWebapp` runs at boot),
and the `restorecon` after it is what makes those freshly written files readable by nginx — files an
unconfined service creates do not reliably arrive labelled `httpd_sys_content_t`.

## (c) nginx on CentOS

Two shapes, and the choice is load-bearing because of the Stripe key. The service injects
`publishable_key` into the `<meta id="stripe-publishable-key">` slot **as it serves the shell**
(`prepareShell`/`injectPublishableKey`, `src/BadgeService/Web/Server.hs:309-331`); the committed
`public/index.html` keeps that attribute empty on purpose and always will.

- **Shape A, simplest: nginx terminates TLS and proxies everything**, `serve_webapp = on`. The
  service already sets exactly the right headers — `no-cache` on the shell and `sw.js`,
  `public, max-age=31536000, immutable` under `/assets/` (`staticHeaders`,
  `src/BadgeService/Web/Server.hs:376-383`) — and the card key arrives. Use this unless there is a
  reason not to.
- **Shape B, below in full: nginx serves the static tree**, `serve_webapp = off`, and the service
  writes the key-injected copy for it: `webapp_export_dir = /srv/badges.popopx.chat`. That
  directory is **emptied at every service boot** (`exportWebapp`, `Server.hs:333-340`), so it must
  be a dedicated export path, never a git checkout and never `web/dist` itself. Omitting
  `webapp_export_dir` while serving `dist/` from nginx leaves the meta empty, `cardPlan` answers
  `unconfigured`, and Card silently fails with "The card form did not load" — with no error
  anywhere. That is the trap in this deployment.

`badge_service.ini` `[listener]` for shape B:

```ini
[listener]
host = 127.0.0.1            ; bind locally; the proxy terminates TLS
port = 8080
static_dir = /srv/badges.dist            ; the rsynced dist/, read as the copy source
serve_webapp = off
webapp_export_dir = /srv/badges.popopx.chat   ; the nginx root; REWRITTEN at every boot, with the key injected
trust_forwarded_for = on    ; without it every buyer shares one rate-limit bucket on the proxy's address
```

**These two paths must differ.** `exportWebapp` runs `emptyDir out` and then `copyTree static_dir out`
(`Server.hs:333-340`); give it the same directory twice and the boot empties the source before
copying it, so the webapp is destroyed on startup and nothing warns you first.

SELinux and firewalld, the two things that make an otherwise-correct nginx block fail on CentOS:

```bash
sudo setsebool -P httpd_can_network_connect 1          # nginx -> 127.0.0.1:8080; without it, 502 and an AVC
sudo semanage fcontext -a -t httpd_sys_content_t '/srv/badges\.popopx\.chat(/.*)?'
sudo semanage fcontext -a -t httpd_sys_content_t '/srv/badges\.dist(/.*)?'      # shape B's copy source too, so both restorecons below have a rule to match
sudo restorecon -Rv /srv/badges.popopx.chat
sudo firewall-cmd --permanent --add-service=https && sudo firewall-cmd --reload
```

Header partial — written once because nginx `add_header` does **not** inherit into any block that
declares its own `add_header`, which is exactly what each caching location does. Repeat the include
in every one of them:

```bash
sudo tee /etc/nginx/badges-headers.conf >/dev/null <<'EOF'
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "no-referrer" always;
# README's CSP, with our own origin in frame-ancestors. Without script-src on js.stripe.com the card
# path breaks silently and nothing in the Node suite would catch it (web/README.md:274-292).
add_header Content-Security-Policy "default-src 'self'; script-src 'self' https://js.stripe.com https://*.js.stripe.com; frame-src https://js.stripe.com https://*.js.stripe.com https://hooks.stripe.com; connect-src 'self' https://api.stripe.com; img-src 'self' https://*.stripe.com; frame-ancestors 'self' https://popopx.chat" always;
EOF
```

Verbatim from `web/README.md:282-289` except `frame-ancestors`, which drops the two `simplex.chat`
entries the README says to drop when upstream must not embed us, and adds nothing. The page needs no
`data:` in `img-src`: the QR, the badge art and the payment marks are all inline SVG built with
`createElementNS` (`src/qr.ts`, `src/icons.ts`), and nothing in `src/` or `styles.css` writes a
`data:` URI — so if a future change adds one, this header is the thing that breaks it, silently.

`/etc/nginx/conf.d/badges.popopx.chat.conf` — complete, and self-verifiable with section (d):

```nginx
upstream badge_service { server 127.0.0.1:8080; keepalive 8; }

server {
    listen 80; listen [::]:80;
    server_name badges.popopx.chat;
    location ^~ /.well-known/acme-challenge/ { root /var/lib/letsencrypt; }   # do not shadow certbot
    location / { return 301 https://$host$request_uri; }
}

server {
    listen 443 ssl; listen [::]:443 ssl;
    http2 on;                    # nginx >= 1.25.1; on an older EPEL build write `listen 443 ssl http2;` and drop this line. `nginx -v` decides; `nginx -t` catches it either way.
    server_name badges.popopx.chat;

    ssl_certificate     /etc/letsencrypt/live/badges.popopx.chat/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/badges.popopx.chat/privkey.pem;

    root /srv/badges.popopx.chat;   # shape B: the exported tree. Shape A: no root at all, everything proxies.
    autoindex off;                  # the default, stated so a later include cannot quietly flip it

    # The shell. The app routes on the FRAGMENT (/#/tier?app=true), which the browser never sends,
    # so $uri is "/" and nothing else in normal use; the fallback still matters, because a reload of
    # any path must return the page rather than a 404 the service worker cannot answer for.
    # No $uri/ term anywhere: a directory would fall to autoindex or a 403, which is the thing this
    # block must never serve.
    location = /       { include /etc/nginx/badges-headers.conf; add_header Cache-Control "no-cache" always; }
    location = /index.html { include /etc/nginx/badges-headers.conf; add_header Cache-Control "no-cache" always; try_files /index.html =404; }
    location /         { include /etc/nginx/badges-headers.conf; add_header Cache-Control "no-cache" always; try_files $uri /index.html; }

    # The worker: no cache, so a redeploy is picked up on the next load, and the right type, because
    # a non-JavaScript content type is refused at registration and offline silently never happens.
    # `types {}` replaces the mime map for this location; `default_type` would not, because mime.types
    # already answers `.js`. The service itself sends `text/javascript; charset=utf-8` (Server.hs:385-391).
    location = /sw.js  { include /etc/nginx/badges-headers.conf; types { text/javascript js; } add_header Cache-Control "no-cache" always; try_files /sw.js =404; }

    # Content-hashed modules, CSS and images: name changes with the bytes, so a year is honest.
    location ^~ /assets/ {
        include /etc/nginx/badges-headers.conf;
        add_header Cache-Control "public, max-age=31536000, immutable" always;
        try_files $uri =404;             # never the fallback: a missing hashed file is a bad deploy
    }

    # The badge RPC. proxy_pass carries NO URI part, which is what preserves the query string —
    # the long poll's `wait`, `seenPaid` and `seenFull` all travel in it (badge_service.ini.example:2-3).
    # Adding a trailing slash to the target would rewrite the path instead; do not.
    location ^~ /api/ {
        include /etc/nginx/badges-headers.conf;
        proxy_pass http://badge_service;
        proxy_http_version 1.1;
        proxy_set_header Connection "";   # required for the upstream keepalive above to be used at all
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 5s;
        proxy_read_timeout 75s;          # the service holds a long poll 30s on purpose (Server.hs:92-93)
        proxy_buffering off;
    }

    # Provider callbacks. Stripe and BTCPay retry on anything but 2xx, so this must not be filtered,
    # redirected to HTTPS with a 301 the caller will not follow, or size-capped below the service's
    # own 64 KiB ceiling (maxWebhookBytes, Server.hs:105).
    location ^~ /webhooks/ {
        include /etc/nginx/badges-headers.conf;
        client_max_body_size 128k;
        proxy_pass http://badge_service;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    gzip on;
    gzip_types text/css text/javascript image/svg+xml application/json;
    gzip_min_length 1024;                # woff2, png and svg are already compact
}
```

Shape A differs in exactly two places: `serve_webapp = on` with `static_dir` at the real `dist/` and
no `webapp_export_dir`, and the four static `location` blocks collapse into
`location / { include /etc/nginx/badges-headers.conf; proxy_pass http://badge_service; … }` with the
same proxy headers and `proxy_read_timeout 75s` as `/api/`.

`nginx -t && sudo systemctl reload nginx`. Insert whole blocks or whole files here — never a
line-inverting `sed` against `location` patterns, which is how a `try_files` ends up in the wrong
block and passes `nginx -t` while serving the shell for every asset.

## (d) Verifying it against the live host

Run these from anywhere; each states what a pass proves. `HASH` is read from the build, never typed.

```bash
H=https://badges.popopx.chat
HASH=$(grep -o 'assets/[0-9a-f]\{8,\}/main\.js' dist/index.html | head -1 | cut -d/ -f2)
echo "built hash: $HASH"

# 1. the shell is served, is HTML, and is the build in the tree
curl -s -o /dev/null -w 'shell: %{http_code} %{content_type}\n' "$H/"
LIVE=$(curl -s "$H/" | grep -o 'assets/[0-9a-f]\{8,\}/main\.js' | head -1 | cut -d/ -f2)
[ "$LIVE" = "$HASH" ] && echo "OK  live shell names $LIVE" || echo "FAIL live names '$LIVE', tree names '$HASH'"
curl -s "$H/" | grep -o '<title>[^<]*</title>'          # want: <title>Support POPOPX</title>

# 2. a hashed asset: 200, immutable, and a JavaScript type (nginx's own mime map answers
#    `application/javascript` and the newer one `text/javascript`; both register, octet-stream does not)
curl -sI "$H/assets/$HASH/main.js" | tr -d '\r' | grep -iE '^HTTP/|content-type|cache-control'
# want: 200, a */javascript type, public, max-age=31536000, immutable

# 3. the service worker: no cache, correct type. Both are registration preconditions.
curl -sI "$H/sw.js" | tr -d '\r' | grep -iE '^HTTP/|content-type|cache-control'
# want: 200, text/javascript, no-cache

# 4. no directory listing, and no fallback swallowing a missing asset
curl -s -o /dev/null -w 'assets/: %{http_code}\n' "$H/assets/"            # want 403 or 404, never an index
curl -s -o /dev/null -w 'bogus asset: %{http_code}\n' "$H/assets/deadbeef/nope.js"   # want 404 (not the shell)
curl -s "$H/some/stray/path" | grep -c 'id="app"'                          # want 1: the SPA fallback works

# 5. the RPC is the SERVICE answering, not nginx shrugging
curl -s -w '\nPOST /api/invoice: %{http_code}\n' -X POST "$H/api/invoice" \
  -H 'content-type: application/json' -d '{}'
# want 400 {"error":"bad_request"} — the service's own JSON (Server.hs:237-244; the "malformed body"
# reason is logged service-side, never returned)
curl -s -w '\nread: %{http_code} in %{time_total}s\n' "$H/api/invoice/none?wait=open"
# want 404 {"error":"not_found"} at once. The body decides: JSON means the proxy is wired, an nginx
# HTML 404 means it is not. And an unknown id must NOT be held 30s by the long poll — it answers from
# the store read (Server.hs:399-402), so a delay here means something in front is buffering wrongly.

# 6. the callback routes the providers will hit
curl -s -o /dev/null -w 'stripe webhook route: %{http_code}\n' -X POST "$H/webhooks/stripe" -d ''   # 400 refused, NOT 404
curl -s -o /dev/null -w 'btcpay webhook route: %{http_code}\n' -X POST "$H/webhooks/btcpay" -d ''    # 400 refused, NOT 404

# 7. the deep-link return path is reachable. The page hands the code to the app by the CUSTOM scheme
# popopxchat: (src/routing.ts:26 -> location.href / a hidden iframe, main.ts:707-709), so there is
# no assetlinks.json or apple-app-site-association to install for this host: nothing https-side has
# to resolve. Prove the bytes carry it, then prove the app takes it.
curl -s "$H/assets/$HASH/routing.js" | grep -o 'popopxchat:/badge/code/' | head -1
# and on a machine with the app installed: open $H/#/tier?app=true in the system browser, buy with
# BTC or XMR, settle it, and confirm the ending says "Return to POPOPX" and the app comes forward on
# the Redeem-code sheet. `?app=desktop` must instead show the code to paste, with the app already
# open beside the browser. Both flags are read once at load: use a fresh private window per flag
# (web/README.md:196-207). The code is a bearer token, so a phone camera scan of the QR is the last
# thing to sign off (web/README.md:239-249 — the Node suite cannot see any of this).

# 8. the failure that leaves no log line: an empty Stripe key on a proxying nginx
curl -s "$H/" | grep -o 'id="stripe-publishable-key" content="[^"]*"'      # content="" means no card path

# 9. SELinux, which presents as 502
sudo ausearch -m avc -ts recent | tail
```

## (e) The client-side change that must land as ONE commit with the deployment

A host change with no bytes behind it silently breaks the purchase flow, and bytes behind a host
nobody points at does nothing. Both ends move together. Measured set for `badges.simplex.chat` in
this repo: **8 occurrences over 8 matching lines in 6 files** (`rg -n "badges\.simplex\.chat"
--glob '!.git' .`: `FORK.md` 1, `web/README.md` 2, `web/test/sw.test.ts` 1, `web/test/embed.test.ts`
1, `BadgeStore.swift` 1, `BadgeStore.kt` 2), plus **3 occurrences over 3 lines in 1 file** in the
site repo (`website/src/badges.html`, which is also the only file there naming the host).

The live ends (must change):

1. `apps/multiplatform/common/src/commonMain/kotlin/chat/popopx/common/views/badges/BadgeStore.kt:53`
   and `:54` — `badgePageUrl()`, the `app=true` and `app=desktop` pair. `:56-57` is the commented dev
   slot; move it or leave it, but say which.
2. `apps/ios/Shared/Views/Badges/BadgeStore.swift:34` — iOS has its **own** copy of the constant,
   and `:36` its dev slot. Nothing in the Kotlin build notices #1 and nothing in the Swift build
   notices #2; they are separate ends of one fact and both must move in the same commit.

Read-only call sites, listed so nobody edits them separately:
`BadgesSupportPopopxView.kt:146,159`, `BadgesSupportPopopxView.swift:156,165`.

Docs and fixtures naming the old origin (same commit, no behaviour attached):

3. `apps/popopx-badge-service/web/README.md:309` and `:313` — the iframe embed snippet and its
   `APP` origin constant.
4. `apps/popopx-badge-service/web/test/sw.test.ts:10` — `const ORIGIN`.
5. `apps/popopx-badge-service/web/test/embed.test.ts:6` — the trusted-origin list the embed test
   drives; add our host, and note `src/embed.ts:56` also accepts `simplex.chat`, which is held.
6. `FORK.md:806` — the residue-table row (owned by the agent driving the two docs).
7. `popopx.chat-site/website/src/badges.html:4-6` — the site page that today **redirects** to
   `badges.simplex.chat` and states that badges are "operated by SimpleX Chat, not by POPOPX". Until
   it moves, our own host is invisible to anyone arriving from popopx.chat. Different repo,
   different commit, same release window.

Known gap to close by hand, because CI will not:
`apps/multiplatform/common/src/commonTest/kotlin/chat/popopx/app/BadgePageUrlTest.kt:11,17` asserts
only the `#/tier?app=…` suffix, so **no test in either tree pins the host** and the swap cannot be
caught by a green run. There is also nothing to change in the Haskell service: `[listener]` carries
only a bind host and port, and the page calls the API relative, so the public origin exists in
exactly the two client constants above and nowhere else.

Suggested order inside the commit: deploy the host and pass all of section (d), then change #1 and
#2. Ships already in the wild keep pointing at whatever URL their build carried, so the upstream
`badges.simplex.chat` stays reachable to old installs regardless of what this repo's master says;
the new host only needs to serve the builds that follow.

## Held on purpose

Recorded so the next reader does not "finish" the job and break something:

- `package.json:2` / `package-lock.json:2` `"simplex-badge-web"` — the npm package name, unread in
  this tree. `CHANGELOG-POPOPX.md:413-416` holds it; its value is set elsewhere.
- The plan-doc URLs in `web/README.md:5-7`, pinned to `github.com/simplex-chat/simplex-chat` at
  `db0768c21` — citations of upstream documents, not ours to rename.
- `src/embed.ts:4-11` `simplex-theme` / `simplex-embed-ready` / … — the postMessage contract with
  the site. Renaming one end silently breaks the embed; it moves only with the site's code.
- `src/icons.ts:98` and the `simplex.domains` provenance comments in `public/styles.css:4,16,20,24,69,98,102,148,152`
  — citations of where the palette, the fonts and the Monero glyph came from. Not rendered.
- `src/routing.ts:24` — the comment on the inherited `simplexchat:` scheme. The apps still accept
  that spelling; only `popopxchat:` is issued.
- Stripe / Bitcoin / Monero / Card wording in `src/screens.ts` (`:354,461,515,640-648,1010`) —
  provider names, not brand names.

## Changed here (this pass)

User-visible copy on our own page, which is a branding requirement:
`src/screens.ts:88` brand `aria-label`, `:231` landing `<h1>`, `:785` `RETURN_TO_APP`, `:804` the
code-screen line — all SimpleX → POPOPX; `public/index.html:20` `<title>`, and the shell markers at
`:42-43` which `npm run build` regenerates from `screens.ts`; `src/domain.ts:15` a comment naming
our own app. The 34 matching assertions across the 15 test files that pin those strings moved with
them, then `npm run build` re-hashed and `npm test` is green at **525/0**.

The artwork needed nothing: `public/img/wordmark-{light,dark}.svg` and `symbol-{light,dark}.svg` are
already POPOPX's own — the wordmark is P-o-p-o-p-x built from rounded rects, circles and an X, the
symbol a `#FAF6FE` speech bubble holding a `#7A2BBE`→`#3D0A6D` "P" pennant — and each is
byte-identical to its master in this repo's `branding/source-svg/apps__popopx-badge-service__web__
public__img__*.svg`, which is what `test/design.test.ts:446-459` pins and what the passing suite
just proved. The hero PNGs are the same mark at 800×1006 (`hero-light.png.src.svg`). No replacement
was invented, because none was due.
