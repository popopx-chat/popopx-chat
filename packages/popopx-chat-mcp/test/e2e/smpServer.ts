import {ChildProcess, spawn} from "child_process"
import {createHash} from "crypto"
import {once} from "events"
import {copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync} from "fs"
import {AddressInfo, createConnection, createServer} from "net"
import {tmpdir} from "os"
import {dirname, join} from "path"

const tlsFixtures = join(__dirname, "tls")
const serverRelease = "v7.1.0.17"
const releaseArch: Record<string, string | undefined> = {x64: "x86-64", arm64: "aarch64"}
// The digests GitHub recorded for the assets of that popopxmq release.
const serverDigests: Record<string, string> = {
  "smp-server-ubuntu-22_04-x86-64": "554fffe2e65ef3df9b891158378baf70c41749b6c2faba606c45a8761fb25eb8",
  "smp-server-ubuntu-22_04-aarch64": "b2d57ed88308c18968cd9262add357e523a9b6e685314ef73fc085643c34c439",
  "xftp-server-ubuntu-22_04-x86-64": "bfa1cba3a7be5d4b4f42e6a7a5d2cb3165a9e76bea088fcc9f09a0cca2c3c158",
  "xftp-server-ubuntu-22_04-aarch64": "84866b8dec330e79ff318244644af635e72cbb761271182d417cac49bba1595c",
}

export interface SmpServer {
  address: string
  stop: () => Promise<void>
}

interface ServerKind {
  name: string
  scheme: string
  env: string
  ini: string
  config: (port: number, dir: string) => string
}

const smp: ServerKind = {
  name: "smp-server",
  scheme: "smp",
  env: "SMP_SERVER",
  ini: "smp-server.ini",
  config: port => `[STORE_LOG]\nenable: off\n\n[TRANSPORT]\nhost: localhost\nport: ${port}\nwebsockets: off\n`,
}

const xftp: ServerKind = {
  name: "xftp-server",
  scheme: "xftp",
  env: "XFTP_SERVER",
  ini: "file-server.ini",
  config: (port, dir) => `[STORE_LOG]\nenable: off\n\n[TRANSPORT]\nhost: localhost\nport: ${port}\n\n[FILES]\npath: ${join(dir, "files")}\nstorage_quota: 1gb\n`,
}

export function startSmpServer(): Promise<SmpServer> {
  return startServer(smp)
}

export function startXftpServer(): Promise<SmpServer> {
  return startServer(xftp)
}

async function startServer(kind: ServerKind): Promise<SmpServer> {
  const port = await freePort()
  const dir = mkdtempSync(join(tmpdir(), `${kind.name}-`))
  const configDir = join(dir, "config")
  mkdirSync(configDir)
  mkdirSync(join(dir, "files"))
  for (const file of ["ca.crt", "server.crt", "server.key"]) copyFileSync(join(tlsFixtures, file), join(configDir, file))
  const fingerprint = caFingerprint(join(configDir, "ca.crt"))
  writeFileSync(join(configDir, "fingerprint"), `${fingerprint}\n`)
  writeFileSync(join(configDir, kind.ini), kind.config(port, dir))
  const server = spawn(await serverExecutable(kind), ["start"], {
    env: {...process.env, [`${kind.env}_CFG_PATH`]: configDir, [`${kind.env}_LOG_PATH`]: join(dir, "logs")},
    stdio: ["ignore", "ignore", "inherit"],
  })
  const stop = async (): Promise<void> => {
    if (server.exitCode === null) {
      const exited = once(server, "exit")
      server.kill()
      await exited
    }
    rmSync(dir, {recursive: true, force: true})
  }
  try {
    await once(server, "spawn")
    await waitForServer(server, kind, port)
  } catch (e) {
    await stop()
    throw e
  }
  return {address: `${kind.scheme}://${fingerprint}@localhost:${port}`, stop}
}

export function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const probe = createServer()
    probe.on("error", reject)
    probe.listen(0, "127.0.0.1", () => {
      const {port} = probe.address() as AddressInfo
      probe.close(() => resolve(port))
    })
  })
}

async function serverExecutable(kind: ServerKind): Promise<string> {
  const executable = process.env[kind.env]
  if (executable) return executable
  const path = join(__dirname, `../../node_modules/.cache/${kind.name}`, `${kind.name}-${serverRelease}`)
  if (!existsSync(path)) await downloadServer(kind, path)
  return path
}

async function downloadServer(kind: ServerKind, path: string): Promise<void> {
  const arch = releaseArch[process.arch]
  if (process.platform !== "linux" || !arch) {
    throw new Error(`${kind.name} release binaries are not available for ${process.platform} ${process.arch}, set ${kind.env} to the ${kind.name} path`)
  }
  // Pinned to a release of popopxmq itself: a 404 here means our own asset is missing, which is not a reason to fall back to upstream's binary
  const asset = `${kind.name}-ubuntu-22_04-${arch}`
  const url = `https://github.com/popopx-chat/popopxmq/releases/download/${serverRelease}/${asset}`
  const response = await fetch(url)
  if (!response.ok) throw new Error(`error downloading ${url}: ${response.status}`)
  const data = Buffer.from(await response.arrayBuffer())
  const digest = createHash("sha256").update(data).digest("hex")
  if (digest !== serverDigests[asset]) throw new Error(`${asset} sha256 ${digest} does not match the pinned ${serverDigests[asset]}`)
  mkdirSync(dirname(path), {recursive: true})
  writeFileSync(`${path}.download`, data, {mode: 0o755})
  renameSync(`${path}.download`, path)
}

function caFingerprint(caFile: string): string {
  const der = Buffer.from(readFileSync(caFile, "utf-8").replace(/-----[^-]+-----|\s/g, ""), "base64")
  return createHash("sha256").update(der).digest("base64").replace(/\+/g, "-").replace(/\//g, "_")
}

async function waitForServer(server: ChildProcess, kind: ServerKind, port: number): Promise<void> {
  const deadline = Date.now() + 15_000
  while (!(await canConnect(port))) {
    if (server.exitCode !== null || Date.now() > deadline) throw new Error(`${kind.name} did not start on port ${port}`)
    await new Promise(resolve => setTimeout(resolve, 100))
  }
}

function canConnect(port: number): Promise<boolean> {
  return new Promise(resolve => {
    const socket = createConnection({host: "localhost", port}, () => {
      socket.destroy()
      resolve(true)
    })
    socket.on("error", () => resolve(false))
  })
}
