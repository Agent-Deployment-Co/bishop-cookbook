# Bishop Cookbook

Skills for agents running under [Bishop](https://bishop.agentdeployment.co). Each top-level directory is one skill, copied into an agent's repository as it is.

| Skill | What it does |
|---|---|
| [`bishop-memory`](bishop-memory/SKILL.md) | Remembers what people teach the agent across every conversation, kept as Markdown notes on the repository's default branch. |

## Adding a skill to an agent

Run this from the root of the agent's repository, with `SKILL` set to the skill's directory name.

```sh
SKILL=bishop-memory
src=$(mktemp -d)
git clone --quiet --depth 1 https://github.com/Agent-Deployment-Co/bishop-cookbook.git "$src"
rm -rf ".agents/skills/$SKILL"
mkdir -p .agents/skills .claude/skills
cp -R "$src/$SKILL" ".agents/skills/$SKILL"
ln -sfn "../../.agents/skills/$SKILL" ".claude/skills/$SKILL"
rm -rf "$src"
git add ".agents/skills/$SKILL" ".claude/skills/$SKILL"
git commit -m "Add the $SKILL skill from bishop-cookbook"
git push
```

The skill lives once, in `.agents/skills`, where Codex loads skills. The symlink in `.claude/skills` lets Claude load the same copy, so either harness works and the two never drift.

The agent picks the skill up once Bishop runs the commit holding it. With a git URL agent and `--auto-update`, that is the next new thread. Otherwise, update the agent's checkout and restart Bishop.

To update a skill, run the same steps again. The `rm -rf` first means a file the cookbook deleted is deleted from the agent too. To remove one, delete both paths and commit.

## bishop-memory

The agent keeps one Markdown note per topic under `memory/` on its repository's default branch, and works in a scratch clone of that branch so every conversation reads and writes the same notes. Every save is a commit saying what was learned and who taught it, so the history is a log of what the agent was taught and any change can be undone.

The agent needs:

- A remote named `origin`.
- Permission to push to the default branch. Branch protection on it refuses the saves.
- A credential git will use. `bishop github setup` provides one, and `gh auth setup-git` makes git use it.
- A git identity, which a Bishop snapshot doesn't have. Set one for the user Bishop runs as.

Untested so far: running end to end under either harness, and under `agent.sandbox`, where the agent needs network access to the remote and somewhere writable for its scratch clone.
