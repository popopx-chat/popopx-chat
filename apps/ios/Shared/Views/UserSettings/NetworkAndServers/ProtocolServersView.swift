//
//  ProtocolServersView.swift
//  POPOPX (iOS)
//
//  Created by Evgeny on 15/11/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//  Modifications Copyright © 2026 POPOPX Chat.
//
// Spec: spec/architecture.md

import SwiftUI
import POPOPXChat

private let howToUrl = URL(string: "https://popopx.chat/docs/server.html")!

struct YourServersView: View {
    @Environment(\.dismiss) var dismiss: DismissAction
    @EnvironmentObject private var m: ChatModel
    @EnvironmentObject var theme: AppTheme
    @Environment(\.editMode) private var editMode
    @Binding var userServers: [UserOperatorServers]
    @Binding var serverErrors: [UserServersError]
    @Binding var serverWarnings: [UserServersWarning]
    var operatorIndex: Int
    @State private var showAddServer = false
    @State private var newServerNavLinkActive = false
    @State private var newChatRelayNavLinkActive = false
    @State private var showScanProtoServer = false
    @State private var testing = false

    var body: some View {
        yourServersView()
            .opacity(testing ? 0.4 : 1)
            .overlay {
                if testing {
                    ProgressView()
                        .scaleEffect(2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .allowsHitTesting(!testing)
            .navigationDestination(isPresented: $newChatRelayNavLinkActive) {
                NewChatRelayView(userServers: $userServers, serverErrors: $serverErrors, serverWarnings: $serverWarnings)
                    .navigationTitle("New chat relay")
                    .navigationBarTitleDisplayMode(.large)
                    .modifier(ThemedBackground(grouped: true))
            }
            .navigationDestination(isPresented: $newServerNavLinkActive) {
                newServerDestinationView()
            }
    }

    private func yourServersView() -> some View {
        let duplicateHosts = findDuplicateHosts(serverErrors)
        let duplicateRelayAddresses = findDuplicateRelayAddresses(serverErrors)
        return List {
            if !userServers[operatorIndex].chatRelays.filter({ !$0.deleted }).isEmpty {
                Section {
                    ForEach(bindingForChatRelays($userServers, operatorIndex)) { relay in
                        if !relay.wrappedValue.deleted {
                            ChatRelayViewLink(
                                relay: relay,
                                duplicateRelayAddresses: duplicateRelayAddresses
                            )
                        } else { EmptyView() }
                    }
                    .onDelete { indexSet in
                        deleteChatRelay($userServers, operatorIndex, indexSet)
                        validateServers_($userServers, $serverErrors, $serverWarnings)
                    }
                } header: {
                    Text("Chat relays").foregroundColor(theme.colors.secondary)
                } footer: {
                    Text("Chat relays forward messages in channels you create.").foregroundColor(theme.colors.secondary)
                }
            }

            if !userServers[operatorIndex].smpServers.filter({ !$0.deleted }).isEmpty {
                Section {
                    ForEach($userServers[operatorIndex].smpServers) { srv in
                        if !srv.wrappedValue.deleted {
                            ProtocolServerViewLink(
                                duplicateHosts: duplicateHosts,
                                server: srv,
                                serverProtocol: .smp
                            )
                        } else {
                            EmptyView()
                        }
                    }
                    .onDelete { indexSet in
                        deleteSMPServer($userServers, operatorIndex, indexSet)
                        validateServers_($userServers, $serverErrors, $serverWarnings)
                    }
                } header: {
                    Text("Message servers")
                        .foregroundColor(theme.colors.secondary)
                } footer: {
                    if let errStr = globalSMPServersError(serverErrors) {
                        ServersErrorView(errStr: errStr)
                    } else {
                        Text("The servers for new connections of your current chat profile **\(m.currentUser?.displayName ?? "")**.")
                            .foregroundColor(theme.colors.secondary)
                            .lineLimit(10)
                    }
                }
            }

            if !userServers[operatorIndex].xftpServers.filter({ !$0.deleted }).isEmpty {
                Section {
                    ForEach($userServers[operatorIndex].xftpServers) { srv in
                        if !srv.wrappedValue.deleted {
                            ProtocolServerViewLink(
                                duplicateHosts: duplicateHosts,
                                server: srv,
                                serverProtocol: .xftp
                            )
                        } else {
                            EmptyView()
                        }
                    }
                    .onDelete { indexSet in
                        deleteXFTPServer($userServers, operatorIndex, indexSet)
                        validateServers_($userServers, $serverErrors, $serverWarnings)
                    }
                } header: {
                    Text("Media & file servers")
                        .foregroundColor(theme.colors.secondary)
                } footer: {
                    if let errStr = globalXFTPServersError(serverErrors) {
                        ServersErrorView(errStr: errStr)
                    } else {
                        Text("The servers for new files of your current chat profile **\(m.currentUser?.displayName ?? "")**.")
                            .foregroundColor(theme.colors.secondary)
                            .lineLimit(10)
                    }
                }
            }

            Section {
                Button("Add server") {
                    showAddServer = true
                }
            } footer: {
                let errs = globalServersErrors(serverErrors)
                let warns = globalServersWarnings(serverWarnings)
                if !errs.isEmpty {
                    ForEach(errs, id: \.self) { err in
                        ServersErrorView(errStr: err)
                    }
                } else if !warns.isEmpty {
                    ForEach(warns, id: \.self) { warn in
                        ServersWarningView(warnStr: warn)
                    }
                }
            }

            Section {
                TestServersButton(
                    smpServers: $userServers[operatorIndex].smpServers,
                    xftpServers: $userServers[operatorIndex].xftpServers,
                    chatRelays: $userServers[operatorIndex].chatRelays,
                    testing: $testing
                )
                howToButton()
            }
        }
        .toolbar {
            if (
                !userServers[operatorIndex].smpServers.filter({ !$0.deleted }).isEmpty ||
                !userServers[operatorIndex].xftpServers.filter({ !$0.deleted }).isEmpty ||
                !userServers[operatorIndex].chatRelays.filter({ !$0.deleted }).isEmpty
            ) {
                EditButton()
            }
        }
        .confirmationDialog("Add server", isPresented: $showAddServer, titleVisibility: .hidden) {
            Button("Enter server manually") { newServerNavLinkActive = true }
            Button("Scan server QR code") { showScanProtoServer = true }
            Button("Chat relay") { newChatRelayNavLinkActive = true }
        }
        .sheet(isPresented: $showScanProtoServer) {
            ScanProtocolServer(
                userServers: $userServers,
                serverErrors: $serverErrors,
                serverWarnings: $serverWarnings
            )
            .modifier(ThemedBackground(grouped: true))
        }
    }

    private func newServerDestinationView() -> some View {
        NewServerView(
            userServers: $userServers,
            serverErrors: $serverErrors,
            serverWarnings: $serverWarnings
        )
        .navigationTitle("New server")
        .navigationBarTitleDisplayMode(.large)
        .modifier(ThemedBackground(grouped: true))
    }

    func howToButton() -> some View {
        Button {
            openExternalLink(howToUrl)
        } label: {
            HStack {
                Text("How to use your servers")
                Image(systemName: "arrow.up.right.circle")
            }
        }
    }
}

struct ProtocolServerViewLink: View {
    @EnvironmentObject var theme: AppTheme
    var duplicateHosts: Set<String>
    @Binding var server: UserServer
    var serverProtocol: ServerProtocol

    var body: some View {
        NavigationLink(value: ProtocolServerSelection(serverId: server.id, serverProtocol: serverProtocol)) {
            let address = parseServerAddress(server.server)
            HStack {
                Group {
                    if let address = address {
                        if !address.valid || address.serverProtocol != serverProtocol {
                            invalidServer()
                        } else if address.hostnames.contains(where: duplicateHosts.contains) {
                            Image(systemName: "exclamationmark.circle").foregroundColor(.red)
                        } else if !server.enabled {
                            Image(systemName: "slash.circle").foregroundColor(theme.colors.secondary)
                        } else {
                            showTestStatus(server: server)
                        }
                    } else {
                        invalidServer()
                    }
                }
                .frame(width: 16, alignment: .center)
                .padding(.trailing, 4)

                let v = Text(address?.hostnames.first ?? server.server).lineLimit(1)
                if server.enabled {
                    v
                } else {
                    v.foregroundColor(theme.colors.secondary)
                }
            }
        }
    }

    private func invalidServer() -> some View {
        Image(systemName: "exclamationmark.circle").foregroundColor(.red)
    }
}

struct ProtocolServerSelection: Hashable {
    var serverId: String
    var serverProtocol: ServerProtocol
}

func userServerBinding(_ userServers: Binding<[UserOperatorServers]>, _ sel: ProtocolServerSelection) -> Binding<UserServer>? {
    for (op, group) in userServers.wrappedValue.enumerated() {
        switch sel.serverProtocol {
        case .smp:
            if let i = group.smpServers.firstIndex(where: { $0.id == sel.serverId }) { return userServers[op].smpServers[i] }
        case .xftp:
            if let i = group.xftpServers.firstIndex(where: { $0.id == sel.serverId }) { return userServers[op].xftpServers[i] }
        }
    }
    return nil
}

@ViewBuilder func protocolServerDestination(
    _ sel: ProtocolServerSelection,
    userServers: Binding<[UserOperatorServers]>,
    serverErrors: Binding<[UserServersError]>,
    serverWarnings: Binding<[UserServersWarning]>,
    backLabel: LocalizedStringKey
) -> some View {
    if let server = userServerBinding(userServers, sel) {
        ProtocolServerView(
            userServers: userServers,
            serverErrors: serverErrors,
            serverWarnings: serverWarnings,
            server: server,
            serverToEdit: server.wrappedValue,
            backLabel: backLabel
        )
        .navigationBarTitle("\(sel.serverProtocol.rawValue.uppercased()) server")
        .modifier(ThemedBackground(grouped: true))
        .navigationBarTitleDisplayMode(.large)
    }
}

// The destinations for these rows are declared on the NavigationStack that hosts NetworkAndServers,
// not on the page that shows them: SwiftUI keeps only the registration closest to the stack root for a
// given value type, so a per-page one is deduplicated away and the row taps resolve to nothing.

func protocolServerGroupIndex(_ userServers: [UserOperatorServers], _ sel: ProtocolServerSelection) -> Int? {
    for (idx, group) in userServers.enumerated() {
        switch sel.serverProtocol {
        case .smp:
            if group.smpServers.contains(where: { $0.id == sel.serverId }) { return idx }
        case .xftp:
            if group.xftpServers.contains(where: { $0.id == sel.serverId }) { return idx }
        }
    }
    return nil
}

func serversBackLabel(_ userServers: [UserOperatorServers], groupIndex: Int?) -> LocalizedStringKey {
    guard let idx = groupIndex, let serverOperator = userServers[idx].operator else { return "Your servers" }
    return "\(serverOperator.tradeName) servers"
}

@ViewBuilder func protocolServerDestination(
    _ sel: ProtocolServerSelection,
    servers: Binding<ServerSettings>
) -> some View {
    let groups = servers.wrappedValue.userServers
    protocolServerDestination(
        sel,
        userServers: servers.userServers,
        serverErrors: servers.serverErrors,
        serverWarnings: servers.serverWarnings,
        backLabel: serversBackLabel(groups, groupIndex: protocolServerGroupIndex(groups, sel))
    )
}

func deleteSMPServer(
    _ userServers: Binding<[UserOperatorServers]>,
    _ operatorServersIndex: Int,
    _ serverIndexSet: IndexSet
) {
    if let idx = serverIndexSet.first {
        let server = userServers[operatorServersIndex].wrappedValue.smpServers[idx]
        if server.serverId == nil {
            userServers[operatorServersIndex].wrappedValue.smpServers.remove(at: idx)
        } else {
            var updatedServer = server
            updatedServer.deleted = true
            userServers[operatorServersIndex].wrappedValue.smpServers[idx] = updatedServer
        }
    }
}

func deleteXFTPServer(
    _ userServers: Binding<[UserOperatorServers]>,
    _ operatorServersIndex: Int,
    _ serverIndexSet: IndexSet
) {
    if let idx = serverIndexSet.first {
        let server = userServers[operatorServersIndex].wrappedValue.xftpServers[idx]
        if server.serverId == nil {
            userServers[operatorServersIndex].wrappedValue.xftpServers.remove(at: idx)
        } else {
            var updatedServer = server
            updatedServer.deleted = true
            userServers[operatorServersIndex].wrappedValue.xftpServers[idx] = updatedServer
        }
    }
}

func deleteChatRelay(
    _ userServers: Binding<[UserOperatorServers]>,
    _ operatorServersIndex: Int,
    _ serverIndexSet: IndexSet
) {
    if let idx = serverIndexSet.first {
        let relay = userServers[operatorServersIndex].wrappedValue.chatRelays[idx]
        if relay.chatRelayId == nil {
            userServers[operatorServersIndex].wrappedValue.chatRelays.remove(at: idx)
        } else {
            var updatedRelay = relay
            updatedRelay.deleted = true
            userServers[operatorServersIndex].wrappedValue.chatRelays[idx] = updatedRelay
        }
    }
}

struct TestServersButton: View {
    @Binding var smpServers: [UserServer]
    @Binding var xftpServers: [UserServer]
    @Binding var chatRelays: [UserChatRelay]
    @Binding var testing: Bool

    var body: some View {
        Button("Test servers", action: testServers)
            .disabled(testing || allServersDisabled)
    }

    private var allServersDisabled: Bool {
        smpServers.allSatisfy { !$0.enabled } &&
        xftpServers.allSatisfy { !$0.enabled } &&
        chatRelays.filter({ !$0.deleted }).allSatisfy { !$0.enabled }
    }

    private func testServers() {
        resetTestStatus()
        testing = true
        Task {
            let rfs = await runRelaysTest()
            let sfs = await runServersTest()
            await MainActor.run {
                testing = false
                var failures: [String] = []
                failures += rfs.map { (name, f) in "\(name): \(f.localizedDescription)" }
                failures += sfs.map { (srv, f) in "\(srv): \(f.localizedDescription)" }
                if !failures.isEmpty {
                    let msg = failures.joined(separator: "\n")
                    showAlert(
                        NSLocalizedString("Tests failed!", comment: "alert title"),
                        message: String.localizedStringWithFormat(NSLocalizedString("Some servers failed the test:\n%@", comment: "alert message"), msg)
                    )
                }
            }
        }
    }

    private func resetTestStatus() {
        for i in 0..<chatRelays.count {
            if chatRelays[i].enabled && !chatRelays[i].deleted {
                chatRelays[i].tested = nil
            }
        }

        for i in 0..<smpServers.count {
            if smpServers[i].enabled {
                smpServers[i].tested = nil
            }
        }

        for i in 0..<xftpServers.count {
            if xftpServers[i].enabled {
                xftpServers[i].tested = nil
            }
        }
    }

    private func runServersTest() async -> [String: ProtocolTestFailure] {
        var fs: [String: ProtocolTestFailure] = [:]
        for i in 0..<smpServers.count {
            if smpServers[i].enabled {
                if let f = await testServerConnection(server: $smpServers[i]) {
                    fs[serverHostname(smpServers[i].server)] = f
                }
            }
        }

        for i in 0..<xftpServers.count {
            if xftpServers[i].enabled {
                if let f = await testServerConnection(server: $xftpServers[i]) {
                    fs[serverHostname(xftpServers[i].server)] = f
                }
            }
        }
        return fs
    }

    private func runRelaysTest() async -> [String: RelayTestFailure] {
        var fs: [String: RelayTestFailure] = [:]
        for i in 0..<chatRelays.count {
            if chatRelays[i].enabled && !chatRelays[i].deleted {
                if let f = await testRelayConnection(relay: $chatRelays[i]) {
                    let name = !chatRelays[i].displayName.isEmpty ? chatRelays[i].displayName : chatRelays[i].domains.first ?? chatRelays[i].address
                    fs[name] = f
                }
            }
        }
        return fs
    }
}

struct YourServersView_Previews: PreviewProvider {
    static var previews: some View {
        YourServersView(
            userServers: Binding.constant([UserOperatorServers.sampleDataNilOperator]),
            serverErrors: Binding.constant([]),
            serverWarnings: Binding.constant([]),
            operatorIndex: 0
        )
    }
}
