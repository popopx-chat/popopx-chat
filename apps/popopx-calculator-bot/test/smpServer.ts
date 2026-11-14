import {ChildProcess, spawn} from "child_process"
import {createHash} from "crypto"
import {once} from "events"
import {copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync} from "fs"
import {AddressInfo, createConnection, createServer} from "net"
import {tmpdir} from "os"
import {dirname, join} from "path"

const tlsFixtures = join(__dirname, "../../../tests/fixtures/tls")
const smpServerRelease = "v7.1.0.17"
const releaseArch: Record<string, string | undefined> = {x64: "x86-64", arm64: "aarch64"}
// The digests GitHub recorded for the smp-server assets of that popopxmq release.
const smpServerDigests: Record<string, string> = {
  "x86-64": "554fffe2e65ef3df9b891158378baf70c41749b6c2faba606c45a8761fb25eb8",
  aarch64: "b2d57ed88308c18968cd9262add357e523a9b6e685314ef73fc085643c34c439",
}

export interface SmpServer {
  address: string
  stop: () => Promise<void>
}

export async function startSmpServer(): Promise<SmpServer> {
  const port = await freePort()
  const dir = mkdtempSync(join(tmpdir(), "smp-server-"))
  const configDir = join(dir, "config")
  mkdirSync(configDir)
  for (const file of ["ca.crt", "server.crt", "server.key"]) copyFileSync(join(tlsFixtures, file), join(configDir, file))
  const fingerprint = caFingerprint(join(configDir, "ca.crt"))
  writeFileSync(join(configDir, "fingerprint"), `${fingerprint}\n`)
  writeFileSync(join(configDir, "smp-server.ini"), `[STORE_LOG]\nenable: off\n\n[TRANSPORT]\nhost: localhost\nport: ${port}\nwebsockets: off\n`)
  const server = spawn(await smpServerExecutable(), ["start"], {
    env: {...process.env, SMP_SERVER_CFG_PATH: configDir, SMP_SERVER_LOG_PATH: join(dir, "logs")},
    stdio: ["ignore", "ignore", "inherit"],
  })
  const stop = async () => {
    if (server.exitCode === null) {
      const exited = once(server, "exit")
      server.kill()
      await exited
    }
    rmSync(dir, {recursive: true, force: true})
  }
  try {
    await once(server, "spawn")
    await waitForServer(server, port)
  } catch (e) {
    await stop()
    throw e
  }
  return {address: `smp://${fingerprint}@localhost:${port}`, stop}
}

async function smpServerExecutable(): Promise<string> {
  if (process.env.SMP_SERVER) return process.env.SMP_SERVER
  const path = join(__dirname, "../node_modules/.cache/smp-server", `smp-server-${smpServerRelease}`)
  if (!existsSync(path)) await downloadSmpServer(path)
  return path
}

async function downloadSmpServer(path: string): Promise<void> {
  const arch = releaseArch[process.arch]
  if (process.platform !== "linux" || !arch) {
    throw new Error(`smp-server release binaries are not available for ${process.platform} ${process.arch}, set SMP_SERVER to the smp-server path`)
  }
  // Pinned to a release of popopxmq itself: a 404 here means our own asset is missing, which is not a reason to fall back to upstream's binary
  const url = `https://github.com/popopx-chat/popopxmq/releases/download/${smpServerRelease}/smp-server-ubuntu-22_04-${arch}`
  const response = await fetch(url)
  if (!response.ok) throw new Error(`error downloading ${url}: ${response.status}`)
  const data = Buffer.from(await response.arrayBuffer())
  const digest = createHash("sha256").update(data).digest("hex")
  if (digest !== smpServerDigests[arch]) throw new Error(`smp-server-${arch} sha256 ${digest} does not match the pinned ${smpServerDigests[arch]}`)
  mkdirSync(dirname(path), {recursive: true})
  writeFileSync(`${path}.download`, data, {mode: 0o755})
  renameSync(`${path}.download`, path)
}

function caFingerprint(caFile: string): string {
  const der = Buffer.from(readFileSync(caFile, "utf-8").replace(/-----[^-]+-----|\s/g, ""), "base64")
  return createHash("sha256").update(der).digest("base64").replace(/\+/g, "-").replace(/\//g, "_")
}

function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const probe = createServer()
    probe.on("error", reject)
    probe.listen(0, "127.0.0.1", () => {
      const {port} = probe.address() as AddressInfo
      probe.close(() => resolve(port))
    })
  })
}

async function waitForServer(server: ChildProcess, port: number): Promise<void> {
  const deadline = Date.now() + 15_000
  while (!(await canConnect(port))) {
    if (server.exitCode !== null || Date.now() > deadline) throw new Error(`smp-server did not start on port ${port}`)
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
