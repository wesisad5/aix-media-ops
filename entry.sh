#!/usr/bin/env bash
# entry.sh — build-command dispatcher for the aix-media-ops site.
#
# Mode selection (review round-10: title-body hooks + OPS_MODE override;
# INCOMING_HOOK_* env is DUMPED redacted by every mode so exposure stays
# OBSERVED, never assumed):
#   1. OPS_MODE site env (manual override: probe | scrape | media)
#   2. INCOMING_HOOK_TITLE from the hook POST body ({"title":"scrape"})
#   3. default: media (push-triggered builds = media sync, unchanged
#      behavior; also the chained build after a scrape fires media)
set -u
MODE="${OPS_MODE:-}"
HOOK_TITLE="${INCOMING_HOOK_TITLE:-}"
HOOK_URL_TAIL="${INCOMING_HOOK_URL:-}"
# never print secrets: hook URLs embed tokens
case "$HOOK_URL_TAIL" in
  *netlify*) HOOK_URL_TAIL="<set>" ;;
esac
echo "[entry] hook_title='${HOOK_TITLE}' hook_url=${HOOK_URL_TAIL} ops_mode='${OPS_MODE:-}'"

if [ -z "$MODE" ] && [ -n "$HOOK_TITLE" ]; then
  case "$HOOK_TITLE" in
    *scrape*) MODE=scrape ;;
    *probe*)  MODE=probe ;;
    *)        MODE=media ;;
  esac
fi
[ -z "$MODE" ] && MODE=media
echo "[entry] dispatching mode=$MODE"
case "$MODE" in
  probe)  exec bash probe.sh ;;
  scrape) exec bash scrape.sh ;;
  media)  exec bash ops.sh ;;
  *) echo "[entry] unknown OPS_MODE '$MODE' — defaulting to media"; exec bash ops.sh ;;
esac
