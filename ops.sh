#!/usr/bin/env bash
# ops.sh — bounded media-sync build for Netlify remote builds (free tier:
# 15 min hard cap; we self-limit to ~13 min of work).
#
# Runs, in order (highest value first):
#   1. thumbs chunk  — new WebP thumbs -> wesisad5/aix-media-thumbs
#                      (Git data API, chunked commits, resumable)
#   2. blob chunk    — new full-res images -> least-filled Netlify vault shard
#                      (direct SDK writes, index checkpoints, resumable)
#   3. status blob   — durable report in the "ops" store on the vault-0 site
#
# Everything is resumable: a 15-min kill loses at most one 200-item chunk.
# Env (set on the Netlify site, never in this public repo):
#   GH_PAT         — PAT with read access to wesisad5/aix-studio-scraper
#                    (sparse clone of scripts + manifest) and the runner repo
#   THUMBS_PAT     — PAT with write access to wesisad5/aix-media-thumbs
#   NETLIFY_AUTH_TOKEN — PAT for blob writes (vault shards)
#   VAULT0_SITE_ID — site id of aix-media-vault (status blob destination)
#   THUMBS_MAX_ITEMS (default 900) — bounded to fit the budget
set -u
BUDGET_S=$((13 * 60))
T0=$(date +%s)
elapsed() { echo $(( $(date +%s) - T0 )); }
left() { echo $(( BUDGET_S - $(elapsed) )); }
say() { echo "[ops $(elapsed)s] $*"; }

: "${GH_PAT:?GH_PAT required}"
: "${THUMBS_PAT:?THUMBS_PAT required}"
: "${NETLIFY_AUTH_TOKEN:?NETLIFY_AUTH_TOKEN required}"
: "${VAULT0_SITE_ID:?VAULT0_SITE_ID required}"
THUMBS_MAX_ITEMS="${THUMBS_MAX_ITEMS:-900}"

say "Netlify media-ops build starting (budget ${BUDGET_S}s)"

# --- 1. sparse-pull the pipeline code + manifest from the data repo -------
say "sparse clone of data repo (scripts + manifest + catalog)..."
rm -rf data
# NOTE: the clone URL embeds the PAT — git prints remote URLs in error
# messages, so stderr is REDACTED before it can reach the build log (P0:
# leaked tokens in Netlify logs are visible to anyone with site access).
if ! git clone --filter=blob:none --sparse --depth 1 \
      "https://x-access-token:${GH_PAT}@github.com/wesisad5/aix-studio-scraper.git" data \
      2> >(sed "s|${GH_PAT}|***REDACTED***|g" | tail -3 >&2); then
  say "FATAL: data repo clone failed (PAT scope? repo moved?)"
  exit 1
fi
cd data
git sparse-checkout set scripts media_shards.json \
  download/aixstudio/media_manifest.json src/data/catalog \
  mini-services/netlify-vault/blob-sync.mjs \
  mini-services/netlify-vault/package.json 2> >(sed "s|${GH_PAT}|***REDACTED***|g" | tail -1 >&2) || true
say "sparse checkout done: $(du -sh . 2>/dev/null | cut -f1)"
cd ..

# --- 2. thumbs chunk (resumable; each chunk is its own commit) ------------
# timeout guard: a stalled CDN day must not eat the whole 15-min build —
# the pusher is resumable, so a kill loses at most one 200-item chunk and
# the status write still happens.
THUMBS_TIME_CAP=$(( BUDGET_S - 300 ))
say "thumbs chunk: max ${THUMBS_MAX_ITEMS} items (cap ${THUMBS_TIME_CAP}s)..."
set +e
THUMBS_RC=0
timeout --signal=TERM --kill-after=20 "$THUMBS_TIME_CAP" \
  env GH_TOKEN="$THUMBS_PAT" python3 data/scripts/aix_thumbs_push_ghapi.py \
  --manifest data/download/aixstudio/media_manifest.json \
  --catalog data/src/data/catalog \
  --max-items "$THUMBS_MAX_ITEMS" --chunk 200 --fetch-workers 6
THUMBS_RC=$?
[ "$THUMBS_RC" = "124" ] && THUMBS_RC=3   # timeout = backlog remains
set -e
say "thumbs chunk rc=$THUMBS_RC (0=complete 3=backlog-remains 1=error)"

# --- 3. blob chunk with the remaining budget -------------------------------
REMAIN_S=$(left)
BLOB_NOTE="not-run"
if [ "$REMAIN_S" -lt 180 ]; then
  say "only ${REMAIN_S}s left — skipping blob chunk (thumbs took the budget)"
  BLOB_NOTE="skipped: budget"
else
  say "blob chunk with ${REMAIN_S}s budget..."
  # guards: a queue/plan failure must degrade to a skipped blob chunk, not
  # crash the build before the status write (pipe-to-tail masks rc — so
  # check the artifacts exist instead of trusting exit codes)
  set +e
  python3 data/scripts/aix_media_queue.py \
    --manifest data/download/aixstudio/media_manifest.json \
    --catalog data/src/data/catalog \
    --out /tmp/media-queue.json > /tmp/queue.log 2>&1
  QRC=$?
  python3 data/scripts/aix_blob_shards.py \
    --registry data/media_shards.json \
    --out /tmp/shard-plan.json \
    --merged-out /tmp/blob-merged-index.json > /tmp/plan.log 2>&1
  PRC=$?
  set -e
  tail -2 /tmp/queue.log; tail -4 /tmp/plan.log
  if [ "$QRC" != "0" ] || [ "$PRC" != "0" ] || [ ! -s /tmp/shard-plan.json ]; then
    say "queue/plan build failed (q=$QRC p=$PRC) — skipping blob chunk"
    BLOB_NOTE="skipped: queue-failed"
  else
    TARGET_SITE=$(python3 -c "import json; print(json.load(open('/tmp/shard-plan.json'))['target']['id'])" 2>/dev/null || echo "")
    if [ -z "$TARGET_SITE" ]; then
      say "no target shard in plan — skipping blob chunk"
      BLOB_NOTE="skipped: no-target"
    else
      say "upload target shard: ${TARGET_SITE:0:8}"
      mkdir -p vault && cp data/mini-services/netlify-vault/blob-sync.mjs vault/ \
        && cp data/mini-services/netlify-vault/package.json vault/
      ( cd vault && npm install --no-audit --no-fund --silent > /tmp/npm.log 2>&1 ) || true
      set +e
      ( cd vault && \
        NETLIFY_AUTH_TOKEN="$NETLIFY_AUTH_TOKEN" TARGET_SITE_ID="$TARGET_SITE" \
        QUEUE_FILE=/tmp/media-queue.json MERGED_INDEX_FILE=/tmp/blob-merged-index.json \
        BLOB_CONCURRENCY=6 BLOB_MAX_MINUTES=$(( REMAIN_S / 60 - 3 )) \
        BLOB_MAX_ITEM_BYTES=60000000 BLOB_FETCH_TIMEOUT_MS=60000 \
        node blob-sync.mjs )
      BLOB_RC=$?
      set -e
      say "blob chunk rc=$BLOB_RC"
      BLOB_NOTE="rc=$BLOB_RC target=${TARGET_SITE:0:8}"
    fi
  fi
fi

# --- 4. status blob (durable report, readable via Blobs API) ---------------
say "installing @netlify/blobs for status write..."
npm install --no-audit --no-fund --silent > /tmp/npm-root.log 2>&1 || true
say "writing status blob..."
STATUS_JSON=$(python3 -c 'import json,sys,subprocess
print(json.dumps({
  "ts": subprocess.run(["date","-u","+%FT%TZ"],capture_output=True,text=True).stdout.strip(),
  "build": "netlify-ops",
  "thumbs_rc": int(sys.argv[1]),
  "blob": sys.argv[2],
  "elapsed_s": int(sys.argv[3]),
}))' "$THUMBS_RC" "${BLOB_NOTE:-not-run}" "$(elapsed)")
node -e "
const { getStore } = require('@netlify/blobs');
(async () => {
  const store = getStore({ name: 'ops', siteID: process.env.VAULT0_SITE_ID, token: process.env.NETLIFY_AUTH_TOKEN });
  await store.set('status', process.argv[1]);
  console.log('[ops] status blob written');
})().catch(e => { console.error('status write failed:', e.message); process.exit(0); });
" "$STATUS_JSON" || true

say "done in $(elapsed)s (thumbs rc=$THUMBS_RC, blob ${BLOB_NOTE:-skipped})"
exit 0
