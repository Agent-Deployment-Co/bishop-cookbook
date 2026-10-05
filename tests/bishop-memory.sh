#!/usr/bin/env bash
# Exercises bishop-memory/scripts/memory.sh against a scratch bare remote.
# Run from anywhere: bash tests/bishop-memory.sh
set -euo pipefail

MEM=$(cd "$(dirname "$0")/.." && pwd)/bishop-memory/scripts/memory.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=$T/gitconfig GIT_CONFIG_NOSYSTEM=1
git config --global user.name Test
git config --global user.email test@example.com
git config --global init.defaultBranch main

pass=0
ok() { pass=$((pass + 1)); echo "ok - $1"; }
fail() { echo "FAIL - $1" >&2; exit 1; }
expect() { # expect <description> <needle> <haystack>
  [[ $3 == *"$2"* ]] || fail "$1: expected '$2' in: $3"
  ok "$1"
}

git init -q --bare "$T/remote.git"
git clone -q "$T/remote.git" "$T/seed"
(cd "$T/seed" && echo agent >README.md && git add . && git commit -qm init && git push -q origin main)
git clone -q "$T/remote.git" "$T/a"
git clone -q "$T/remote.git" "$T/b"

cd "$T/a"
expect "empty memory" "Nothing remembered yet." "$("$MEM" list)"
out=$(printf '# Billing\n\n- Invoices go to finance@.\n' | "$MEM" save billing -m "Invoices go to finance@" --by "Dana Lee")
expect "save reports a commit" "Saved as" "$out"
[[ -z $(git status --porcelain) ]] || fail "save left the checkout dirty"
ok "save leaves the checkout untouched"

cd "$T/b"
expect "another clone sees it" "billing: Billing" "$("$MEM" list)"
expect "read" "Invoices go to finance@." "$("$MEM" read billing)"
expect "search is case-insensitive" "billing.md:3:- Invoices go to finance@." "$("$MEM" search INVOICES)"
expect "search with no match" "Nothing remembered mentions that." "$("$MEM" search nowhere)"
expect "history names the teacher" "Invoices go to finance@ (taught by Dana Lee)" "$("$MEM" history billing)"
expect "unchanged save is a no-op" "Nothing changed" "$(printf '# Billing\n\n- Invoices go to finance@.\n' | "$MEM" save billing -m same)"

# A detached checkout, the way a Bishop snapshot is.
git clone -q "$T/remote.git" "$T/snap"
cd "$T/snap" && git checkout -q --detach
printf '# Shipping\n\n- Ship with Acme.\n' | "$MEM" save shipping -m "Ship with Acme" >/dev/null
expect "saves from a detached checkout" "shipping: Shipping" "$("$MEM" list)"

# Another writer pushes between our fetch and our push: retried, both kept.
cd "$T/a"
cat >.git/hooks/pre-push <<EOF
#!/usr/bin/env bash
rm -f "\$0"
cd "$T/b" && printf '# Holidays\n\n- Closed Dec 25.\n' | "$MEM" save holidays -m "Closed Dec 25" >/dev/null
EOF
chmod +x .git/hooks/pre-push
printf '# Support\n\n- Pager rotates Mondays.\n' | "$MEM" save support -m "Pager rotates Mondays" >/dev/null
list=$("$MEM" list)
expect "race keeps the other writer" "holidays: Holidays" "$list"
expect "race keeps ours" "support: Support" "$list"

# Undo puts back what a change replaced.
printf '# Billing\n\n- Invoices go to accounts@.\n' | "$MEM" save billing -m "Invoices go to accounts@" >/dev/null
change=$("$MEM" history billing -n 1 | cut -d' ' -f1)
"$MEM" undo "$change" -m "Put back finance@" >/dev/null
expect "undo restores" "finance@" "$("$MEM" read billing)"

# Undoing something that has since changed again is a conflict, not an overwrite.
printf '# Billing\n\n- Invoices go to billing@.\n' | "$MEM" save billing -m "Invoices go to billing@" >/dev/null
set +e
"$MEM" undo "$change" -m "stale" 2>/dev/null
status=$?
set -e
[[ $status == 3 ]] || fail "stale undo exited $status, not 3"
ok "stale undo is a conflict"
expect "conflict left memory alone" "billing@" "$("$MEM" read billing)"

"$MEM" forget shipping -m "No longer ship with Acme" >/dev/null
[[ $("$MEM" list) != *shipping* ]] || fail "forget left the topic"
ok "forget"

# Bad input is refused before anything is written.
for args in "save Bad-Topic -m x" "save ../escape -m x" "save ok" "forget missing -m x"; do
  set +e
  # shellcheck disable=SC2086
  echo x | "$MEM" $args >/dev/null 2>&1
  status=$?
  set -e
  [[ $status != 0 ]] || fail "accepted: $args"
done
ok "refuses bad topics, a missing message, and forgetting nothing"
set +e
"$MEM" undo "$(git -C "$T/seed" rev-parse HEAD)" -m x >/dev/null 2>&1
status=$?
set -e
[[ $status != 0 ]] || fail "undo of a commit outside memory was accepted"
ok "refuses to undo a change outside memory"

# No identity configured anywhere still saves.
git config --global --unset user.email
printf '# Office\n\n- Badge at the front desk.\n' | "$MEM" save office -m "Badge at the front desk" >/dev/null
expect "saves without a configured identity" "bishop-memory" "$(git -C "$T/remote.git" log -1 --format=%an main)"

# Pushes landed on the default branch, with nothing left in the checkouts.
[[ $(git -C "$T/remote.git" branch --format='%(refname:short)') == main ]] || fail "extra branches on the remote"
ok "only the default branch on the remote"

echo "$pass passed"
