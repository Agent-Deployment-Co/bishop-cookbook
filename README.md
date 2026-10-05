# Bishop Cookbook

Skills and recipes for agents running under [Bishop](https://bishop.agentdeployment.co). Each top-level directory is one, copied into an agent's repository as it is.

## bishop-memory

Lets an agent remember what people teach it across every conversation, without anyone handling git. People say "remember that invoices go to finance@" or "what do you know about billing", and the agent keeps one Markdown note per topic under `memory/` on its repository's default branch. Every save is a commit that says what was learned and who taught it, so the history is a log of what the agent was taught and any change can be undone.

People can also teach it how to do a task. The agent saves that as a skill under `.agents/skills/<name>/`, with a `.claude/skills/<name>` link so either harness loads it. A taught skill's frontmatter is limited to the Agent Skills fields, so a message can't hand itself Claude's `hooks` or `allowed-tools`, and `bishop-memory` itself can't be rewritten from chat.

The agent writes straight to the remote's default branch without touching its checkout. A note survives the thread branch Bishop deletes later, and two threads saving at once both keep what they saved. Notes are read from the remote, so every thread sees a new one at once. A skill is loaded from the files a thread starts on, so it reaches new threads only once Bishop runs that commit: with a git URL and `--auto-update`, the next new thread; otherwise after the agent's checkout is updated and Bishop restarted.

### Adding it to an agent

Copy `bishop-memory/` to `.agents/skills/bishop-memory/` in the agent's repository, where Codex finds it, and commit a symlink so Claude finds it too:

```sh
mkdir -p .claude/skills
ln -s ../../.agents/skills/bishop-memory .claude/skills/bishop-memory
```

The agent needs:

- A remote named `origin`. Set `BISHOP_MEMORY_REMOTE` to use another.
- Permission to push to the default branch, which branch protection on it will refuse. Set `BISHOP_MEMORY_BRANCH` to keep memory on another branch, though a new thread only starts from the default one.
- A credential git will use. `bishop github setup` provides one, and `gh auth setup-git` makes git use it.

Untested so far: running under `agent.sandbox`, where the agent needs network access to the remote and write access to the repository's object store.

### Testing

```sh
bash tests/bishop-memory.sh
```

Runs the script against a scratch remote: two clones acting as two threads, a detached checkout like a Bishop snapshot, a push race, undo, and a conflicting undo.
