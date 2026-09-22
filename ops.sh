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
# Both chunks take an advisory lock blob on vault-0's "ops" store (scripts/
# blob_sync_lock.py in the data repo) so this executor and the weekly GHA
# run never write the same store concurrently (round-9 A6-P1-1/P2-4).
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
# FIX 2026-09-23: cone-mode sparse-checkout REJECTS file pathspecs ("fatal:
# 'media_shards.json' is not a directory") — the whole set aborted, the || true
# swallowed it, and the build ran with ZERO pipeline files (thumbs_rc=2 in 2s).
# Non-cone patterns accept exact files. rc is captured directly (process
# substitution preserves $?; the old `|| true` was the real rc-eater) and the
# build now FAILS LOUDLY if the pipeline files are missing — a silent
# no-op build burns a remote-build slot and reports a green lie.
SPARSE_LOG=$(mktemp)
git sparse-checkout set --no-cone \
  '/scripts/**' '/media_shards.json' \
  '/download/aixstudio/media_manifest.json' \
  '/src/data/catalog/**' \
  '/mini-services/netlify-vault/blob-sync.mjs' \
  '/mini-services/netlify-vault/package.json' \
  2> "$SPARSE_LOG"
SPARSE_RC=$?
sed "s|${GH_PAT}|***REDACTED***|g" "$SPARSE_LOG" | tail -2 >&2
if [ "$SPARSE_RC" != "0" ] || [ ! -f scripts/aix_thumbs_push_ghapi.py ] \
   || [ ! -f scripts/aix_media_queue.py ]; then
  say "FATAL: sparse checkout failed (rc=$SPARSE_RC) — pipeline files missing"
  cd ..
  exit 1
fi
say "sparse checkout done: $(du -sh . 2>/dev/null | cut -f1)"
cd ..

# --- advisory locks (round-9 A6-P1-1 / A6-P2-4) ----------------------------
# The weekly GHA run (aixfeed/aix-studio-runner) executes the SAME writers
# against the same stores: blob-sync.mjs -> same least-filled shard (the
# chooser is deterministic, and the shard index write is last-writer-wins)
# and aix_thumbs_push_ghapi.py -> same thumbs-repo ref (GET->PATCH 422
# race). Both executors now take a lock blob on vault-0's `ops` store
# before each chunk; the loser defers (skip-with-notice — both chunks are
# resumable, so the next run picks up the backlog with no data loss).
# Lock script missing (data repo not carrying it yet) or lock-API error
# (rc=1) = proceed unlocked with a warning: best-effort advisory lock, a
# lock outage must not idle the migration. Crashed holders self-heal via
# the lock TTL (1800s > the ~13-min build budget).
LOCK_SCRIPT="$PWD/data/scripts/blob_sync_lock.py"
LOCK_SITE="$VAULT0_SITE_ID"
THUMBS_LOCK_HELD=0
BLOB_LOCK_HELD=0
release_lock() {  # $1=key $2=holder — best-effort, never fails the build
  [ -f "$LOCK_SCRIPT" ] || return 0
  python3 "$LOCK_SCRIPT" release --site "$LOCK_SITE" --key "$1" --holder "$2" \
    || say "WARNING: lock release $1 failed (TTL will expire it)"
  return 0
}
release_locks() {
  [ "$THUMBS_LOCK_HELD" = "1" ] && release_lock thumbs-push-lock netlify-ops
  [ "$BLOB_LOCK_HELD" = "1" ] && release_lock blob-sync-lock netlify-ops
  return 0
}
lock_acquire() {  # $1=key $2=holder -> 0=acquired 3=held-elsewhere 1=error
  if [ ! -f "$LOCK_SCRIPT" ]; then
    say "WARNING: blob_sync_lock.py not in data repo — proceeding unlocked"
    return 0
  fi
  python3 "$LOCK_SCRIPT" acquire --site "$LOCK_SITE" --key "$1" --holder "$2"
  return $?
}
trap release_locks EXIT

# --- 2. thumbs chunk (resumable; each chunk is its own commit) ------------
# timeout guard: a stalled CDN day must not eat the whole 15-min build —
# the pusher is resumable, so a kill loses at most one 200-item chunk and
# the status write still happens.
# A6-P2-4: thumbs-push-lock FIRST — the weekly GHA run pushes to the SAME
# Netlify thumbs store; concurrent index writes clobber (round-5 class).
# Lock held elsewhere -> defer (rc=3, backlog semantics).
# ROUND-9 CUTOVER: pushes go to the NETLIFY thumbs blob store — the GH
# thumbs repo is FROZEN and serves only as the route's fallback tier.
THUMBS_TIME_CAP=$(( BUDGET_S - 300 ))
THUMBS_RC=0
THUMBS_NOTE=""
THUMBS_SKIP=0
set +e
lock_acquire thumbs-push-lock netlify-ops
TL_RC=$?
set -e
case "$TL_RC" in
  0) THUMBS_LOCK_HELD=1 ;;
  3) say "thumbs-push-lock held by another executor — deferring thumbs chunk"
     THUMBS_RC=3; THUMBS_NOTE="skipped: lock-held"; THUMBS_SKIP=1 ;;
  *) say "WARNING: thumbs lock acquire rc=$TL_RC — proceeding unlocked" ;;
esac
if [ "$THUMBS_SKIP" = "1" ]; then
  say "thumbs chunk skipped (lock held elsewhere — deferred, no data loss)"
else
  say "thumbs chunk: max ${THUMBS_MAX_ITEMS} items (cap ${THUMBS_TIME_CAP}s)..."
  set +e
  timeout --signal=TERM --kill-after=20 "$THUMBS_TIME_CAP" \
    env NETLIFY_AUTH_TOKEN="$NETLIFY_AUTH_TOKEN" \
        THUMBS_SITE_ID=75c01060-e863-4377-bbed-820ce64fafac \
    python3 data/scripts/aix_thumbs_push_netlify.py \
    --manifest data/download/aixstudio/media_manifest.json \
    --catalog data/src/data/catalog \
    --max-items "$THUMBS_MAX_ITEMS" --chunk 200 --fetch-workers 6
  THUMBS_RC=$?
  [ "$THUMBS_RC" = "124" ] && THUMBS_RC=3   # timeout = backlog remains
  set -e
fi
if [ "$THUMBS_LOCK_HELD" = "1" ]; then
  release_lock thumbs-push-lock netlify-ops
  THUMBS_LOCK_HELD=0
fi
say "thumbs chunk rc=$THUMBS_RC (0=complete 3=backlog-remains/deferred 1=error)"

# --- 3. blob chunk with the remaining budget -------------------------------
# A6-P2-5: BLOB_MAX_MINUTES=$((REMAIN_S/60-3)) evaluates to exactly 0 when
# REMAIN_S is in [180,239] (integer division) — and blob-sync treats 0 as
# UNLIMITED (falsy env guard), so a slow thumbs chunk could push the blob
# writer past the 15-min build cap and orphan the status write. Skip below
# 300s (real reserve for the status write) and clamp the cap to >= 1.
# A6-P1-1: blob-sync-lock FIRST (before the plan: the chooser reads shard
# indexes) — the weekly GHA blob step can be writing the SAME least-filled
# shard right now; two blind writers clobber the shard index
# last-writer-wins. Lock held elsewhere -> skip (deferred; content-keyed
# blobs make the next run's catch-up idempotent).
REMAIN_S=$(left)
BLOB_NOTE="not-run"
BLOB_RC=""
BLOB_SKIP=0
if [ "$REMAIN_S" -lt 300 ]; then
  say "only ${REMAIN_S}s left — skipping blob chunk (budget reserve for status write)"
  BLOB_NOTE="skipped: budget"
else
  say "blob chunk with ${REMAIN_S}s budget..."
  set +e
  lock_acquire blob-sync-lock netlify-ops
  BL_RC=$?
  set -e
  case "$BL_RC" in
    0) BLOB_LOCK_HELD=1 ;;
    3) say "blob-sync-lock held by another executor — skipping blob chunk (deferred)"
       BLOB_NOTE="skipped: lock-held"; BLOB_SKIP=1 ;;
    *) say "WARNING: blob lock acquire rc=$BL_RC — proceeding unlocked" ;;
  esac
  if [ "$BLOB_SKIP" != "1" ]; then
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
        # A6-P2-5 (clamp + belt-and-braces hard timeout): the env cap stays
        # for blob-sync's own budgeting, but a `timeout` wrapper makes the
        # bound independent of its env parsing (rc 124 -> 3, backlog). 90s
        # reserved for the status write below.
        BLOB_MAX_MINUTES=$(( REMAIN_S / 60 - 3 ))
        if [ "$BLOB_MAX_MINUTES" -lt 1 ]; then
          say "blob budget < 1 min after reserve — skipping blob chunk"
          BLOB_NOTE="skipped: budget"
        else
          BLOB_TIME_CAP=$(( REMAIN_S - 90 ))
          set +e
          ( cd vault && \
            NETLIFY_AUTH_TOKEN="$NETLIFY_AUTH_TOKEN" TARGET_SITE_ID="$TARGET_SITE" \
            QUEUE_FILE=/tmp/media-queue.json MERGED_INDEX_FILE=/tmp/blob-merged-index.json \
            BLOB_CONCURRENCY=6 BLOB_MAX_MINUTES="$BLOB_MAX_MINUTES" \
            BLOB_MAX_ITEM_BYTES=60000000 BLOB_FETCH_TIMEOUT_MS=60000 \
            timeout --signal=TERM --kill-after=20 "$BLOB_TIME_CAP" node blob-sync.mjs )
          BLOB_RC=$?
          [ "$BLOB_RC" = "124" ] && BLOB_RC=3   # hard timeout = backlog remains
          set -e
          say "blob chunk rc=$BLOB_RC"
          BLOB_NOTE="rc=$BLOB_RC target=${TARGET_SITE:0:8}"
        fi
      fi
    fi
  fi
  if [ "$BLOB_LOCK_HELD" = "1" ]; then
    release_lock blob-sync-lock netlify-ops
    BLOB_LOCK_HELD=0
  fi
fi

# --- 4. status blob (durable report, readable via Blobs API) ---------------
say "installing @netlify/blobs for status write..."
npm install --no-audit --no-fund --silent > /tmp/npm-root.log 2>&1 || true
say "writing status blob..."
STATUS_JSON=$(python3 -c 'import json,sys,subprocess
d = {
  "ts": subprocess.run(["date","-u","+%FT%TZ"],capture_output=True,text=True).stdout.strip(),
  "build": "netlify-ops",
  "thumbs_rc": int(sys.argv[1]),
  "blob": sys.argv[2],
  "elapsed_s": int(sys.argv[3]),
}
if len(sys.argv) > 4 and sys.argv[4]:
  d["thumbs"] = sys.argv[4]   # e.g. "skipped: lock-held"
print(json.dumps(d))' "$THUMBS_RC" "${BLOB_NOTE:-not-run}" "$(elapsed)" "${THUMBS_NOTE:-}")
node -e "
const { getStore } = require('@netlify/blobs');
(async () => {
  const store = getStore({ name: 'ops', siteID: process.env.VAULT0_SITE_ID, token: process.env.NETLIFY_AUTH_TOKEN });
  await store.set('status', process.argv[1]);
  console.log('[ops] status blob written');
})().catch(e => { console.error('status write failed:', e.message); process.exit(0); });
" "$STATUS_JSON" || true

say "done in $(elapsed)s (thumbs rc=$THUMBS_RC, blob ${BLOB_NOTE:-skipped})"

# A6-P2-6: a real failure must FAIL the build — rc 1 (fatal: bad PAT,
# unreadable index) and 137 (OOM kill) used to flow into a green `exit 0`,
# contradicting the fail-loud principle above. 0 (complete) and 3
# (backlog-remains / deferred-by-lock) stay green. The status blob write
# above has already happened either way.
EXIT_RC=0
case "$THUMBS_RC" in
  0|3) ;;
  *) say "thumbs chunk FAILED (rc=$THUMBS_RC) — failing the build"; EXIT_RC=1 ;;
esac
if [ -n "$BLOB_RC" ]; then
  case "$BLOB_RC" in
    0|3) ;;
    *) say "blob chunk FAILED (rc=$BLOB_RC) — failing the build"; EXIT_RC=1 ;;
  esac
fi
exit "$EXIT_RC"
