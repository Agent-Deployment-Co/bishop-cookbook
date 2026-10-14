# Bishop Cookbook

Plugins for agents running under [Bishop](https://bishop.agentdeployment.co). The repository is one plugin marketplace, `bishop-cookbook`, that Claude and Codex both install from. Each directory in `plugins/` is one plugin.

| Plugin | What it does |
|---|---|
| [`bishop-memory`](plugins/bishop-memory/skills/bishop-memory/SKILL.md) | Remembers what people teach the agent across every conversation, kept as Markdown notes on a `memory` branch apart from the agent's own files. |

## Adding a plugin to an agent

Declare the plugin in the agent's repository, pinned to a commit of this one, and commit the change. Bishop installs it on the first turn of each new thread. [Harness configuration](https://bishop.agentdeployment.co/running/harness) covers how Bishop applies the agent's settings and plugins.

For Claude, in `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "bishop-cookbook": {
      "source": {
        "source": "settings",
        "name": "bishop-cookbook",
        "plugins": [
          {
            "name": "bishop-memory",
            "source": {
              "source": "git-subdir",
              "url": "https://github.com/Agent-Deployment-Co/bishop-cookbook.git",
              "path": "plugins/bishop-memory",
              "sha": "<commit>"
            }
          }
        ]
      }
    }
  },
  "enabledPlugins": { "bishop-memory@bishop-cookbook": true }
}
```

For Codex, in `.codex/config.toml`:

```toml
[marketplaces.bishop-cookbook]
source_type = "git"
source = "https://github.com/Agent-Deployment-Co/bishop-cookbook.git"
ref = "<commit>"

[plugins."bishop-memory@bishop-cookbook"]
enabled = true
```

An agent that runs under both harnesses declares it in both files. To update a plugin, change the commit. To remove one, delete its entries.

Agents that copied a skill from an earlier version of this repository have it in `.agents/skills/<skill>` and `.claude/skills/<skill>`. Delete both when adding the plugin, or the agent loads the skill twice.

## Testing

Tests go in `test/`, outside the plugins so they never reach an agent. The setup is Bishop's: vitest for tests, Biome for linting and formatting, and `tsc` for typechecking, all run by `npm run check`, which CI runs on every pull request. Node 24 or later.

```sh
npm install
npm run check
```

`test/manifests.test.ts` fails when the Claude and Codex manifests disagree about a plugin. A plugin's scripts get tests in `test/<plugin>/`. A test runs a script the way an agent does, with `runScript` in `test/support/script.ts`, and asserts on its exit status, output, and what it left on disk. `test/support/git.ts` makes real repositories in temp directories, with a bare repository on a local path standing in for the remote, so nothing reaches the network. Both run git with the developer's own git config shut out.

## bishop-memory

The agent keeps one Markdown note per topic in a checkout of a `memory` branch, which shares no history with the agent's own files. Every conversation on the host reads and writes that one checkout, so a note saved in one thread is there for the next without a fetch. Each save is a commit saying what was learned and who taught it, pushed to the remote, so the history is a log of what the agent was taught and any change can be undone. Because memory lives on its own branch, saving never moves the branch Bishop runs the agent from, and the agent's own branch can stay protected.

`memory.sh` makes every change, holding a `flock` lock so concurrent saves on one host take turns. It pulls before each save and refuses one made against a version of the topic that has since changed. A save that can't be pushed stays on the host and goes out with the next one. If something else changed the same topic before it went out, the remote's version wins: the save is kept on a `refs/memory/set-aside/*` ref in the checkout and handed back to the agent to merge.

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
