#!/usr/bin/env bash
# probe.sh — validates the Netlify-scrape unknowns BEFORE the full build.
#
# Measures (design doc audit/round10/netlify_scrape_migration_design.md):
#   P1. env exposure: INCOMING_HOOK_TITLE / _URL / _BODY (redacted)
#   P2. Python version + pip
#   P3. Playwright + chromium install in the build container
#       (--with-deps fallback plain), with BOTH cache-path candidates
#       ($NETLIFY_BUILD_BASE/.cache and /cache) marker-tested for
#       persistence across builds
#   P4. WAF admission: transport smoke test from the Netlify HK container
#   P5. chain POST /sites/{id}/builds acceptance (queues a media build)
#   P6. status blob REST write
set -u
T0=$(date +%s)
el() { echo $(( $(date +%s) - T0 )); }
say() { echo "[probe $(el)s] $*"; }

OPS_SITE_ID="9f636436-d3c9-439b-976c-e9293e41ccd1"
: "${NETLIFY_AUTH_TOKEN:?required}"
: "${VAULT0_SITE_ID:?required}"

# --- P1: env exposure (observed, not assumed) -----------------------------
say "INCOMING_HOOK_TITLE='${INCOMING_HOOK_TITLE:-}'"
say "INCOMING_HOOK_URL set: $([ -n "${INCOMING_HOOK_URL:-}" ] && echo yes || echo no)"
say "INCOMING_HOOK_BODY set: $([ -n "${INCOMING_HOOK_BODY:-}" ] && echo yes || echo no)"
say "NETLIFY_BUILD_BASE='${NETLIFY_BUILD_BASE:-}' CWD=$(pwd) arch=$(uname -m)"

# --- P3a: cache-path candidates --------------------------------------------
for CAND in "${NETLIFY_BUILD_BASE:-/opt/build}/.cache" "${NETLIFY_BUILD_BASE:-/opt/build}/cache"; do
  if mkdir -p "$CAND/pw-probe" 2>/dev/null; then
    if [ -f "$CAND/pw-probe/marker" ]; then
      say "cache candidate PERSISTED from an earlier build: $CAND"
    else
      say "cache candidate fresh (no marker): $CAND"
      date -u > "$CAND/pw-probe/marker"
    fi
  else
    say "cache candidate NOT writable: $CAND"
  fi
done

# --- P2: python --------------------------------------------------------------
say "python: $(python3 --version 2>&1) ($(which python3))"
say "node: $(node --version 2>&1)"
python3 -m pip --version 2>&1 | head -1 || say "pip MISSING"

# --- P3b: playwright + chromium ---------------------------------------------
PW_CACHE="${NETLIFY_BUILD_BASE:-/opt/build}/.cache/pw-browsers"
export PLAYWRIGHT_BROWSERS_PATH="$PW_CACHE"
say "installing playwright (pip)..."
python3 -m pip install --quiet --disable-pip-version-check playwright 2>&1 | tail -2
say "playwright pip done ($(el)s); installing chromium (--with-deps, fallback plain)..."
if python3 -m playwright install chromium --with-deps > /tmp/pw-install.log 2>&1; then
  say "chromium install WITH deps OK ($(el)s)"
else
  say "chromium --with-deps FAILED (apt denied?) — retrying plain install..."
  python3 -m playwright install chromium > /tmp/pw-install.log 2>&1 \
    && say "chromium plain install OK ($(el)s)" \
    || { say "CHROMIUM INSTALL FAILED:"; tail -15 /tmp/pw-install.log; }
fi
du -sh "$PW_CACHE" 2>/dev/null || true

# --- clone the data repo (scripts only) + token ----------------------------
say "sparse clone of data repo (scripts only)..."
rm -rf data
if ! git clone --filter=blob:none --sparse --depth 5 \
      "https://x-access-token:${GH_PAT}@github.com/wesisad5/aix-studio-scraper.git" data \
      2> >(sed "s|${GH_PAT}|***REDACTED***|g" | tail -3 >&2); then
  say "FATAL: clone failed"; exit 1
fi
( cd data && git sparse-checkout set --no-cone '/scripts/**' 2>/dev/null \
  && [ -f scripts/aix_transport.py ] && say "sparse checkout OK" ) \
  || { say "FATAL: sparse checkout missing pipeline files"; exit 1; }

if [ -n "${AIX_TOKEN:-}" ]; then
  printf '%s' "$AIX_TOKEN" > data/scripts/.aix_token
  say "AIX token written"
else
  say "WARNING: AIX_TOKEN not set — smoke test will run unauthenticated"
fi

# --- P4: WAF admission — the transport smoke --------------------------------
say "transport smoke test (playwright from this container)..."
set +e
( cd data && AIX_TRANSPORT=playwright timeout 240 python3 scripts/aix_transport.py )
SMOKE_RC=$?
set -e
say "smoke rc=$SMOKE_RC (0 = WAF admits this container + full pipeline viable)"

# --- P5: chain POST acceptance ----------------------------------------------
say "chain POST test: POST /sites/$OPS_SITE_ID/builds ..."
CHAIN_CODE=$(curl -s -o /tmp/chain.json -w "%{http_code}" --max-time 30 -X POST \
  -H "Authorization: Bearer $NETLIFY_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.netlify.com/api/v1/sites/$OPS_SITE_ID/builds" -d '{}' || echo 000)
say "chain POST http=$CHAIN_CODE (2xx/409-ish = accepted/queued)"
[ "$CHAIN_CODE" = "000" ] && say "chain body: $(head -c 200 /tmp/chain.json 2>/dev/null)"

# --- P6: status blob REST write ----------------------------------------------
python3 - "$NETLIFY_AUTH_TOKEN" "$VAULT0_SITE_ID" "$SMOKE_RC" "$CHAIN_CODE" "$(el)" <<'EOF'
import json, sys, urllib.request
token, site, smoke, chain, el = sys.argv[1:7]
body = json.dumps({"ts": __import__('subprocess').run(
    ["date","-u","+%FT%TZ"],capture_output=True,text=True).stdout.strip(),
    "build": "probe", "smoke_rc": int(smoke), "chain_http": chain,
    "elapsed_s": int(el)}).encode()
req = urllib.request.Request(
    f"https://api.netlify.com/api/v1/blobs/{site}/site:ops/probe-status",
    data=body, method="PUT",
    headers={"Authorization": f"Bearer {token}",
             "Content-Type": "application/octet-stream"})
try:
    with urllib.request.urlopen(req, timeout=60) as r:
        print(f"[probe {el}s] status blob PUT -> {r.status}")
except Exception as e:
    print(f"[probe {el}s] status blob PUT FAILED: {e}")
EOF

say "probe done in $(el)s (smoke=$SMOKE_RC chain=$CHAIN_CODE)"
[ "$SMOKE_RC" = "0" ] || exit 1
