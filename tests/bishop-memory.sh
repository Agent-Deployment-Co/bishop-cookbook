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
expect "read" "Invoices go to finance@." "$("$MEM" read billing 2>/dev/null)"
expect "search is case-insensitive" "billing.md:3:- Invoices go to finance@." "$("$MEM" search INVOICES)"
expect "search with no match" "Nothing remembered mentions that." "$("$MEM" search nowhere)"
expect "history names the teacher" "Invoices go to finance@ (taught by Dana Lee)" "$("$MEM" history billing)"

# Writing over a topic takes the version that was read.
ver() { "$MEM" read "$1" 2>&1 >/dev/null | awk '{ print $NF }'; }
expect "read reports a version" "bishop-memory: version " "$("$MEM" read billing 2>&1 >/dev/null)"
set +e
printf '# Billing\n\n- x\n' | "$MEM" save billing -m blind 2>/dev/null
status=$?
set -e
[[ $status == 3 ]] || fail "save over an unread topic exited $status, not 3"
ok "save over an unread topic is a conflict"
expect "unchanged save is a no-op" "Nothing changed" "$(printf '# Billing\n\n- Invoices go to finance@.\n' | "$MEM" save billing -m same --after "$(ver billing)")"

# Thread A reads, thread B saves the same topic, then A saves its merge of
# what it read: A must not overwrite B.
stale=$(ver billing)
cd "$T/a"
printf '# Billing\n\n- Invoices go to finance@.\n- Net-30 terms.\n' | "$MEM" save billing -m "Net-30 terms" --after "$(ver billing)" >/dev/null
cd "$T/b"
set +e
printf '# Billing\n\n- Invoices go to finance@.\n- Pay by wire.\n' | "$MEM" save billing -m "Pay by wire" --after "$stale" 2>/dev/null
status=$?
set -e
[[ $status == 3 ]] || fail "stale save exited $status, not 3"
ok "save after someone else's save of the same topic is a conflict"
expect "the other thread's save survived" "Net-30 terms." "$("$MEM" read billing 2>/dev/null)"

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
printf '# Billing\n\n- Invoices go to accounts@.\n' | "$MEM" save billing -m "Invoices go to accounts@" --after "$(ver billing)" >/dev/null
change=$("$MEM" history billing -n 1 | cut -d' ' -f1)
"$MEM" undo "$change" -m "Put back finance@" >/dev/null
expect "undo restores" "finance@" "$("$MEM" read billing 2>/dev/null)"

# Undoing something that has since changed again is a conflict, not an overwrite.
printf '# Billing\n\n- Invoices go to billing@.\n' | "$MEM" save billing -m "Invoices go to billing@" --after "$(ver billing)" >/dev/null
set +e
"$MEM" undo "$change" -m "stale" 2>/dev/null
status=$?
set -e
[[ $status == 3 ]] || fail "stale undo exited $status, not 3"
ok "stale undo is a conflict"
expect "conflict left memory alone" "billing@" "$("$MEM" read billing 2>/dev/null)"

"$MEM" forget shipping -m "No longer ship with Acme" --after "$(ver shipping)" >/dev/null
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

# Skills: written under .agents/skills with a .claude/skills link, so a fresh
# clone loads them under either harness.
expect "no skills yet" "No skills learned yet." "$("$MEM" skills)"
S=$T/skill-draft
mkdir -p "$S/scripts"
printf -- '---\nname: weekly-report\ndescription: Write the weekly report. Use when asked for the weekly report.\nmetadata:\n  author: Dana Lee\n---\n\nRun scripts/totals.sh, then summarize.\n' >"$S/SKILL.md"
printf '#!/bin/sh\necho 42\n' >"$S/scripts/totals.sh"
chmod +x "$S/scripts/totals.sh"
"$MEM" skill-save weekly-report "$S" -m "How to write the weekly report" --by "Dana Lee" >/dev/null
expect "skills lists it" "weekly-report: Write the weekly report." "$("$MEM" skills)"
git clone -q "$T/remote.git" "$T/fresh"
[[ -f $T/fresh/.agents/skills/weekly-report/SKILL.md ]] || fail "skill missing under .agents/skills"
[[ -L $T/fresh/.claude/skills/weekly-report && -f $T/fresh/.claude/skills/weekly-report/SKILL.md ]] || fail ".claude/skills link missing or broken"
[[ -x $T/fresh/.agents/skills/weekly-report/scripts/totals.sh ]] || fail "script lost its executable bit"
ok "skill lands where both harnesses load it, scripts still executable"
expect "history includes skills" "How to write the weekly report (taught by Dana Lee)" "$("$MEM" history)"

# Editing goes through skill-get and --after, like a topic.
E=$T/skill-edit
skill_ver=$("$MEM" skill-get weekly-report "$E" 2>&1 >/dev/null | awk '{ print $NF }')
[[ -x $E/scripts/totals.sh ]] || fail "skill-get lost the executable bit"
rm "$E/scripts/totals.sh"
printf -- '---\nname: weekly-report\ndescription: Write the weekly report. Use when asked for the weekly report.\n---\n\nSummarize the week.\n' >"$E/SKILL.md"
"$MEM" skill-save weekly-report "$E" -m "Drop the totals script" --after "$skill_ver" >/dev/null
git -C "$T/fresh" pull -q
[[ ! -e $T/fresh/.agents/skills/weekly-report/scripts/totals.sh ]] || fail "a file removed from the draft survived the save"
ok "skill-save replaces the whole skill"
set +e
"$MEM" skill-save weekly-report "$S" -m stale --after "$skill_ver" 2>/dev/null
status=$?
set -e
[[ $status == 3 ]] || fail "stale skill-save exited $status, not 3"
ok "stale skill-save is a conflict"

# Refused: harness-specific frontmatter, a mismatched name, and this skill itself.
B=$T/skill-bad
mkdir -p "$B"
printf -- '---\nname: sneaky\ndescription: x\nallowed-tools: Bash(*)\n---\nx\n' >"$B/SKILL.md"
set +e
"$MEM" skill-save sneaky "$B" -m x >/dev/null 2>&1; s1=$?
"$MEM" skill-save other-name "$B" -m x >/dev/null 2>&1; s2=$?
printf -- '---\nname: bishop-memory\ndescription: x\n---\nx\n' >"$B/SKILL.md"
"$MEM" skill-save bishop-memory "$B" -m x >/dev/null 2>&1; s3=$?
set -e
[[ $s1 != 0 && $s2 != 0 && $s3 != 0 ]] || fail "accepted a bad skill ($s1 $s2 $s3)"
ok "refuses harness-specific frontmatter, a mismatched name, and rewriting bishop-memory"
for key in '"allowed-tools": Bash(*)' 'hooks :' "'hooks': x" '{hooks: x}'; do
  printf -- '---\nname: sneaky\ndescription: x\n%s\n---\nx\n' "$key" >"$B/SKILL.md"
  set +e
  "$MEM" skill-save sneaky "$B" -m x >/dev/null 2>&1
  status=$?
  set -e
  [[ $status != 0 ]] || fail "accepted frontmatter line: $key"
done
ok "refuses quoted, spaced, and flow-style keys"

# A Claude skill written by hand under .claude/skills isn't memory to undo.
(cd "$T/seed" && git pull -q && mkdir -p .claude/skills/deploy && printf -- '---\nname: deploy\ndescription: x\n---\nx\n' >.claude/skills/deploy/SKILL.md && git add . && git commit -qm "Add deploy" && git push -q)
set +e
"$MEM" undo "$(git -C "$T/seed" rev-parse HEAD)" -m x >/dev/null 2>&1
status=$?
set -e
[[ $status != 0 ]] || fail "undo removed a hand-written Claude skill"
ok "refuses to undo a hand-written Claude skill"
(cd "$T/seed" && mkdir -p elsewhere/ops && ln -s ../../elsewhere/ops .claude/skills/ops && git add . && git commit -qm "Add ops" && git push -q)
set +e
"$MEM" undo "$(git -C "$T/seed" rev-parse HEAD)" -m x >/dev/null 2>&1
status=$?
set -e
[[ $status != 0 ]] || fail "undo removed a hand-made Claude skill link"
ok "refuses to undo a Claude skill link skill-save didn't write"

# Undo of the edit brings the script back with its mode.
change=$("$MEM" history weekly-report -n 1 | cut -d' ' -f1)
"$MEM" undo "$change" -m "Put the totals script back" >/dev/null
git -C "$T/fresh" pull -q
[[ -x $T/fresh/.agents/skills/weekly-report/scripts/totals.sh ]] || fail "undo did not restore the executable script"
ok "undo restores a skill file with its mode"

skill_ver=$("$MEM" skill-get weekly-report "$T/skill-view" 2>&1 >/dev/null | awk '{ print $NF }')
"$MEM" skill-forget weekly-report -m "No more weekly report" --after "$skill_ver" >/dev/null
git -C "$T/fresh" pull -q
[[ ! -e $T/fresh/.agents/skills/weekly-report && ! -L $T/fresh/.claude/skills/weekly-report ]] || fail "skill-forget left files or the link"
ok "skill-forget removes the skill and its link"

# A repository whose whole .claude/skills is a link to .agents/skills.
git init -q --bare "$T/shared.git"
git clone -q "$T/shared.git" "$T/shared" 2>/dev/null
(cd "$T/shared" && mkdir -p .agents/skills .claude && touch .agents/skills/.keep && ln -s ../.agents/skills .claude/skills && git add . && git commit -qm init && git push -q origin main)
(cd "$T/shared" && "$MEM" skill-save weekly-report "$S" -m "Weekly report" >/dev/null && git pull -q)
[[ -f $T/shared/.claude/skills/weekly-report/SKILL.md ]] || fail "skill not visible through a shared .claude/skills link"
ok "saves into a repository whose .claude/skills links to .agents/skills"
(cd "$T/shared" && rm .claude/skills && ln -s ../elsewhere .claude/skills && git commit -qam "Point elsewhere" && git push -q)
set +e
(cd "$T/shared" && "$MEM" skill-save other-report "$S" -m x >/dev/null 2>&1)
status=$?
set -e
[[ $status != 0 ]] || fail "saved through a .claude/skills link that points elsewhere"
ok "refuses a .claude/skills link that points elsewhere"

# No identity configured anywhere still saves.
git config --global --unset user.email
printf '# Office\n\n- Badge at the front desk.\n' | "$MEM" save office -m "Badge at the front desk" >/dev/null
expect "saves without a configured identity" "bishop-memory" "$(git -C "$T/remote.git" log -1 --format=%an main)"

# Pushes landed on the default branch, with nothing left in the checkouts.
[[ $(git -C "$T/remote.git" branch --format='%(refname:short)') == main ]] || fail "extra branches on the remote"
ok "only the default branch on the remote"

echo "$pass passed"
