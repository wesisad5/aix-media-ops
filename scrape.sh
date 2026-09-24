#!/usr/bin/env bash
# scrape.sh — the FULL weekly scrape pipeline as a Netlify remote build.
#
# Design: audit/round10/netlify_scrape_migration_design.md (review-hardened:
# 12-min budget, adaptive suite timeout, scrape-lock with visible defer,
# JSONL+state repair pass, chain POST with retry + recorded http code,
# PAT redaction on clone/pull/push, freshness-monitored status blob).
#
# Sequence: lock -> sparse full-data clone -> playwright -> smoke ->
# scrape suite (timeout-guarded) -> repair -> finalize/build/validate ->
# commit+push data repo -> scrape-status blob -> chain the media build.
set -u
BUDGET_S=$((12 * 60))          # review: 12-min self-limit under the 15-min cap
T0=$(date +%s)
elapsed() { echo $(( $(date +%s) - T0 )); }
left() { echo $(( BUDGET_S - $(elapsed) )); }
say() { echo "[scrape $(elapsed)s] $*"; }

OPS_SITE_ID="9f636436-d3c9-439b-976c-e9293e41ccd1"
DATA_URL="https://x-access-token:${GH_PAT}@github.com/wesisad5/aix-studio-scraper.git"
LOCK_SCRIPT=""
LOCK_SITE="${VAULT0_SITE_ID:-}"
SCRAPE_LOCK_HELD=0
redact() { sed "s|${GH_PAT}|***REDACTED***|g"; }   # PAT never reaches logs
trap 'if [ "$SCRAPE_LOCK_HELD" = "1" ] && [ -f "$LOCK_SCRIPT" ]; then python3 "$LOCK_SCRIPT" release --site "$LOCK_SITE" --key scrape-lock --holder netlify-scrape || true; fi' EXIT

# --- status blob helper (pure REST, no node) --------------------------------
write_status() {  # $1..=kwargs
  python3 - "$NETLIFY_AUTH_TOKEN" "$LOCK_SITE" "$(elapsed)" "$@" <<'EOF'
import json, sys, urllib.request
token, site, el = sys.argv[1], sys.argv[2], sys.argv[3]
d = {"ts": __import__('subprocess').run(["date","-u","+%FT%TZ"],
     capture_output=True,text=True).stdout.strip(),
     "build": "netlify-scrape", "elapsed_s": int(el)}
for kv in sys.argv[4:]:
    if "=" in kv:
        k, v = kv.split("=", 1)
        d[k] = v if not v.lstrip("-").isdigit() else int(v)
req = urllib.request.Request(
    f"https://api.netlify.com/api/v1/blobs/{site}/site:ops/scrape-status",
    data=json.dumps(d).encode(), method="PUT",
    headers={"Authorization": f"Bearer {token}",
             "Content-Type": "application/octet-stream"})
try:
    with urllib.request.urlopen(req, timeout=60) as r:
        print(f"[status] PUT -> {r.status}", flush=True)
except Exception as e:
    print(f"[status] PUT FAILED: {e}", flush=True)
EOF
}

chain_media_build() {  # retry x2; echoes final http code
  local code
  for i in 1 2 3; do
    code=$(curl -s -o /tmp/chain.json -w "%{http_code}" --max-time 30 -X POST \
      -H "Authorization: Bearer $NETLIFY_AUTH_TOKEN" \
      -H "Content-Type: application/json" \
      "https://api.netlify.com/api/v1/sites/$OPS_SITE_ID/builds" -d '{}' || echo 000)
    case "$code" in 2*|429) break ;; esac
    [ "$i" = "3" ] || sleep 5
  done
  echo "$code"
}

: "${GH_PAT:?GH_PAT required}"
: "${NETLIFY_AUTH_TOKEN:?NETLIFY_AUTH_TOKEN required}"
: "${VAULT0_SITE_ID:?VAULT0_SITE_ID required}"
say "Netlify scrape build starting (budget ${BUDGET_S}s)"

# --- 1. scrape-lock (holders: this build / manual GHA dispatch) ------------
say "acquiring scrape-lock..."
set +e
LOCK_RCV=1
if [ -n "${NETLIFY_AUTH_TOKEN:-}" ]; then
  # lock script comes from the data repo below; if absent, proceed unlocked
  :
fi
set -e
# (lock is taken AFTER the clone — the script lives in the data repo; a
# concurrent scrape can't start anyway: free plan = 1 concurrent build, and
# the GHA manual path takes the same lock before scraping)

# --- 2. sparse full-data clone ----------------------------------------------
say "sparse clone of data repo (full data set)..."
rm -rf data
if ! git clone --filter=blob:none --sparse --depth 50 "$DATA_URL" data \
      2> >(redact | tail -3 >&2); then
  say "FATAL: data repo clone failed"; write_status rc=1 error=clone; exit 1
fi
( cd data && git sparse-checkout set --no-cone \
    '/scripts/**' '/download/**' '/media_shards.json' '/src/data/catalog/**' \
    2> >(redact | tail -2 >&2) )
if [ ! -f data/scripts/aix_scraper.py ] || [ ! -d data/download/aixstudio ]; then
  say "FATAL: sparse checkout incomplete (pipeline files / data missing)"
  write_status rc=1 error=sparse; exit 1
fi
say "clone done: $(du -sh data 2>/dev/null | cut -f1) ($(elapsed)s)"

LOCK_SCRIPT="$PWD/data/scripts/blob_sync_lock.py"
if [ -f "$LOCK_SCRIPT" ]; then
  set +e
  python3 "$LOCK_SCRIPT" acquire --site "$LOCK_SITE" --key scrape-lock \
    --holder netlify-scrape --ttl 1800
  LRC=$?
  set -e
  case "$LRC" in
    0) SCRAPE_LOCK_HELD=1; say "scrape-lock acquired" ;;
    3) say "scrape-lock held elsewhere — DEFERRING (visible, not silent)"
       write_status rc=3 deferred=true
       say "chaining the media build so this week's media still syncs..."
       CH=$(chain_media_build); say "chain http=$CH"
       exit 0 ;;
    *) say "WARNING: lock acquire rc=$LRC — proceeding unlocked (best-effort)" ;;
  esac
else
  say "WARNING: blob_sync_lock.py missing — proceeding unlocked"
fi

# --- 3. playwright + chromium (persisted in .cache where available) --------
export PLAYWRIGHT_BROWSERS_PATH="${NETLIFY_BUILD_BASE:-/opt/build}/.cache/pw-browsers"
say "installing playwright + chromium..."
python3 -m pip install --quiet --disable-pip-version-check playwright 2>&1 | tail -1
if ! python3 -m playwright install chromium --with-deps > /tmp/pw.log 2>&1; then
  say "--with-deps failed; plain install fallback..."
  python3 -m playwright install chromium >> /tmp/pw.log 2>&1 \
    || { say "CHROMIUM INSTALL FAILED"; tail -10 /tmp/pw.log
         write_status rc=1 error=chromium; exit 1; }
fi
say "playwright ready ($(elapsed)s)"

# --- 4. token + smoke --------------------------------------------------------
if [ -n "${AIX_TOKEN:-}" ]; then
  printf '%s' "$AIX_TOKEN" > data/scripts/.aix_token
else
  say "WARNING: AIX_TOKEN unset — authed scrape will fail"
fi
export AIX_BASE="$PWD/data"
export AIX_TRANSPORT=playwright
say "transport smoke test..."
set +e
( cd data && timeout 240 python3 scripts/aix_transport.py )
SMOKE=$?
set -e
if [ "$SMOKE" != "0" ]; then
  say "FATAL: transport smoke failed (rc=$SMOKE) — WAF/site issue from this container"
  write_status rc=1 error=smoke; exit 1
fi
say "smoke OK"

# --- 5. scrape suite (timeout-guarded, adaptive) ----------------------------
# post-suite reserve: finalize+builders+validate+push+status+chain measured
# ~1.5-3 min on GHA — reserve 200s (review fix; was a fixed 360s cap)
SUITE_RC=0
PARTIAL=0
for step in aix_scraper.py aix_auth_scrape.py aix_prism_tags.py \
            aix_lib_details.py aix_aux.py aix_enrich.py; do
  # adaptive: each step gets whatever budget remains minus the post-suite
  # reserve (200s) and a floor so tiny budgets don't spin
  REMAIN=$(( $(left) - 200 ))
  if [ "$REMAIN" -lt 60 ]; then
    say "budget floor hit before $step — marking partial"
    PARTIAL=1; break
  fi
  set +e
  ( cd data && timeout --signal=TERM --kill-after=15 "$REMAIN" \
      python3 "scripts/$step" )
  RC=$?
  set -e
  # progress marker: Netlify build logs are UI-only, so every step reports
  # into the status blob for log-free diagnosis (suite_rc=1 above was only
  # diagnosable by inference before this)
  write_status rc=255 step="$step" step_rc=$RC partial=$PARTIAL || true
  if [ "$RC" = "124" ]; then
    say "$step TIMED OUT — partial capture, remainder defers to next run"
    PARTIAL=1; break
  fi
  if [ "$RC" != "0" ] && [ "$RC" != "3" ]; then
    say "$step FAILED rc=$RC — continuing with lighter steps (fail recorded)"
    SUITE_RC=$RC
  fi
done
say "suite done rc=$SUITE_RC partial=$PARTIAL ($(left)s left)"

# --- 6. repair pass (torn JSONL lines / corrupt state files) ----------------
say "repair pass (torn trailing JSONL lines + state files)..."
python3 - <<'EOF'
import glob, json, os
BASE = os.environ["AIX_BASE"]
fixed = []
# 1) JSONL: drop a torn trailing line (record re-fetched next run — idempotent)
for p in glob.glob(f"{BASE}/download/aixstudio/**/*.jsonl", recursive=True):
    try:
        with open(p, "rb") as f:
            data = f.read()
        lines = data.split(b"\n")
        # file ends with \n normally; trailing element b"" is fine
        if lines and lines[-1] != b"":
            try:
                json.loads(lines[-1])
            except Exception:
                with open(p, "wb") as f:
                    f.write(b"\n".join(lines[:-1]) + (b"\n" if data.endswith(b"\n") else b""))
                fixed.append((p, "torn-last-line-dropped"))
    except Exception:
        pass
# 2) JSON state/profile files: delete-on-corrupt (all are re-buildable:
#    state = progress cursors (tolerant re-sweep), user_profiles = re-fetch)
for p in [f"{BASE}/download/aixstudio/user_profiles.json",
          f"{BASE}/scripts/aix_state.json", f"{BASE}/scripts/aix_prism_state.json",
          f"{BASE}/scripts/aix_auth_state.json",
          f"{BASE}/scripts/aix_lib_detail_state.json"]:
    if os.path.exists(p):
        try:
            json.load(open(p))
        except Exception:
            os.remove(p)
            fixed.append((p, "corrupt-json-deleted"))
for p, why in fixed:
    print(f"  repaired: {os.path.basename(p)} ({why})")
print(f"repair pass done: {len(fixed)} fixes")
EOF

# --- 7. finalize + rebuild catalogs + manifest ------------------------------
say "finalize + rebuild..."
set +e
( cd data && python3 scripts/aix_finalize.py ) && \
( cd data && python3 scripts/aix_build_catalog.py ) && \
( cd data && python3 scripts/aix_build_catalog_auth.py ) && \
( cd data && python3 scripts/aix_media_manifest.py )
FIN_RC=$?
set -e
if [ "$FIN_RC" != "0" ]; then
  say "FATAL: finalize/build failed rc=$FIN_RC — not pushing"
  write_status rc=1 error=finalize partial=$PARTIAL; exit 1
fi
say "rebuild OK ($(left)s left)"

# --- 8. validate --------------------------------------------------------------
set +e
( cd data && python3 scripts/aix_validate.py )
VAL_RC=$?
set -e
if [ "$VAL_RC" != "0" ]; then
  say "FATAL: validation gate failed rc=$VAL_RC — not pushing"
  write_status rc=1 error=validate partial=$PARTIAL; exit 1
fi
say "validation OK"

# --- 9. commit + push ---------------------------------------------------------
say "commit + push data repo..."
( cd data
  git config user.name "netlify-ops[bot]"
  git config user.email "netlify-ops[bot]@users.noreply.github.com"
  git add -A
  if git diff --staged --quiet; then
    echo "[scrape] no changes — data unchanged this run"
    exit 42
  fi
  TOTAL=$(python3 -c "import json;print(sum(json.load(open('src/data/catalog/index.json'))['counts'].values()))")
  [ "$PARTIAL" = "1" ] && MARK=" (PARTIAL — remainder next run)" || MARK=""
  git commit -q -m "netlify scrape $(date -u '+%Y-%m-%d %H:%M UTC'): ${TOTAL} records${MARK}"
  # rebase safety: fetch more history first (shallow clone + advanced remote
  # lacks a merge base otherwise)
  git fetch --depth 50 origin main 2> >(redact | tail -2 >&2)
  if ! git pull --rebase origin main 2> >(redact | tail -3 >&2); then
    echo "[scrape] data repo advanced mid-run — rebase conflict; aborting (delta re-capturable)"
    git rebase --abort 2>/dev/null || true
    exit 1
  fi
  git push origin main 2> >(redact | tail -3 >&2)
) 
PUSH_RC=$?
if [ "$PUSH_RC" = "42" ]; then
  say "no data changes this run (clean week)"
  PUSH_RC=0
  RECORDS="unchanged"
elif [ "$PUSH_RC" != "0" ]; then
  say "FATAL: push failed rc=$PUSH_RC"
  write_status rc=1 error=push partial=$PARTIAL; exit 1
else
  RECORDS=$(python3 -c "import json;print(sum(json.load(open('data/src/data/catalog/index.json'))['counts'].values()))")
  say "pushed: $RECORDS records"
fi

# --- 10. status + chain --------------------------------------------------------
say "chaining the media build (thumbs + blob chunks)..."
CH=$(chain_media_build)
say "chain http=$CH (2xx/4xx-queued = ok; recorded for the monitor)"
RC=0
[ "$SUITE_RC" != "0" ] && RC=2
write_status rc=$RC partial=$PARTIAL suite_rc=$SUITE_RC \
  records="$RECORDS" chain_http="$CH"
say "scrape build done in $(elapsed)s (rc=$RC partial=$PARTIAL chain=$CH)"
exit "$RC"
