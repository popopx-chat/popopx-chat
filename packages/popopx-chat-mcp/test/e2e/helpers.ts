import {T} from "@simplex-chat/types"
import {api, bot} from "simplex-chat"
import {RunningServer, ServeOptions, startServer} from "../../src/serve"
import {markRelayFailure} from "./smpServer"

export const timeout = 60_000

export function captureLog(): string[] {
  const lines: string[] = []
  const write = process.stdout.write.bind(process.stdout) as (chunk: string) => boolean
  jest.spyOn(process.stdout, "write").mockImplementation(((chunk: string) => {
    lines.push(...String(chunk).split("\n"))
    return write(chunk)
  }) as typeof process.stdout.write)
  return lines
}

// jest reports only Error.message, while the core's ChatError travels on the chatError property -
// so any call that can answer with a chat error has to be awaited through here, or CI shows the
// SDK's generic message and the reason is lost.
export async function withChatError<T>(run: () => Promise<T>): Promise<T> {
  try {
    return await run()
  } catch (e) {
    const err = e as Error & {chatError?: unknown}
    if (err.chatError !== undefined) err.message = `${err.message}: ${JSON.stringify(err.chatError)}`
    markRelayFailure()
    throw err
  }
}

export async function profileWithServer(smpAddress: string, filePrefix: string, profile: T.Profile, xftpAddress?: string): Promise<void> {
  const chat = await api.ChatApi.init({type: "sqlite", filePrefix})
  await chat.apiCreateActiveUser(profile)
  await chat.startChat()
  expect(await withChatError(() => chat.sendChatCmd(`/smp ${smpAddress}`))).toMatchObject({type: "cmdOk"})
  if (xftpAddress !== undefined) expect(await withChatError(() => chat.sendChatCmd(`/xftp ${xftpAddress}`))).toMatchObject({type: "cmdOk"})
  await chat.close()
}

export async function person(smpAddress: string, filePrefix: string, displayName: string, xftpAddress?: string): Promise<{chat: api.ChatApi; user: T.User}> {
  await profileWithServer(smpAddress, filePrefix, {displayName, fullName: ""}, xftpAddress)
  const chat = await api.ChatApi.init({type: "sqlite", filePrefix})
  const user = (await chat.apiGetActiveUser())!
  await chat.startChat()
  return {chat, user}
}

export interface Bot {
  chat: api.ChatApi
  user: T.User
  link: string
}

export async function startBot(smpAddress: string, filePrefix: string, displayName: string, addressSettings: api.BotAddressSettings): Promise<Bot> {
  await profileWithServer(smpAddress, filePrefix, {displayName, fullName: "", peerType: T.ChatPeerType.Bot})
  // bot.run registers the address on the relay, so it answers with a chat error when that fails.
  const [chat, user, address] = await withChatError(() => bot.run({
    profile: {displayName, fullName: "", shortDescr: "Find groups and bots."},
    dbOpts: {type: "sqlite", filePrefix},
    options: {addressSettings, commands: [{type: "command", keyword: "help", label: "Help"}], logContacts: false},
    onMessage: async (ci, content, botChat) => {
      await botChat.apiSendTextReply(ci, `result 1: ${content.text}`)
      await botChat.apiSendTextReply(ci, `result 2: ${content.text}`)
    },
    onCommands: {
      help: async (ci, _command, botChat) => {
        await botChat.apiSendTextReply(ci, "Send a search, for example: trail shoes")
      },
    },
  }))
  return {chat, user, link: address!.connLinkContact.connShortLink ?? address!.connLinkContact.connFullLink}
}

export function serveOptions(data: string, port: number, extra: Partial<ServeOptions> = {}): ServeOptions {
  return {name: "agent", data, dataGiven: true, approve: "requests", expireHours: 23, resetOwners: false, newToken: false, port, qrCode: "small", stopWait: 10, ...extra}
}

export function startAgentServer(options: ServeOptions): Promise<RunningServer> {
  return withChatError(() => startServer(options))
}

export function lastLink(lines: string[]): string {
  return lines.filter(line => /^(https:\/\/|simplex:)/.test(line)).at(-1)!
}

export async function joinByLink({chat, user}: {chat: api.ChatApi; user: T.User}, link: string): Promise<number> {
  const joined = chat.wait("userJoinedGroup", timeout)
  const [, connLink] = await withChatError(() => chat.apiConnectPlan(user.userId, link))
  await withChatError(() => chat.apiConnect(user.userId, false, connLink))
  const event = await joined
  if (event === undefined) {
    markRelayFailure()
    throw new Error("not joined")
  }
  return event.groupInfo.groupId
}

export async function until(condition: () => boolean | Promise<boolean>, ms = timeout): Promise<void> {
  const deadline = Date.now() + ms
  while (!(await condition())) {
    if (Date.now() > deadline) {
      markRelayFailure()
      throw new Error("condition timed out")
    }
    await new Promise(resolve => setTimeout(resolve, 100))
  }
}

export type ItemCheck = (ci: T.AChatItem) => boolean

export function received(chat: api.ChatApi, check: ItemCheck): Promise<T.AChatItem> {
  return chat.wait("newChatItems", ({chatItems}) => chatItems.some(check), timeout).then(event => {
    if (event === undefined) {
      markRelayFailure()
      throw new Error("no matching item")
    }
    return event.chatItems.find(check)!
  })
}

export function updated(chat: api.ChatApi, check: ItemCheck): Promise<T.AChatItem> {
  return chat.wait("chatItemUpdated", ({chatItem}) => check(chatItem), timeout).then(event => {
    if (event === undefined) {
      markRelayFailure()
      throw new Error("no matching update")
    }
    return event.chatItem
  })
}

// A wait that times out resolves to undefined, and "expected undefined to be defined" names no event and
// implicates nothing - this says which event never arrived and marks it, so the relay log survives cleanup.
export async function expectEvent(event: Promise<unknown>, name: string): Promise<void> {
  if (await event === undefined) {
    markRelayFailure()
    throw new Error(`no ${name} event`)
  }
}

export const textStarts = (prefix: string): ItemCheck => ci => ci.chatItem.meta.itemText.startsWith(prefix)

export function cardNumber(ci: T.AChatItem): number {
  return Number(/\/'(?:approve|receive) (?:[#@]\d+ )?(\d+)'/.exec(ci.chatItem.meta.itemText)![1])
}

export function lines(ci: T.AChatItem): string[] {
  return ci.chatItem.meta.itemText.split("\n")
}

export function isActive({memberStatus}: T.GroupMember): boolean {
  return memberStatus === T.GroupMemberStatus.Connected || memberStatus === T.GroupMemberStatus.Complete
}

export async function controlGroupOf(chat: api.ChatApi, userId: number): Promise<T.GroupInfo> {
  return (await chat.apiListGroups(userId)).find(({customData}) => (customData as {simplexMcp?: {control?: boolean}} | undefined)?.simplexMcp?.control === true)!
}
