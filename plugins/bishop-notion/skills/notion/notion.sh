#!/usr/bin/env bash
# notion.sh: call the Notion API as the agent's own Notion connection.
#
#   notion.sh METHOD PATH [BODY | -]
#
# PATH is relative to https://api.notion.com/v1/, for example "search" or
# "pages/<id>/markdown?markdown_version=v2". BODY is a JSON string, or "-" to
# read it from stdin. Prints the JSON response on stdout.
#
# Exit status: 0 on success; 1 on an HTTP error (the error JSON is still
# printed) or a network failure; 2 when NOTION_TOKEN is not set; 64 on bad usage.
#
# Retries rate limits (429, honoring Retry-After) and brief gateway errors.
set -euo pipefail

NOTION_VERSION="2026-03-11"
MAX_ATTEMPTS=4

if [[ -z "${NOTION_TOKEN:-}" ]]; then
  echo "notion.sh: NOTION_TOKEN is not set, so Notion isn't connected in this environment." >&2
  exit 2
fi
if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: notion.sh METHOD PATH [BODY | -]" >&2
  exit 64
fi

method=$(tr '[:lower:]' '[:upper:]' <<<"$1")
path=${2#/}
path=${path#v1/}
url="https://api.notion.com/v1/$path"

body=""
if [[ $# -eq 3 ]]; then
  if [[ $3 == "-" ]]; then body=$(cat); else body=$3; fi
  if ! jq -e . >/dev/null 2>&1 <<<"$body"; then
    echo "notion.sh: BODY is not valid JSON" >&2
    exit 64
  fi
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# The token goes in a private header file so it never appears in a process list.
printf 'Authorization: Bearer %s\n' "$NOTION_TOKEN" >"$tmp/auth"

attempt=1
while :; do
  args=(-sS -X "$method" "$url" -D "$tmp/headers" -o "$tmp/body" -w '%{http_code}'
    -H "Notion-Version: $NOTION_VERSION" -H "@$tmp/auth")
  if [[ -n $body ]]; then
    printf '%s' "$body" >"$tmp/request"
    args+=(-H 'Content-Type: application/json' --data-binary "@$tmp/request")
  fi

  if ! status=$(curl "${args[@]}"); then
    echo "notion.sh: request to $url failed" >&2
    exit 1
  fi

  if ((attempt < MAX_ATTEMPTS)); then
    if [[ $status == 429 ]]; then
      wait=$(awk -F': *' 'tolower($1) == "retry-after" { print int($2) }' "$tmp/headers" | tail -1)
      ((${wait:-0} > 0 && ${wait:-0} <= 60)) || wait=1
      sleep "$wait"
      attempt=$((attempt + 1))
      continue
    fi
    if [[ $status == 502 || $status == 503 || $status == 504 ]]; then
      sleep $((attempt * 2))
      attempt=$((attempt + 1))
      continue
    fi
  fi
  break
done

cat "$tmp/body"
echo
if ((status >= 400)); then
  echo "notion.sh: HTTP $status from $method /v1/$path" >&2
  exit 1
fi
