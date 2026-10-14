/**
 * Real git repositories in temp directories. A bare repository on a local path
 * clones and pushes like any remote, so nothing here reaches the network.
 */

import { mkdtemp } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { run } from './script.js'

export function tempDir(prefix = 'cookbook-'): Promise<string> {
  return mkdtemp(join(tmpdir(), prefix))
}

/** Runs git in a directory, throwing with git's own message when it fails. */
export async function git(cwd: string, ...args: string[]): Promise<string> {
  const result = await run('git', args, { cwd })
  if (result.code !== 0) {
    throw new Error(`git ${args.join(' ')} failed in ${cwd}: ${result.stderr}`)
  }
  return result.stdout.trim()
}

/**
 * A bare remote holding one branch with an empty first commit, the way a
 * branch with no history in common with anything else starts.
 */
export async function bareRemote(branch: string): Promise<string> {
  const dir = await tempDir('cookbook-remote-')
  const remote = join(dir, 'remote.git')
  const seed = join(dir, 'seed')
  await git(dir, 'init', '--quiet', '--bare', `--initial-branch=${branch}`, remote)
  await git(dir, 'init', '--quiet', `--initial-branch=${branch}`, seed)
  await identify(seed)
  await git(seed, 'commit', '--quiet', '--allow-empty', '-m', 'Start')
  await git(seed, 'push', '--quiet', remote, branch)
  return remote
}

/** A clone of one branch with an identity set, standing in for one host's checkout. */
export async function clone(remote: string, branch: string): Promise<string> {
  const dir = join(await tempDir('cookbook-clone-'), 'checkout')
  await git(process.cwd(), 'clone', '--quiet', '--branch', branch, remote, dir)
  await identify(dir)
  return dir
}

/** Git config is isolated from the developer's, so every repository needs its own identity. */
async function identify(dir: string): Promise<void> {
  await git(dir, 'config', 'user.name', 'Agent')
  await git(dir, 'config', 'user.email', 'agent@example.com')
}
