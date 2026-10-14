/**
 * Runs a skill's script the way an agent would: with `bash`, by its full path,
 * from whatever directory the agent happens to be in.
 */

import { spawn } from 'node:child_process'
import { join, resolve } from 'node:path'

export const ROOT = resolve(import.meta.dirname, '..', '..')

/** The path to a script inside a skill's directory. */
export function skillScript(skill: string, name: string): string {
  return join(ROOT, skill, name)
}

export interface Result {
  code: number
  stdout: string
  stderr: string
}

export interface RunOptions {
  cwd?: string
  env?: Record<string, string | undefined>
  input?: string
}

/**
 * Git reads the developer's own config unless told not to, and a hook or an
 * identity there would change what a test sees.
 */
const ISOLATED: Record<string, string> = {
  GIT_CONFIG_GLOBAL: '/dev/null',
  GIT_CONFIG_NOSYSTEM: '1',
}

/** Runs a command to completion. Never throws on a non-zero exit, since that is often the point. */
export function run(command: string, args: string[], options: RunOptions = {}): Promise<Result> {
  return new Promise((done, fail) => {
    const child = spawn(command, args, {
      cwd: options.cwd,
      env: { ...process.env, ...ISOLATED, ...options.env },
      stdio: ['pipe', 'pipe', 'pipe'],
    })
    let stdout = ''
    let stderr = ''
    child.stdout.on('data', (chunk) => {
      stdout += chunk
    })
    child.stderr.on('data', (chunk) => {
      stderr += chunk
    })
    child.on('error', fail)
    child.on('close', (code) => done({ code: code ?? -1, stdout, stderr }))
    child.stdin.end(options.input ?? '')
  })
}

/** Runs a skill's script with `bash`. */
export function runScript(
  skill: string,
  name: string,
  args: string[],
  options: RunOptions = {},
): Promise<Result> {
  return run('bash', [skillScript(skill, name), ...args], options)
}
