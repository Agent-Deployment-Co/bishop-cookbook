# Bishop Cookbook

Skills for agents running under [Bishop](https://bishop.agentdeployment.co). Each top-level directory is one skill, copied into an agent's repository as it is.

| Skill | What it does |
|---|---|
| [`bishop-memory`](bishop-memory/SKILL.md) | Remembers what people teach the agent across every conversation, kept as Markdown notes on a `memory` branch apart from the agent's own files. |

## Adding a skill to an agent

Ask the agent to install a skill from this repository by name, or do it yourself from the root of the agent's repository:

1. Copy the skill's directory to `.agents/skills/<skill>`, replacing any copy already there.
2. Symlink `.claude/skills/<skill>` to `../../.agents/skills/<skill>`.
3. Commit both paths and push.

The skill lives once, in `.agents/skills`, where Codex loads skills. The symlink in `.claude/skills` lets Claude load the same copy, so either harness works and the two never drift.

The agent picks the skill up once Bishop runs the commit holding it. With a git URL agent and `--auto-update`, that is the next new thread. Otherwise, update the agent's checkout and restart Bishop.

To update a skill, follow the same steps. Replacing the directory rather than copying over it means a file the cookbook deleted is deleted from the agent too. To remove a skill, delete both paths and commit.

## bishop-memory

The agent keeps one Markdown note per topic in a checkout of a `memory` branch, which shares no history with the agent's own files. Every conversation on the host reads and writes that one checkout, so a note saved in one thread is there for the next without a fetch. Each save is a commit saying what was learned and who taught it, pushed to the remote, so the history is a log of what the agent was taught and any change can be undone. Because memory lives on its own branch, saving never moves the branch Bishop runs the agent from, and the agent's own branch can stay protected.

`memory.sh` makes every change, holding a `flock` lock so concurrent saves on one host take turns. It pulls before each save and refuses one made against a version of the topic that has since changed. A save that can't be pushed stays on the host and goes out with the next one.

### Setting it up

Once per agent, create the branch from any clone of the agent's repository:

```sh
git switch --orphan memory
git commit --allow-empty -m "Start memory"
git push origin memory
```

Then on each host that runs the agent:

1. Clone the branch somewhere outside both the agent's directory and Bishop's home, like `git clone --branch memory --single-branch <agent repository URL> /srv/agent-memory`.
2. Give that checkout a git identity with `git config user.name` and `user.email`, and make sure pushing from it works as the user Bishop runs as. `bishop github setup` provides a credential, and `gh auth setup-git` makes git use it.
3. Add `AGENT_MEMORY=/srv/agent-memory` to Bishop's `.env` and restart Bishop.
4. Under `agent.sandbox`, grant the checkout read and write in the nono profile Bishop uses. Bishop's own grants don't reach it.

The host needs `flock`, which util-linux provides on Linux. On macOS, install it with Homebrew.

With more than one host, each pulls the others' notes only when it saves, so a host that hasn't saved lately reads older notes.

### Moving from notes on the default branch

Earlier versions kept notes under `memory/` on the default branch. Copy those files into the new checkout, commit and push them there, then delete `memory/` from the default branch.
