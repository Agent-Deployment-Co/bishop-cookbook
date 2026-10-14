/**
 * Claude and Codex each read their own manifests, so nothing but this test
 * keeps the two from describing different plugins.
 */

import { existsSync } from 'node:fs'
import { readdir, readFile } from 'node:fs/promises'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { ROOT } from './support/script.js'

interface Plugin {
  name: string
  version: string
  description: string
}

interface ClaudeMarketplace {
  name: string
  plugins: { name: string; source: string; description?: string }[]
}

interface CodexMarketplace {
  name: string
  plugins: { name: string; source: { source: string; path: string } }[]
}

/** What AGENTS.md allows, so a skill behaves the same under Claude and Codex. */
const SKILL_KEYS = ['name', 'description', 'metadata']

async function json<T>(...path: string[]): Promise<T> {
  return JSON.parse(await readFile(join(ROOT, ...path), 'utf8')) as T
}

async function dirs(...path: string[]): Promise<string[]> {
  const entries = await readdir(join(ROOT, ...path), { withFileTypes: true })
  return entries.filter((entry) => entry.isDirectory()).map((entry) => entry.name)
}

/** The top-level keys of a SKILL.md's frontmatter, with their one-line values. */
function frontmatter(text: string): Map<string, string> {
  const match = /^---\n([\s\S]*?)\n---\n/.exec(text)
  if (!match) throw new Error('no frontmatter')
  const keys = new Map<string, string>()
  for (const line of match[1]!.split('\n')) {
    const key = /^([A-Za-z_-]+):\s*(.*)$/.exec(line)
    if (key) keys.set(key[1]!, key[2]!)
  }
  return keys
}

const plugins = await dirs('plugins')
const claude = await json<ClaudeMarketplace>('.claude-plugin', 'marketplace.json')
const codex = await json<CodexMarketplace>('.agents', 'plugins', 'marketplace.json')

describe('marketplaces', () => {
  it('share a name, since an agent enables a plugin as <plugin>@<marketplace>', () => {
    expect(codex.name).toBe(claude.name)
  })

  it('each list every plugin, at its own directory', () => {
    const local = plugins.map((name) => ({ name, path: `./plugins/${name}` }))
    expect(claude.plugins.map((p) => ({ name: p.name, path: p.source }))).toEqual(local)
    expect(codex.plugins.map((p) => ({ name: p.name, path: p.source.path }))).toEqual(local)
    expect(codex.plugins.every((p) => p.source.source === 'local')).toBe(true)
  })
})

describe.each(plugins)('plugin %s', (name) => {
  it('describes itself the same way to both harnesses', async () => {
    const forClaude = await json<Plugin>('plugins', name, '.claude-plugin', 'plugin.json')
    const forCodex = await json<Plugin>('plugins', name, '.codex-plugin', 'plugin.json')
    expect(forClaude.name).toBe(name)
    expect(forCodex).toEqual(forClaude)
    expect(claude.plugins.find((p) => p.name === name)?.description).toBe(forClaude.description)
  })

  it('has skills both harnesses load the same way', async () => {
    const skills = await dirs('plugins', name, 'skills')
    expect(skills.length).toBeGreaterThan(0)
    for (const skill of skills) {
      const file = join(ROOT, 'plugins', name, 'skills', skill, 'SKILL.md')
      expect(existsSync(file), file).toBe(true)
      const keys = frontmatter(await readFile(file, 'utf8'))
      expect(keys.get('name')).toBe(skill)
      expect([...keys.keys()].filter((key) => !SKILL_KEYS.includes(key))).toEqual([])
    }
  })
})
