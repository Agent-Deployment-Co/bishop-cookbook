/**
 * notion.sh run against a stand-in for curl, so nothing reaches Notion, and a
 * stand-in for sleep, so retries are recorded instead of waited out.
 */

import { existsSync } from 'node:fs'
import { chmod, mkdir, readdir, readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { tempDir } from '../support/git.js'
import { type Result, runScript } from '../support/script.js'

const TOKEN = 'ntn_test_token_0123456789'

/**
 * Records each call's arguments, the header file it was given, and the body it
 * sent, then plays back the response queued for that call. A call with nothing
 * queued fails the way curl does when it can't connect.
 */
const CURL = `#!/usr/bin/env bash
set -euo pipefail
n=$(( $(cat "$FAKE/calls" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$FAKE/calls"
printf '%s\\n' "$@" >"$FAKE/$n.args"
while (( $# )); do
  case $1 in
    -D) headers=$2; shift ;;
    -o) out=$2; shift ;;
    -H) if [[ $2 == @* ]]; then cat "\${2#@}" >"$FAKE/$n.headerfile"; fi; shift ;;
    --data-binary) cat "\${2#@}" >"$FAKE/$n.request"; shift ;;
  esac
  shift
done
r=$FAKE/responses/$n
[[ -f $r.status ]] || { echo "curl: (7) Failed to connect" >&2; exit 7; }
cat "$r.headers" >"$headers"
cat "$r.body" >"$out"
cat "$r.status"
`

const SLEEP = `#!/usr/bin/env bash
echo "$1" >>"$FAKE/sleeps"
`

interface Response {
  status: number
  body?: string
  headers?: Record<string, string>
}

interface Notion {
  /** Runs notion.sh with the token set, unless `env` says otherwise. */
  call(
    args: string[],
    options?: { input?: string; env?: Record<string, string | undefined> },
  ): Promise<Result>
  /** How many times notion.sh called curl. */
  calls(): Promise<number>
  /** The arguments notion.sh gave curl on a call, one per element. */
  args(call: number): Promise<string[]>
  file(name: string): Promise<string>
  has(name: string): boolean
  /** The seconds notion.sh asked to sleep, in order. */
  sleeps(): Promise<string[]>
  /** notion.sh's temp directory, to check it cleans up after itself. */
  tmp: string
}

/** A fake Notion that answers each call with the next response in `responses`. */
async function notion(...responses: Response[]): Promise<Notion> {
  const fake = await tempDir('notion-')
  const bin = join(fake, 'bin')
  const tmp = join(fake, 'tmp')
  await mkdir(bin)
  await mkdir(tmp)
  await mkdir(join(fake, 'responses'))
  for (const [name, script] of [
    ['curl', CURL],
    ['sleep', SLEEP],
  ] as const) {
    await writeFile(join(bin, name), script)
    await chmod(join(bin, name), 0o755)
  }
  for (const [i, r] of responses.entries()) {
    const base = join(fake, 'responses', String(i + 1))
    const headers = Object.entries(r.headers ?? {}).map(([k, v]) => `${k}: ${v}\r\n`)
    await writeFile(`${base}.status`, String(r.status))
    await writeFile(`${base}.headers`, `HTTP/2 ${r.status}\r\n${headers.join('')}\r\n`)
    await writeFile(`${base}.body`, r.body ?? '{}')
  }
  const file = (name: string) => readFile(join(fake, name), 'utf8')
  return {
    call: (args, options = {}) =>
      runScript('bishop-notion', 'notion', 'notion.sh', args, {
        env: {
          PATH: `${bin}:${process.env.PATH}`,
          FAKE: fake,
          TMPDIR: tmp,
          NOTION_TOKEN: TOKEN,
          ...options.env,
        },
        ...(options.input === undefined ? {} : { input: options.input }),
      }),
    calls: async () => (existsSync(join(fake, 'calls')) ? Number(await file('calls')) : 0),
    args: async (call) => (await file(`${call}.args`)).trimEnd().split('\n'),
    file,
    has: (name) => existsSync(join(fake, name)),
    sleeps: async () =>
      existsSync(join(fake, 'sleeps')) ? (await file('sleeps')).trimEnd().split('\n') : [],
    tmp,
  }
}

/** The value curl was given after `flag`, or every value when the flag repeats. */
function flagValues(args: string[], flag: string): string[] {
  return args.flatMap((arg, i) => (arg === flag ? [args[i + 1]!] : []))
}

describe('before calling Notion', () => {
  it('exits 2 when NOTION_TOKEN is not set', async () => {
    const n = await notion({ status: 200 })
    const result = await n.call(['GET', 'users/me'], { env: { NOTION_TOKEN: undefined } })
    expect(result.code).toBe(2)
    expect(result.stderr).toContain('NOTION_TOKEN')
    expect(await n.calls()).toBe(0)
  })

  it('exits 64 on the wrong number of arguments', async () => {
    const n = await notion({ status: 200 })
    expect((await n.call(['GET'])).code).toBe(64)
    expect((await n.call(['POST', 'search', '{}', 'extra'])).code).toBe(64)
    expect(await n.calls()).toBe(0)
  })

  it('exits 64 on a body that is not JSON', async () => {
    const n = await notion({ status: 200 })
    const result = await n.call(['POST', 'search', '{"query": '])
    expect(result.code).toBe(64)
    expect(result.stderr).toContain('not valid JSON')
    expect(await n.calls()).toBe(0)
  })
})

describe('a call', () => {
  it('goes to the path under /v1/ with the pinned API version, and prints the response', async () => {
    const n = await notion({ status: 200, body: '{"object":"page","id":"abc"}' })
    const result = await n.call(['get', '/v1/pages/abc'])
    expect(result).toMatchObject({ code: 0, stdout: '{"object":"page","id":"abc"}\n' })
    const args = await n.args(1)
    expect(flagValues(args, '-X')).toEqual(['GET'])
    expect(args).toContain('https://api.notion.com/v1/pages/abc')
    expect(flagValues(args, '-H')).toContain('Notion-Version: 2026-03-11')
    expect(n.has('1.request')).toBe(false)
  })

  it('keeps the token out of the command line', async () => {
    const n = await notion({ status: 200 })
    await n.call(['GET', 'users/me'])
    expect((await n.args(1)).join(' ')).not.toContain(TOKEN)
    expect(await n.file('1.headerfile')).toBe(`Authorization: Bearer ${TOKEN}\n`)
  })

  it('sends a body given as an argument', async () => {
    const n = await notion({ status: 200 })
    const body = '{"query": "onboarding", "page_size": 10}'
    await n.call(['POST', 'search', body])
    expect(await n.file('1.request')).toBe(body)
    expect(flagValues(await n.args(1), '-H')).toContain('Content-Type: application/json')
  })

  it('sends a body read from stdin when the body is -', async () => {
    const n = await notion({ status: 200 })
    const body = '{"type": "insert_content",\n "insert_content": {"content": "Line\\nTwo"}}'
    await n.call(['PATCH', 'pages/abc/markdown', '-'], { input: body })
    expect(await n.file('1.request')).toBe(body)
  })

  it('leaves nothing behind in the temp directory, the token file included', async () => {
    const n = await notion({ status: 200 }, { status: 404 })
    await n.call(['GET', 'users/me'])
    await n.call(['GET', 'pages/gone'])
    expect(await readdir(n.tmp)).toEqual([])
  })
})

describe('an error', () => {
  it('is printed, with exit 1 and the status on stderr', async () => {
    const error = '{"object":"error","status":404,"code":"object_not_found"}'
    const n = await notion({ status: 404, body: error })
    const result = await n.call(['GET', 'pages/abc'])
    expect(result).toMatchObject({ code: 1, stdout: `${error}\n` })
    expect(result.stderr).toContain('HTTP 404 from GET /v1/pages/abc')
  })

  it('is not retried unless it is a rate limit or a gateway error', async () => {
    const n = await notion({ status: 500 }, { status: 200 })
    expect((await n.call(['GET', 'users/me'])).code).toBe(1)
    expect(await n.calls()).toBe(1)
  })

  it('exits 1 when the request never reaches Notion', async () => {
    const n = await notion()
    const result = await n.call(['GET', 'users/me'])
    expect(result.code).toBe(1)
    expect(result.stderr).toContain('request to https://api.notion.com/v1/users/me failed')
  })
})

describe('retries', () => {
  it('wait as long as Retry-After says on a rate limit', async () => {
    const n = await notion(
      { status: 429, headers: { 'Retry-After': '7' } },
      { status: 200, body: '{"ok":true}' },
    )
    const result = await n.call(['GET', 'users/me'])
    expect(result).toMatchObject({ code: 0, stdout: '{"ok":true}\n' })
    expect(await n.sleeps()).toEqual(['7'])
  })

  it('wait a second when Retry-After is missing or over a minute', async () => {
    const n = await notion(
      { status: 429 },
      { status: 429, headers: { 'retry-after': '120' } },
      { status: 200 },
    )
    expect((await n.call(['GET', 'users/me'])).code).toBe(0)
    expect(await n.sleeps()).toEqual(['1', '1'])
  })

  it('back off longer after each gateway error', async () => {
    const n = await notion({ status: 502 }, { status: 503 }, { status: 504 }, { status: 200 })
    expect((await n.call(['GET', 'users/me'])).code).toBe(0)
    expect(await n.sleeps()).toEqual(['2', '4', '6'])
  })

  it('give up after four attempts and print the last error', async () => {
    const limited = (i: number): Response => ({ status: 429, body: `{"attempt":${i}}` })
    const n = await notion(limited(1), limited(2), limited(3), limited(4), { status: 200 })
    const result = await n.call(['GET', 'users/me'])
    expect(result).toMatchObject({ code: 1, stdout: '{"attempt":4}\n' })
    expect(await n.calls()).toBe(4)
    expect(await n.sleeps()).toHaveLength(3)
  })
})
