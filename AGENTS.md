# Bishop Cookbook

`CLAUDE.md` is a symlink to this file, so Claude and Codex both read it.

Plugins for agents running under [Bishop](https://github.com/Agent-Deployment-Co/bishop). The repository is one marketplace that Claude and Codex both install from. Each directory in `plugins/` is one plugin, and the harness copies it whole into its cache, so everything in it ships to the agent and nothing else does.

## Layout

```
.claude-plugin/marketplace.json     Claude's marketplace
.agents/plugins/marketplace.json    Codex's marketplace
plugins/<plugin>/
  .claude-plugin/plugin.json        Claude's manifest
  .codex-plugin/plugin.json         Codex's manifest, identical to Claude's
  skills/<skill>/SKILL.md           loaded by both
```

- **Both marketplaces list every plugin**, under the same marketplace name, since an agent enables a plugin as `<plugin>@bishop-cookbook` in either harness.
- **Both manifests are the same file.** Keep them to fields both harnesses accept: `name`, `version`, `description`, `author`, and `repository`. Both find `skills/` without a `skills` field.
- **Bump `version` in both manifests whenever a plugin changes.** Codex keeps one cached copy per plugin and replaces it only when the version changes, so an agent pinned to a new commit keeps the old copy otherwise.
- `test/manifests.test.ts` fails when any of this drifts.

## Writing a skill

- **Both harnesses load it.** Keep `SKILL.md` frontmatter to `name`, `description`, and `metadata`, so the skill behaves the same under Claude and Codex.
- **A script runs with `bash`, by its full path**, so it works without its executable bit and from any working directory.
- **A script makes any write outside the agent's working directory.** Under Bishop's worktree mode, Claude's `Edit` and `Write` are refused until the thread enters its worktree, whatever file they target, while Bash is not.
- **Expect concurrency.** Several conversations run the same skill at once, possibly on several hosts, and an agent with a shell may ignore the instructions. Shared state needs a lock or a version check, and a failure must leave state that the next run can recover from.
- **Assume the sandbox.** Under `agent.sandbox`, the agent can write its working directory, its git directories, and the temp directory. Anything else is a grant the operator has to add, and the README has to say so.
- **People never hear about the mechanism.** A skill tells the agent not to mention the skill, git, or scripts when it talks to people.

## Testing

`npm run check` runs Biome, `tsc`, and vitest, and CI runs it on every pull request. Node 24 or later.

Tests for a plugin's scripts go in `test/<plugin>/`, never inside the plugin. `runScript` in `test/support/script.ts` runs a script the way an agent does. `test/support/git.ts` builds real repositories with a local bare remote, so tests never reach the network. Both shut out the developer's git config. A test that proves a fix should fail with the fix removed: check that before trusting it.

## Docs

The README lists every plugin and says what each needs from the agent's repository and host. A change an operator would notice updates it.

Write plainly and briefly, in active voice, leading with what something does before how. No em-dashes, no filler, and no hard-wrapped markdown: one paragraph is one line.
