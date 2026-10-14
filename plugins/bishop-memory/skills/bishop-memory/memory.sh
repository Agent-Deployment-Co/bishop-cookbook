#!/usr/bin/env bash
# Changes the shared memory checkout at $AGENT_MEMORY, one writer at a time.
#
#   memory.sh version <topic>                          print a topic's version, or "new"
#   memory.sh save <topic> <version> <subject> <by>    replace a topic with stdin
#   memory.sh forget <topic> <version> <subject> <by>  delete a topic
#   memory.sh undo <commit> <subject> <by>             revert one earlier change
#
# Exit status 3 means memory changed under the caller: read again and retry.
set -euo pipefail

die() {
  printf 'memory: %s\n' "$1" >&2
  exit "${2:-1}"
}

usage() { die 'usage: memory.sh version|save|forget|undo ... (see SKILL.md)' 2; }

mem=${AGENT_MEMORY:-}
[ -n "$mem" ] || die 'AGENT_MEMORY is not set, so there is no memory checkout to use'
git -C "$mem" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "AGENT_MEMORY names $mem, which is not a git checkout"
gitdir=$(git -C "$mem" rev-parse --absolute-git-dir)

topic_file() {
  [[ $1 =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "a topic is lowercase words joined by hyphens, not \"$1\"" 2
  printf '%s/%s.md' "$mem" "$1"
}

version_of() {
  if [ -f "$1" ]; then git -C "$mem" hash-object -- "$1"; else echo new; fi
}

# Held until the script exits. The lock lives in the git directory so the one
# grant a sandboxed agent needs for the checkout covers it too.
lock() {
  command -v flock >/dev/null || die 'flock is not installed'
  exec 9>"$gitdir/memory.lock"
  flock -w 30 9 || die 'another save has held memory for 30 seconds; try again shortly'
}

rebasing() { [ -d "$gitdir/rebase-merge" ] || [ -d "$gitdir/rebase-apply" ]; }

# Brings in saves pushed from other machines. An unreachable remote only costs
# freshness.
#
# A conflict means a save made here never reached the remote before something
# else changed the same topic. The remote's version wins and the save is set
# aside on a ref and handed back to the agent to merge, because leaving the
# rebase for a person would refuse every later save on this host until then.
sync() {
  local out c aside=()
  if out=$(git -C "$mem" pull --quiet --rebase --autostash 2>&1); then return; fi
  if ! rebasing; then
    printf "memory: couldn't fetch, saving on top of this machine's copy: %s\n" "$out" >&2
    return
  fi
  while rebasing; do
    c=$(git -C "$mem" rev-parse REBASE_HEAD)
    git -C "$mem" update-ref "refs/memory/set-aside/$c" "$c"
    aside+=("$c")
    git -C "$mem" rebase --skip >/dev/null 2>&1 && continue
    if rebasing && [ "$(git -C "$mem" rev-parse REBASE_HEAD)" = "$c" ]; then
      git -C "$mem" rebase --abort >/dev/null 2>&1 || true
      die "memory here and on the remote disagree and need someone to reconcile them in $mem"
    fi
  done
  {
    echo 'memory: these saves from here conflicted with changes made elsewhere and were set aside. Read each topic again, merge in what they said, and save it:'
    for c in "${aside[@]}"; do git -C "$mem" show --format='%n%B' "$c"; done
  } >&2
  exit 3
}

# Commits only the named path, so anything else left in the checkout stays out.
commit() {
  local subject=$1 by=$2 path=$3
  git -C "$mem" add -A -- "$path"
  if git -C "$mem" diff --cached --quiet -- "$path"; then
    echo 'memory: nothing changed'
    exit 0
  fi
  git -C "$mem" commit --quiet -m "$subject" --trailer "Taught-by: $by" -- "$path"
}

# A failed push leaves the commit here, where every conversation on this
# machine already reads it, and the next save pushes it along with its own.
publish() {
  local out
  if out=$(git -C "$mem" push --quiet origin HEAD 2>&1); then return; fi
  sync
  if out=$(git -C "$mem" push --quiet origin HEAD 2>&1); then return; fi
  printf "memory: saved on this machine but couldn't push, the next save will try again: %s\n" "$out" >&2
}

check_version() {
  [ "$(version_of "$1")" = "$2" ] || die "$3 changed since you read it; read it again and merge your change into it" 3
}

cmd=${1:-}
[ $# -gt 0 ] && shift
case $cmd in
  version)
    [ $# -eq 1 ] || usage
    version_of "$(topic_file "$1")"
    ;;
  save)
    [ $# -eq 4 ] || usage
    file=$(topic_file "$1")
    content=$(cat)
    [[ $content == '# '* ]] || die 'a topic opens with a "# Heading" line' 2
    lock
    sync
    check_version "$file" "$2" "$1"
    printf '%s\n' "$content" >"$file"
    commit "$3" "$4" "$file"
    publish
    echo "memory: saved $1, now at version $(version_of "$file")"
    ;;
  forget)
    [ $# -eq 4 ] || usage
    file=$(topic_file "$1")
    lock
    sync
    [ -f "$file" ] || die "there is no topic named $1" 2
    check_version "$file" "$2" "$1"
    rm -- "$file"
    commit "$3" "$4" "$file"
    publish
    echo "memory: forgot $1"
    ;;
  undo)
    [ $# -eq 3 ] || usage
    lock
    sync
    git -C "$mem" rev-parse --quiet --verify "$1^{commit}" >/dev/null || die "there is no change $1" 2
    if ! out=$(git -C "$mem" revert --no-commit "$1" 2>&1); then
      git -C "$mem" revert --abort >/dev/null 2>&1 || git -C "$mem" reset --quiet --merge
      die "$1 can't be undone cleanly because what it touched has changed since; save the topic as it should be instead: $out" 3
    fi
    git -C "$mem" commit --quiet -m "$2" --trailer "Taught-by: $3"
    publish
    echo "memory: undid $1"
    ;;
  *) usage ;;
esac
