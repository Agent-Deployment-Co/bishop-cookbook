#!/usr/bin/env bash
# Keeps what an agent learns as one Markdown file per topic under memory/ on
# its repository's default branch, read from and written to the remote.
#
# Writes never touch a checkout. Each one builds a commit with plumbing on top
# of the remote tip and pushes it, so it works from a detached snapshot, from a
# thread's own worktree, or from a checkout with unrelated edits in it, and a
# thread branch that is later deleted never holds the only copy.
set -euo pipefail

DIR=memory
REMOTE=${BISHOP_MEMORY_REMOTE:-origin}
TRIES=5
CONFLICT=3

usage() {
  cat <<'EOF'
Usage: memory.sh <command> [args]

  list                          every topic and its first line
  read <topic>                  print a topic
  search <text>                 lines mentioning text, case-insensitive
  history [topic] [-n N]        what was learned, newest first
  save <topic> -m <msg> [--by <who>] [--after <version>]
                                replace a topic with stdin
  forget <topic> -m <msg> [--by <who>] --after <version>
                                remove a topic
  undo <commit> -m <msg> [--by <who>]
                                put back what a change replaced

Topics are lowercase letters, digits, and hyphens. read reports a topic's
version, and changing a topic that exists takes --after with that version.
Exit status 3 means the topic changed since that read: read it again, merge,
and retry.
EOF
}

die() {
  echo "bishop-memory: $*" >&2
  exit 1
}

cmd=${1:-}
[[ -n $cmd ]] || { usage >&2; exit 1; }
shift
case $cmd in
  -h | --help | help) usage; exit 0 ;;
esac

git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
git remote get-url "$REMOTE" >/dev/null 2>&1 ||
  die "this repository has no remote named $REMOTE to keep memory on"

branch() {
  if [[ -n ${BISHOP_MEMORY_BRANCH:-} ]]; then
    echo "$BISHOP_MEMORY_BRANCH"
    return
  fi
  local b
  b=$(git ls-remote --symref "$REMOTE" HEAD | awk '/^ref:/ { sub("refs/heads/", "", $2); print $2; exit }')
  [[ -n $b ]] || die "could not find the default branch of $REMOTE"
  echo "$b"
}

# The remote tip as a commit present locally. The sha comes from ls-remote
# rather than FETCH_HEAD, which concurrent threads sharing one git directory
# would overwrite under each other, and the empty refmap keeps the fetch from
# moving remote-tracking refs Bishop's own mirror reads.
tip() {
  local sha
  sha=$(git ls-remote "$REMOTE" "refs/heads/$BRANCH" | awk '{ print $1; exit }')
  [[ -n $sha ]] || die "$REMOTE has no branch $BRANCH"
  git fetch -q --no-write-fetch-head --refmap= "$REMOTE" "refs/heads/$BRANCH" ||
    die "could not fetch $BRANCH from $REMOTE"
  git cat-file -e "$sha^{commit}" 2>/dev/null || die "fetched $BRANCH but $sha is missing"
  echo "$sha"
}

check_topic() {
  [[ $1 =~ ^[a-z0-9]+(-[a-z0-9]+)*$ && ${#1} -le 64 ]] ||
    die "topic '$1' must be lowercase letters, digits, and single hyphens, at most 64 characters"
}

# Blob id of path at rev, or "-" when the path is absent.
blob_at() {
  git rev-parse -q --verify "$1:$2" 2>/dev/null || echo -
}

# What a writer read, checked against the topic as it is now. Compared here
# rather than at push time, since a write landing between the agent's read and
# its save is the one that would otherwise be lost.
expect_read() {
  local path=$1 current=$2
  if [[ $current == - ]]; then
    [[ -z $AFTER ]] && return
    echo "bishop-memory: $path was removed since it was read" >&2
    exit $CONFLICT
  fi
  if [[ -z $AFTER ]]; then
    echo "bishop-memory: $path already exists; read it, merge, and pass --after with its version" >&2
    exit $CONFLICT
  fi
  if [[ ${#AFTER} -lt 7 || $current != "$AFTER"* ]]; then
    echo "bishop-memory: $path changed since it was read; read it again and retry" >&2
    exit $CONFLICT
  fi
}

summary() {
  git show "$1:$2" | awk 'NF { sub(/^#+[ \t]*/, ""); print; exit }'
}

# A commit needs an identity, and a host without one configured shouldn't
# cost the agent what it learned.
ensure_identity() {
  if ! git config user.email >/dev/null; then
    export GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME:-bishop-memory} GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL:-bishop-memory@localhost}
    export GIT_COMMITTER_NAME=${GIT_COMMITTER_NAME:-bishop-memory} GIT_COMMITTER_EMAIL=${GIT_COMMITTER_EMAIL:-bishop-memory@localhost}
  fi
}

# Commits CHANGES on top of the remote tip and pushes, retrying from a fresh
# tip when another writer got there first. Each change is
# "path<TAB>new-blob<TAB>expected-blob", "-" meaning absent. A path whose blob
# at the tip is not the expected one is a conflict rather than a retry,
# because writing over it would lose what the other writer saved.
CHANGES=()
commit_changes() {
  local message=$1 base=$2 attempt tree commit line path new expected
  local idx err
  idx=$(mktemp -u)
  err=$(mktemp)
  ensure_identity
  for ((attempt = 1; attempt <= TRIES; attempt++)); do
    for line in "${CHANGES[@]}"; do
      IFS=$'\t' read -r path new expected <<<"$line"
      if [[ $(blob_at "$base" "$path") != "$expected" ]]; then
        rm -f "$idx" "$err"
        echo "bishop-memory: $path changed since it was read; read it again and retry" >&2
        exit $CONFLICT
      fi
    done
    rm -f "$idx"
    GIT_INDEX_FILE=$idx git read-tree "$base"
    for line in "${CHANGES[@]}"; do
      IFS=$'\t' read -r path new expected <<<"$line"
      if [[ $new == - ]]; then
        GIT_INDEX_FILE=$idx git update-index --force-remove -- "$path"
      else
        GIT_INDEX_FILE=$idx git update-index --add --cacheinfo "100644,$new,$path"
      fi
    done
    tree=$(GIT_INDEX_FILE=$idx git write-tree)
    if [[ $tree == $(git rev-parse "$base^{tree}") ]]; then
      rm -f "$idx" "$err"
      echo "Nothing changed: memory already says that."
      return
    fi
    commit=$(printf '%s\n' "$message" | git commit-tree "$tree" -p "$base")
    if git push -q "$REMOTE" "$commit:refs/heads/$BRANCH" 2>"$err"; then
      rm -f "$idx" "$err"
      echo "Saved as $(git rev-parse --short "$commit")."
      return
    fi
    # A tip that moved means another writer won, whichever way git words the
    # rejection. One that didn't, such as branch protection, won't change on
    # retry.
    if [[ $(git ls-remote "$REMOTE" "refs/heads/$BRANCH" | awk '{ print $1; exit }') == "$base" ]]; then
      cat "$err" >&2
      rm -f "$idx" "$err"
      die "could not push to $BRANCH on $REMOTE"
    fi
    base=$(tip)
  done
  rm -f "$idx" "$err"
  die "gave up after $TRIES attempts: $BRANCH on $REMOTE kept moving"
}

# Parses -m, --by, and --after for the commands that write, leaving
# positionals in ARGS.
MSG= BY= AFTER= ARGS=()
parse_write_flags() {
  while (($#)); do
    case $1 in
      -m) MSG=${2:?-m needs a message}; shift 2 ;;
      --by) BY=${2:?--by needs a name}; shift 2 ;;
      --after) AFTER=${2:?--after needs a version}; shift 2 ;;
      *) ARGS+=("$1"); shift ;;
    esac
  done
  [[ -n $MSG ]] || die "-m <message> is required: say what was learned"
}

message() {
  if [[ -n $BY ]]; then
    printf '%s\n\nTaught-by: %s' "$MSG" "$BY"
  else
    printf '%s' "$MSG"
  fi
}

BRANCH=$(branch)

case $cmd in
  list)
    base=$(tip)
    found=
    while IFS= read -r path; do
      [[ $path == *.md ]] || continue
      found=1
      printf '%s: %s\n' "$(basename "$path" .md)" "$(summary "$base" "$path")"
    done < <(git ls-tree --name-only "$base" -- "$DIR/")
    [[ -n $found ]] || echo "Nothing remembered yet."
    ;;

  read)
    (($# == 1)) || die "usage: read <topic>"
    check_topic "$1"
    base=$(tip)
    git show "$base:$DIR/$1.md" 2>/dev/null || die "nothing remembered about $1"
    # stderr, so stdout stays exactly the topic for the agent to merge into.
    echo "bishop-memory: version $(git rev-parse --short=12 "$base:$DIR/$1.md")" >&2
    ;;

  search)
    (($# >= 1)) || die "usage: search <text>"
    base=$(tip)
    if ! git grep -i -n -F -e "$*" "$base" -- "$DIR/" | sed "s|^$base:$DIR/||"; then
      echo "Nothing remembered mentions that."
    fi
    ;;

  history)
    n=20 paths=("$DIR/")
    while (($#)); do
      case $1 in
        -n) n=${2:?-n needs a number}; shift 2 ;;
        *) check_topic "$1"; paths=("$DIR/$1.md"); shift ;;
      esac
    done
    base=$(tip)
    git log -n "$n" --date=short \
      --format='%h %ad %s%x09%(trailers:key=Taught-by,valueonly,separator=%x2C )' \
      "$base" -- "${paths[@]}" |
      awk -F '\t' '{ print ($2 == "" ? $1 : $1 " (taught by " $2 ")") }'
    ;;

  save)
    parse_write_flags "$@"
    ((${#ARGS[@]} == 1)) || die "usage: save <topic> -m <message> [--by <who>] [--after <version>] < content"
    topic=${ARGS[0]}
    check_topic "$topic"
    content=$(mktemp)
    trap 'rm -f "$content"' EXIT
    cat >"$content"
    [[ -n $(tr -d '[:space:]' <"$content") ]] || die "nothing on stdin to save; use forget to remove a topic"
    blob=$(git hash-object -w "$content")
    base=$(tip)
    current=$(blob_at "$base" "$DIR/$topic.md")
    expect_read "$DIR/$topic.md" "$current"
    CHANGES=("$DIR/$topic.md"$'\t'"$blob"$'\t'"$current")
    commit_changes "$(message)" "$base"
    ;;

  forget)
    parse_write_flags "$@"
    ((${#ARGS[@]} == 1)) || die "usage: forget <topic> -m <message> [--by <who>] --after <version>"
    topic=${ARGS[0]}
    check_topic "$topic"
    base=$(tip)
    current=$(blob_at "$base" "$DIR/$topic.md")
    [[ $current != - ]] || die "nothing remembered about $topic"
    expect_read "$DIR/$topic.md" "$current"
    CHANGES=("$DIR/$topic.md"$'\t'-$'\t'"$current")
    commit_changes "$(message)" "$base"
    ;;

  undo)
    parse_write_flags "$@"
    ((${#ARGS[@]} == 1)) || die "usage: undo <commit> -m <message> [--by <who>]"
    base=$(tip)
    target=$(git rev-parse -q --verify "${ARGS[0]}^{commit}" 2>/dev/null) || die "no change ${ARGS[0]}"
    git merge-base --is-ancestor "$target" "$base" || die "${ARGS[0]} is not in memory's history"
    git rev-parse -q --verify "$target^" >/dev/null || die "${ARGS[0]} has nothing before it to go back to"
    CHANGES=()
    while IFS= read -r path; do
      [[ $path == "$DIR"/* ]] || die "${ARGS[0]} changed $path, which is not memory"
      CHANGES+=("$path"$'\t'"$(blob_at "$target^" "$path")"$'\t'"$(blob_at "$target" "$path")")
    done < <(git diff-tree --no-commit-id --name-only -r "$target")
    ((${#CHANGES[@]})) || die "${ARGS[0]} changed nothing"
    commit_changes "$(message)" "$base"
    ;;

  *)
    usage >&2
    exit 1
    ;;
esac
