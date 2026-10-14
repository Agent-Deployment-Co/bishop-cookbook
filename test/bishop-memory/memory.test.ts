import { existsSync } from 'node:fs'
import { chmod, readdir, readFile, writeFile } from 'node:fs/promises'
import { basename, dirname, join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { bareRemote, clone, git, tempDir } from '../support/git.js'
import { type Result, runScript, skillScript } from '../support/script.js'

const BRANCH = 'memory'

/** One host's memory checkout, driven through memory.sh as the agent drives it. */
interface Host {
  dir: string
  memory(args: string[], input?: string): Promise<Result>
  version(topic: string): Promise<string>
  /** Saves at whatever version the topic is now, as an agent that just read it would. */
  save(topic: string, content: string, subject?: string, by?: string): Promise<Result>
  read(topic: string): Promise<string>
}

function host(dir: string): Host {
  const memory = (args: string[], input?: string) =>
    runScript('bishop-memory', 'memory', 'memory.sh', args, {
      env: { AGENT_MEMORY_HOME: dir },
      ...(input === undefined ? {} : { input }),
    })
  const version = async (topic: string) => (await memory(['version', topic])).stdout.trim()
  return {
    dir,
    memory,
    version,
    save: async (topic, content, subject = `Learned ${topic}`, by = 'Dana Lee') =>
      memory(['save', topic, await version(topic), subject, by], content),
    read: (topic) => readFile(join(dir, `${topic}.md`), 'utf8'),
  }
}

/** A remote memory branch and a checkout of it per host. */
async function setup(hosts = 1): Promise<{ remote: string; hosts: Host[] }> {
  const remote = await bareRemote(BRANCH)
  const dirs = await Promise.all(Array.from({ length: hosts }, () => clone(remote, BRANCH)))
  return { remote, hosts: dirs.map(host) }
}

const topic = (heading: string, ...facts: string[]) =>
  `# ${heading}\n\n${facts.map((fact) => `- ${fact}`).join('\n')}\n`

const onRemote = (remote: string, topic: string) =>
  git(remote, 'show', `${BRANCH}:${topic}.md`).then((text) => `${text}\n`)

/** Points a checkout's remote somewhere that doesn't exist, as a network outage would. */
const unreachable = async (h: Host) =>
  git(h.dir, 'remote', 'set-url', 'origin', join(await tempDir(), 'gone.git'))

describe('version', () => {
  it('is "new" for a topic that does not exist', async () => {
    const { hosts } = await setup()
    expect(await hosts[0]!.version('billing')).toBe('new')
  })

  it('is the blob hash of the topic as it is on disk', async () => {
    const { hosts } = await setup()
    const [a] = hosts as [Host]
    await a.save('billing', topic('Billing', 'Invoices go to finance@'))
    expect(await a.version('billing')).toBe(await git(a.dir, 'hash-object', 'billing.md'))
  })
})

describe('save', () => {
  it('writes the topic, commits it with who taught it, and pushes', async () => {
    const { remote, hosts } = await setup()
    const [a] = hosts as [Host]
    const text = topic('Billing', 'Invoices go to finance@')

    const result = await a.save('billing', text, 'Invoices go to finance@', 'Dana Lee')

    expect(result.code).toBe(0)
    expect(await a.read('billing')).toBe(text)
    expect(
      await git(remote, 'log', '-1', '--format=%s|%(trailers:key=Taught-by,valueonly)', BRANCH),
    ).toBe('Invoices go to finance@|Dana Lee')
    expect(await onRemote(remote, 'billing')).toBe(text)
  })

  it('refuses a version that is no longer current, leaving the topic alone', async () => {
    const { hosts } = await setup()
    const [a] = hosts as [Host]
    const text = topic('Billing', 'Invoices go to finance@')
    await a.save('billing', text)

    const result = await a.memory(['save', 'billing', 'new', 'Stale', 'Sam'], topic('Billing', 'x'))

    expect(result.code).toBe(3)
    expect(result.stderr).toContain('changed since you read it')
    expect(await a.read('billing')).toBe(text)
  })

  it('refuses a version read before another host changed the topic', async () => {
    const { hosts } = await setup(2)
    const [a, b] = hosts as [Host, Host]
    await a.save('billing', topic('Billing', 'finance@'))
    await git(b.dir, 'pull', '--quiet')
    const read = await a.version('billing')
    await b.save('billing', topic('Billing', 'ap@'))

    const result = await a.memory(['save', 'billing', read, 'Late', 'Dana'], topic('Billing', 'x'))

    expect(result.code).toBe(3)
    expect(await a.read('billing')).toBe(topic('Billing', 'ap@'))
  })

  it("brings in other hosts' saves", async () => {
    const { hosts } = await setup(2)
    const [a, b] = hosts as [Host, Host]
    await b.save('vendors', topic('Vendors', 'Acme ships Tuesdays'))

    expect((await a.save('release', topic('Release', 'Fridays'))).code).toBe(0)

    expect(await a.read('vendors')).toBe(topic('Vendors', 'Acme ships Tuesdays'))
  })

  it('takes concurrent saves on one host in turn, keeping all of them', async () => {
    const { remote, hosts } = await setup()
    const [a] = hosts as [Host]
    const names = Array.from({ length: 8 }, (_, i) => `topic-${i}`)

    const results = await Promise.all(names.map((name) => a.save(name, topic(name, 'fact'))))

    expect(results.map((r) => r.code)).toEqual(names.map(() => 0))
    expect(await git(remote, 'rev-list', '--count', BRANCH)).toBe(String(names.length + 1))
    expect(await git(a.dir, 'status', '--porcelain')).toBe('')
  }, 30_000)

  it('commits only its own topic', async () => {
    const { hosts } = await setup()
    const [a] = hosts as [Host]
    await writeFile(join(a.dir, 'stray.md'), 'left by hand\n')

    await a.save('billing', topic('Billing', 'Net 30'))

    expect(await git(a.dir, 'show', '--name-only', '--format=', 'HEAD')).toBe('billing.md')
    expect(await git(a.dir, 'status', '--porcelain')).toBe('?? stray.md')
  })

  it('makes no commit when nothing changed', async () => {
    const { hosts } = await setup()
    const [a] = hosts as [Host]
    const text = topic('Billing', 'Net 30')
    await a.save('billing', text)
    const before = await git(a.dir, 'rev-parse', 'HEAD')

    const result = await a.save('billing', text)

    expect(result.code).toBe(0)
    expect(result.stdout).toContain('nothing changed')
    expect(await git(a.dir, 'rev-parse', 'HEAD')).toBe(before)
  })

  it('keeps a save it could not push, and pushes it with the next one', async () => {
    const { remote, hosts } = await setup()
    const [a] = hosts as [Host]
    const origin = await git(a.dir, 'remote', 'get-url', 'origin')
    await unreachable(a)

    const offline = await a.save('offline', topic('Offline', 'saved offline'))
    expect(offline.code).toBe(0)
    expect(offline.stderr).toContain("couldn't push")

    await git(a.dir, 'remote', 'set-url', 'origin', origin)
    await a.save('online', topic('Online', 'back'))

    expect(await onRemote(remote, 'offline')).toBe(topic('Offline', 'saved offline'))
  })

  it('refuses a topic name that is not lowercase words joined by hyphens', async () => {
    const { hosts } = await setup()
    const result = await hosts[0]!.memory(['save', 'Bad Name', 'new', 's', 'b'], '# Bad\n')
    expect(result.code).toBe(2)
    expect(existsSync(join(hosts[0]!.dir, 'Bad Name.md'))).toBe(false)
  })

  it('refuses a topic that does not open with a heading', async () => {
    const { hosts } = await setup()
    const result = await hosts[0]!.memory(['save', 'billing', 'new', 's', 'b'], '- no heading\n')
    expect(result.code).toBe(2)
  })
})

describe('conflicts with changes made elsewhere', () => {
  it('sets aside a save made offline that another host contradicted, and hands it back', async () => {
    const { remote, hosts } = await setup(2)
    const [a, b] = hosts as [Host, Host]
    await a.save('billing', topic('Billing', 'finance@'))
    await git(b.dir, 'pull', '--quiet')
    const origin = await git(a.dir, 'remote', 'get-url', 'origin')
    await unreachable(a)
    await a.save('billing', topic('Billing', 'accounts@'), 'Invoices go to accounts@')
    await git(a.dir, 'remote', 'set-url', 'origin', origin)
    await b.save('billing', topic('Billing', 'ap@'))

    const result = await a.save('vendors', topic('Vendors', 'Acme'))

    expect(result.code).toBe(3)
    expect(result.stderr).toContain('set aside')
    expect(result.stderr).toContain('Invoices go to accounts@')
    expect(result.stderr).toContain('+- accounts@')
    expect(await a.read('billing')).toBe(topic('Billing', 'ap@'))
    expect(
      await git(a.dir, 'for-each-ref', '--format=%(refname)', 'refs/memory/set-aside'),
    ).not.toBe('')

    const retry = await a.save('vendors', topic('Vendors', 'Acme'))
    expect(retry.code).toBe(0)
    expect(await onRemote(remote, 'vendors')).toBe(topic('Vendors', 'Acme'))
  }, 30_000)

  it('sets aside a save that lost a push race on the same topic', async () => {
    const { remote, hosts } = await setup(2)
    const [a, b] = hosts as [Host, Host]
    await a.save('billing', topic('Billing', 'ap@'))
    await git(b.dir, 'pull', '--quiet')
    // On a's first push, host b saves the same topic and a's push is
    // rejected, which is a race between a's pull and its push made certain.
    // Git exports GIT_DIR to hooks, which would point b's git at a.
    const raced = join(await tempDir(), 'raced')
    const hook = join(a.dir, '.git', 'hooks', 'pre-push')
    const script = skillScript('bishop-memory', 'memory', 'memory.sh')
    await writeFile(
      hook,
      [
        '#!/bin/sh',
        `[ -e '${raced}' ] && exit 0`,
        `touch '${raced}'`,
        'unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE',
        `export AGENT_MEMORY_HOME='${b.dir}'`,
        `v=$(bash '${script}' version billing)`,
        `printf '# Billing\\n\\n- payables@\\n' | bash '${script}' save billing "$v" payables Sam >/dev/null 2>&1`,
        'exit 1',
        '',
      ].join('\n'),
    )
    await chmod(hook, 0o755)

    const result = await a.save('billing', topic('Billing', 'ap@', 'Net 30'), 'Net 30')

    expect(result.code).toBe(3)
    expect(result.stderr).toContain('+- Net 30')
    expect(await a.read('billing')).toBe(topic('Billing', 'payables@'))

    const retry = await a.save('billing', topic('Billing', 'payables@', 'Net 30'))
    expect(retry.code).toBe(0)
    expect(await onRemote(remote, 'billing')).toBe(topic('Billing', 'payables@', 'Net 30'))
  }, 30_000)
})

describe('forget', () => {
  it('deletes the topic and pushes', async () => {
    const { remote, hosts } = await setup()
    const [a] = hosts as [Host]
    await a.save('vendors', topic('Vendors', 'Acme'))

    const result = await a.memory([
      'forget',
      'vendors',
      await a.version('vendors'),
      'We dropped Acme',
      'Dana',
    ])

    expect(result.code).toBe(0)
    expect(existsSync(join(a.dir, 'vendors.md'))).toBe(false)
    expect(await git(remote, 'ls-tree', '--name-only', BRANCH)).toBe('')
  })

  it('refuses a topic that does not exist', async () => {
    const { hosts } = await setup()
    expect((await hosts[0]!.memory(['forget', 'vendors', 'new', 's', 'b'])).code).toBe(2)
  })

  it('refuses a version that is no longer current', async () => {
    const { hosts } = await setup()
    const [a] = hosts as [Host]
    await a.save('vendors', topic('Vendors', 'Acme'))
    const result = await a.memory(['forget', 'vendors', 'new', 's', 'b'])
    expect(result.code).toBe(3)
    expect(existsSync(join(a.dir, 'vendors.md'))).toBe(true)
  })
})

describe('undo', () => {
  it('reverts an earlier change with who asked for it', async () => {
    const { hosts } = await setup()
    const [a] = hosts as [Host]
    const text = topic('Vendors', 'Acme')
    await a.save('vendors', text)
    await a.memory(['forget', 'vendors', await a.version('vendors'), 'We dropped Acme', 'Dana'])
    const forgot = await git(a.dir, 'rev-parse', 'HEAD')

    const result = await a.memory(['undo', forgot, 'Put Acme back', 'Sam'])

    expect(result.code).toBe(0)
    expect(await a.read('vendors')).toBe(text)
    expect(await git(a.dir, 'log', '-1', '--format=%(trailers:key=Taught-by,valueonly)')).toBe(
      'Sam',
    )
  })

  it('refuses a change whose topic has changed since, leaving the checkout clean', async () => {
    const { hosts } = await setup()
    const [a] = hosts as [Host]
    await a.save('billing', topic('Billing', 'finance@'))
    const first = await git(a.dir, 'rev-parse', 'HEAD')
    await a.save('billing', topic('Billing', 'ap@'))

    const result = await a.memory(['undo', first, 'Drop billing', 'Sam'])

    expect(result.code).toBe(3)
    expect(await git(a.dir, 'status', '--porcelain')).toBe('')
    expect(await a.read('billing')).toBe(topic('Billing', 'ap@'))
  })

  it('refuses a change that does not exist', async () => {
    const { hosts } = await setup()
    expect((await hosts[0]!.memory(['undo', 'deadbeef', 's', 'b'])).code).toBe(2)
  })
})

describe('where memory lives', () => {
  /** An agent's repository whose origin is the remote, the way Bishop runs one. */
  async function agentRepo(origin: string): Promise<string> {
    const dir = await tempDir('cookbook-agent-')
    await git(dir, 'init', '--quiet')
    await git(dir, 'remote', 'add', 'origin', origin)
    return dir
  }

  /** Runs memory.sh as an agent would, with nothing set but what a test passes. */
  async function memory(
    cwd: string,
    args: string[],
    env: Record<string, string> = {},
    input?: string,
  ): Promise<Result> {
    return runScript('bishop-memory', 'memory', 'memory.sh', args, {
      cwd,
      env: {
        AGENT_MEMORY_HOME: '',
        XDG_DATA_HOME: await tempDir('cookbook-data-'),
        ...IDENTITY,
        ...env,
      },
      ...(input === undefined ? {} : { input }),
    })
  }

  /** The checkout a default clone makes has no identity of its own. */
  const IDENTITY = {
    GIT_AUTHOR_NAME: 'Agent',
    GIT_AUTHOR_EMAIL: 'agent@example.com',
    GIT_COMMITTER_NAME: 'Agent',
    GIT_COMMITTER_EMAIL: 'agent@example.com',
  }

  it('is AGENT_MEMORY_HOME when it is set', async () => {
    const { hosts } = await setup()
    const result = await hosts[0]!.memory(['path'])
    expect(result.stdout.trim()).toBe(hosts[0]!.dir)
  })

  it('defaults to a clone of the agent repository, named after it', async () => {
    const remote = await bareRemote(BRANCH)
    const data = await tempDir('cookbook-data-')
    const agent = await agentRepo(remote)
    const env = { XDG_DATA_HOME: data }

    const path = (await memory(agent, ['path'], env)).stdout.trim()
    const owner = basename(dirname(remote))
    expect(path).toBe(join(data, 'bishop-memory', `${owner}-remote`))
    expect(await git(path, 'branch', '--show-current')).toBe(BRANCH)

    const saved = await memory(
      agent,
      ['save', 'billing', 'new', 'Invoices', 'Dana'],
      env,
      topic('Billing', 'finance@'),
    )
    expect(saved.code).toBe(0)
    expect(await onRemote(remote, 'billing')).toBe(topic('Billing', 'finance@'))
  })

  it('names the default after the owner and repository in a GitHub URL', async () => {
    const data = await tempDir('cookbook-data-')
    const agent = await agentRepo(join(await tempDir(), 'acme', 'agent.git'))
    await git(agent, 'remote', 'set-url', 'origin', 'git@github.com:acme/agent.git')
    await git(agent, 'config', 'url.file:///nowhere/.insteadOf', 'git@github.com:')
    const result = await memory(agent, ['path'], { XDG_DATA_HOME: data })
    expect(result.code).toBe(1)
    expect(result.stderr).toContain(join(data, 'bishop-memory', 'acme-agent'))
    expect(existsSync(join(data, 'bishop-memory', 'acme-agent'))).toBe(false)
  })

  it('clones once when two conversations start at the same moment', async () => {
    const remote = await bareRemote(BRANCH)
    const agent = await agentRepo(remote)
    const env = { XDG_DATA_HOME: await tempDir('cookbook-data-') }
    const results = await Promise.all([memory(agent, ['path'], env), memory(agent, ['path'], env)])
    expect(results.map((r) => r.code)).toEqual([0, 0])
    expect(results[0]!.stdout).toBe(results[1]!.stdout)
  })

  it('uses the branch AGENT_MEMORY_BRANCH names', async () => {
    const remote = await bareRemote('notes')
    const agent = await agentRepo(remote)
    const env = { AGENT_MEMORY_BRANCH: 'notes' }
    const saved = await memory(
      agent,
      ['save', 'billing', 'new', 'Invoices', 'Dana'],
      env,
      topic('Billing', 'finance@'),
    )
    expect(saved.code).toBe(0)
    expect(await git(remote, 'show', 'notes:billing.md')).toBe(
      topic('Billing', 'finance@').trimEnd(),
    )
  })

  it('pulls and pushes the branch in a checkout with no upstream set', async () => {
    const { remote, hosts } = await setup(2)
    const [a, b] = hosts as [Host, Host]
    await git(a.dir, 'branch', '--unset-upstream')
    await b.save('vendors', topic('Vendors', 'Acme'))
    expect((await a.save('billing', topic('Billing', 'finance@'))).code).toBe(0)
    expect(await a.read('vendors')).toBe(topic('Vendors', 'Acme'))
    expect(await onRemote(remote, 'billing')).toBe(topic('Billing', 'finance@'))
  })

  it('fails without creating a branch the remote lacks', async () => {
    const remote = await bareRemote(BRANCH)
    const agent = await agentRepo(remote)
    const data = await tempDir('cookbook-data-')
    const result = await memory(agent, ['path'], {
      XDG_DATA_HOME: data,
      AGENT_MEMORY_BRANCH: 'notes',
    })
    expect(result.code).toBe(1)
    expect(result.stderr).toContain("couldn't clone the notes branch")
    expect(await git(remote, 'branch', '--list', 'notes')).toBe('')
    expect(await readdir(join(data, 'bishop-memory'))).toEqual([
      `.${basename(dirname(remote))}-remote.lock`,
    ])
  })

  it('refuses a checkout of a different branch', async () => {
    const { hosts } = await setup()
    const result = await memory(hosts[0]!.dir, ['path'], {
      AGENT_MEMORY_HOME: hosts[0]!.dir,
      AGENT_MEMORY_BRANCH: 'notes',
    })
    expect(result.code).toBe(1)
    expect(result.stderr).toContain(`has ${BRANCH} checked out rather than the notes branch`)
  })

  it('fails when AGENT_MEMORY_HOME is unset and the agent has no origin', async () => {
    const result = await memory(await tempDir(), ['version', 'billing'])
    expect(result.code).toBe(1)
    expect(result.stderr).toContain('no origin remote')
  })

  it('fails when AGENT_MEMORY_HOME is not a git checkout', async () => {
    const dir = await tempDir()
    const result = await memory(dir, ['version', 'billing'], { AGENT_MEMORY_HOME: dir })
    expect(result.code).toBe(1)
    expect(result.stderr).toContain('not a git checkout')
  })

  it('prints usage for an unknown command', async () => {
    const { hosts } = await setup()
    expect((await hosts[0]!.memory(['remember', 'billing'])).code).toBe(2)
  })
})
