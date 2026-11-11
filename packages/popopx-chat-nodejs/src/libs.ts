import * as crypto from "crypto"
import * as fs from "fs"
import * as http from "http"
import * as https from "https"
import * as os from "os"
import * as path from "path"
import {pipeline} from "stream/promises"
import * as yauzl from "yauzl"
import type {Backend} from "./core"
import {ADDON_RELEASE, LIBS_RELEASE, SHA256} from "./release"

const GITHUB_REPO = "simplex-chat/simplex-chat-libs"
const REQUEST_TIMEOUT_MS = 60_000
export const MAX_REDIRECTS = 5
// Two spellings of the same library, in load order.  libpopopx.* is what this fork's own build
// scripts produce (scripts/desktop/build-lib-*, flake.nix, the Dockerfiles) and what
// POPOPX_LIBS_DIR/SIMPLEX_LIBS_DIR points at after a local build.  libsimplex.* is what the
// pinned release asset still contains, because GITHUB_REPO is upstream's simplex-chat-libs --
// until POPOPX publishes its own libs repository the download can only serve the old name, so
// every lookup keeps both.
const PLATFORMS: {[platform: string]: {name: string, libs: string[]} | undefined} = {
  linux: {name: "linux", libs: ["libpopopx.so", "libsimplex.so"]},
  darwin: {name: "macos", libs: ["libpopopx.dylib", "libsimplex.dylib"]},
  win32: {name: "windows", libs: ["libpopopx.dll", "libsimplex.dll"]},
}
const ARCHS: {[arch: string]: string | undefined} = {x64: "x86_64", arm64: "aarch64"}
const SUPPORTED = ["linux-x86_64", "linux-aarch64", "macos-x86_64", "macos-aarch64", "windows-x86_64"]
const S_IFMT = 0o170000
const S_IFLNK = 0o120000

function unsupported(platform: string, arch: string): Error {
  return new Error(`Unsupported platform: ${platform}/${arch}; supported: ${SUPPORTED.join(", ")}`)
}

export function platformTag(platform: string, arch: string): string {
  const tag = `${PLATFORMS[platform]?.name}-${ARCHS[arch]}`
  if (!SUPPORTED.includes(tag)) throw unsupported(platform, arch)
  return tag
}

export function libNames(platform: string = process.platform, arch: string = process.arch): string[] {
  const libs = PLATFORMS[platform]?.libs
  if (!libs) throw unsupported(platform, arch)
  return libs
}

function libName(platform: string = process.platform, arch: string = process.arch): string {
  return libNames(platform, arch)[0]
}

// The name that is actually in `dir`, preferring ours.  Falls back to the first name when
// the directory is empty, so callers that are about to create the file still work.
function presentLib(dir: string, platform: string = process.platform, arch: string = process.arch): string {
  for (const name of libNames(platform, arch)) if (fs.existsSync(path.join(dir, name))) return name
  return libName(platform, arch)
}

export function cacheRoot(platform: string, env: NodeJS.ProcessEnv, home: string = os.homedir()): string {
  if (platform === "darwin") return path.join(home, "Library", "Caches", "simplex-chat")
  if (platform === "win32") {
    if (!env.LOCALAPPDATA) throw new Error("LOCALAPPDATA is not set")
    return path.join(env.LOCALAPPDATA, "simplex-chat")
  }
  return path.join(env.XDG_CACHE_HOME || path.join(home, ".cache"), "simplex-chat")
}

export function libsAsset(backend: Backend, tag: string): string {
  const suffix = backend === "postgres" ? "-postgres" : ""
  return `simplex-chat-libs-${tag}${suffix}.zip`
}

export function addonAsset(tag: string): string {
  return `simplex-chat-nodejs-${tag}.node`
}

export function releaseUrl(release: string, asset: string): string {
  return `https://github.com/${GITHUB_REPO}/releases/download/${release}/${asset}`
}

function pinnedSha256(asset: string): string {
  const sha256 = SHA256[asset]
  if (!sha256) throw new Error(`no SHA-256 is pinned for ${asset}`)
  return sha256
}

export function libPath(dir: string): string {
  return path.join(dir, presentLib(dir))
}

// Two spellings of the same override: POPOPX_* is current, SIMPLEX_* keeps an existing CI job,
// Dockerfile or Local.xcconfig working. The error names whichever one the caller actually set.
function envOverride(env: NodeJS.ProcessEnv, current: string, legacy: string): {name: string, value: string} | undefined {
  if (env[current]) return {name: current, value: env[current] as string}
  if (env[legacy]) return {name: legacy, value: env[legacy] as string}
}

export async function resolveLibsDir(
  backend: Backend,
  env: NodeJS.ProcessEnv = process.env,
  platform: string = process.platform,
  arch: string = process.arch
): Promise<string> {
  const libs = libNames(platform, arch)
  const override = envOverride(env, "POPOPX_LIBS_DIR", "SIMPLEX_LIBS_DIR")
  if (override) {
    const dir = path.resolve(override.value)
    if (!libs.some(lib => fs.existsSync(path.join(dir, lib)))) {
      throw new Error(`${override.name} has none of ${libs.join(", ")}: ${dir}`)
    }
    return dir
  }
  const tag = platformTag(platform, arch)
  if (backend === "postgres" && tag !== "linux-x86_64") {
    throw new Error(`postgres backend is only supported on linux-x86_64; current platform is ${tag}`)
  }
  const target = path.resolve(cacheRoot(platform, env), LIBS_RELEASE, backend)
  if (!libs.some(lib => fs.existsSync(path.join(target, lib)))) {
    const asset = libsAsset(backend, tag)
    await installLibs(releaseUrl(LIBS_RELEASE, asset), pinnedSha256(asset), target, libs)
  }
  return target
}

export async function resolveAddonPath(
  env: NodeJS.ProcessEnv = process.env,
  platform: string = process.platform,
  arch: string = process.arch
): Promise<string> {
  const override = envOverride(env, "POPOPX_ADDON_PATH", "SIMPLEX_ADDON_PATH")
  if (override) {
    const file = path.resolve(override.value)
    if (!fs.existsSync(file)) throw new Error(`${override.name} does not exist: ${file}`)
    return file
  }
  if (!ADDON_RELEASE) throw new Error("no prebuilt Node.js add-on is pinned in this version; set POPOPX_ADDON_PATH")
  const asset = addonAsset(platformTag(platform, arch))
  const target = path.resolve(cacheRoot(platform, env), ADDON_RELEASE, asset)
  if (!fs.existsSync(target)) await installAddon(releaseUrl(ADDON_RELEASE, asset), pinnedSha256(asset), target)
  return target
}

export function installLibs(url: string, sha256: string, target: string, lib: string | string[], timeoutMs: number = REQUEST_TIMEOUT_MS): Promise<void> {
  const libs = Array.isArray(lib) ? lib : [lib]
  return inTempDir(target, async tmp => {
    process.stderr.write(`Downloading the native libs from ${url} ...\n`)
    const zipPath = path.join(tmp, "libs.zip")
    await download(url, zipPath, timeoutMs)
    await verifySha256(zipPath, sha256, url)
    await unzip(zipPath, tmp)
    const extracted = path.join(tmp, "libs")
    const name = libs.find(n => fs.existsSync(path.join(extracted, n)))
    if (!name) throw new Error(`libs/${libs.join(" or ")} missing from ${url}`)
    await renameInto(extracted, target, path.join(target, name))
  })
}

export function installAddon(url: string, sha256: string, target: string, timeoutMs: number = REQUEST_TIMEOUT_MS): Promise<void> {
  return inTempDir(target, async tmp => {
    process.stderr.write(`Downloading the Node.js add-on from ${url} ...\n`)
    const file = path.join(tmp, path.basename(target))
    await download(url, file, timeoutMs)
    await verifySha256(file, sha256, url)
    await renameInto(file, target, target)
  })
}

function unzip(zipPath: string, dir: string): Promise<void> {
  const root = path.resolve(dir)
  return new Promise((resolve, reject) => {
    yauzl.open(zipPath, {lazyEntries: true}, (err, zip) => {
      if (err || !zip) return reject(err ?? new Error(`cannot open ${zipPath}`))
      let failed = false
      const fail = (e: unknown) => {
        if (failed) return
        failed = true
        zip.close()
        reject(e)
      }
      zip.on("error", e => {
        failed = true
        reject(e)
      })
      zip.on("end", () => resolve())
      zip.on("entry", (entry: yauzl.Entry) => {
        const dest = path.resolve(root, entry.fileName)
        if (!dest.startsWith(root + path.sep)) return fail(new Error(`zip entry outside the target folder: ${entry.fileName}`))
        const mode = entry.externalFileAttributes >>> 16
        if ((mode & S_IFMT) === S_IFLNK) return fail(new Error(`zip entry is a symlink: ${entry.fileName}`))
        if (entry.fileName.endsWith("/")) {
          fs.promises.mkdir(dest, {recursive: true}).then(() => zip.readEntry(), fail)
          return
        }
        zip.openReadStream(entry, (e, stream) => {
          if (e || !stream) return fail(e ?? new Error(`cannot read ${entry.fileName}`))
          fs.promises.mkdir(path.dirname(dest), {recursive: true})
            .then(() => pipeline(stream, fs.createWriteStream(dest, {mode: (mode & 0o777) || 0o644})))
            .then(() => zip.readEntry(), fail)
        })
      })
      zip.readEntry()
    })
  })
}

async function verifySha256(file: string, expected: string, url: string): Promise<void> {
  const hash = crypto.createHash("sha256")
  for await (const chunk of fs.createReadStream(file)) hash.update(chunk)
  const actual = hash.digest("hex")
  if (actual !== expected) throw new Error(`SHA-256 of ${url} is ${actual}, expected ${expected}`)
}

// The temp dir is next to the target, so the final rename stays on one filesystem.
async function inTempDir(target: string, install: (tmp: string) => Promise<void>): Promise<void> {
  const parent = path.dirname(target)
  await fs.promises.mkdir(parent, {recursive: true})
  const tmp = await fs.promises.mkdtemp(path.join(parent, ".download-"))
  try {
    await install(tmp)
  } finally {
    await fs.promises.rm(tmp, {recursive: true, force: true})
  }
}

async function renameInto(from: string, target: string, installed: string): Promise<void> {
  try {
    await fs.promises.rename(from, target)
  } catch (e) {
    // Another process installed the same version first; its files are identical.
    // Windows reports renaming onto an existing directory or a loaded file as EPERM.
    const code = (e as NodeJS.ErrnoException).code
    const lost = (code === "EEXIST" || code === "ENOTEMPTY" || code === "EPERM") && fs.existsSync(target)
    if (!lost) throw e
    if (!fs.existsSync(installed)) {
      throw new Error(`another process partially populated ${target} but ${path.basename(installed)} is missing; remove it manually and retry`)
    }
  }
}

function download(url: string, dest: string, timeoutMs: number, redirects = 0): Promise<void> {
  return new Promise((resolve, reject) => {
    const get = url.startsWith("https:") ? https.get : http.get
    // Once a response arrives, request errors are ignored: a download settles via pipeline, which
    // waits for the file to close, so tmp cleanup cannot fail with EBUSY on Windows.
    let res: http.IncomingMessage | undefined
    const req = get(url, {headers: {"User-Agent": "simplex-chat-nodejs"}, timeout: timeoutMs}, response => {
      res = response
      const status = response.statusCode ?? 0
      const location = response.headers.location
      if (status >= 300 && status < 400 && location) {
        response.resume()
        if (redirects >= MAX_REDIRECTS) return reject(new Error(`too many redirects downloading ${url}`))
        let next: URL
        try {
          next = new URL(location, url)
        } catch (e) {
          return reject(e)
        }
        if (next.protocol !== new URL(url).protocol) return reject(new Error(`redirect from ${url} to ${next} changes protocol`))
        download(next.toString(), dest, timeoutMs, redirects + 1).then(resolve, reject)
        return
      }
      if (status !== 200) {
        response.resume()
        return reject(new Error(`HTTP ${status} downloading ${url}`))
      }
      pipeline(response, fs.createWriteStream(dest)).then(resolve, reject)
    })
    const abort = (err: Error) => (res ? res.destroy(err) : req.destroy(err))
    req.on("timeout", () => abort(new Error(`timeout downloading ${url}`)))
    req.on("error", e => { if (!res) reject(e) })
  })
}
