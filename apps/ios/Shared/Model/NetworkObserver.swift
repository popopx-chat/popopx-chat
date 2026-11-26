//
//  NetworkObserver.swift
//  POPOPX (iOS)
//
//  Created by Avently on 05.04.2024.
//  Copyright © 2024 SimpleX Chat. All rights reserved.
//  Modifications Copyright © 2026 POPOPX Chat.
//

import Foundation
import Network
import POPOPXChat
import PopopxMeshKit

class NetworkObserver {
    static let shared = NetworkObserver()
    private let queue: DispatchQueue = DispatchQueue(label: "com.popopxchat.popopx.NetworkObserver")
    private var prevInfo: UserNetworkInfo? = nil
    private var monitor: NWPathMonitor?
    private let monitorLock: DispatchQueue = DispatchQueue(label: "com.popopxchat.popopx.monitorLock")

    /// How long to let a new path settle before reconnecting. The interface is up before the route
    /// works: reconnecting on the same runloop turn usually fails, and the next edge would be later
    /// than this.
    private static let reconnectSettle: TimeInterval = 0.3

    func restartMonitor() {
        monitorLock.sync {
            monitor?.cancel()
            let mon = NWPathMonitor()
            mon.pathUpdateHandler = { [weak self] path in
                self?.networkPathChanged(path: path)
            }
            mon.start(queue: queue)
            monitor = mon
        }
    }

    private func networkPathChanged(path: NWPath) {
        let info = UserNetworkInfo(
            networkType: networkTypeFromPath(path),
            online: path.status == .satisfied
        )
        if (prevInfo != info) {
            let prev = prevInfo
            prevInfo = info
            setNetworkInfo(info)
            // A latency reading taken over Wi-Fi says nothing about cellular, so an interface change
            // voids the cache instead of letting the settings screen rank on the old route.
            if let prev, prev.networkType != info.networkType {
                Task { await PopopxRelayLatency.shared.invalidate() }
            }
            reconnectOnPathChange(from: prev, to: info)
        }
    }

    /// Reconnect the SMP/XFTP connections on an edge the agent cannot see for itself.
    ///
    /// The OS tears the sockets down when the interface changes; what the agent gets from this
    /// observer is only `setUserNetworkInfo`, which in the pinned core writes a TVar behind
    /// `userOfflineDelay` (Agent.hs:741-751) and reconnects nothing. `reconnectAllServers` is the
    /// command that actually redials (Agent.hs:753-757), so without this call a phone that moves
    /// Wi-Fi -> cellular waits for the ordinary retry timer while the UI already shows a network.
    ///
    /// Skipped for the very first reading — a starting app connects by itself, and reconnecting then
    /// would race its own initialisation — and for a transition to offline, where there is nothing to
    /// reconnect to.
    private func reconnectOnPathChange(from prev: UserNetworkInfo?, to info: UserNetworkInfo) {
        guard let prev, info.online else { return }
        guard !prev.online || prev.networkType != info.networkType else { return }
        queue.asyncAfter(deadline: .now() + Self.reconnectSettle) { [weak self] in
            self?.reconnectNow(expected: info)
        }
    }

    private func reconnectNow(expected: UserNetworkInfo) {
        // The path moved again while the route settled; that edge scheduled its own reconnect.
        guard prevInfo == expected, hasChatCtrl() else { return }
        Task {
            do {
                try await reconnectAllServers()
            } catch let err {
                // A failed redial is not worth an alert: the ordinary retry timer still runs. What it
                // is worth is a line in the log, because "it did not reconnect" is the question asked
                // of every user report about a network switch.
                logger.error("reconnectOnPathChange error: \(responseError(err))")
            }
        }
    }

    private func networkTypeFromPath(_ path: NWPath) -> UserNetworkType {
        if path.usesInterfaceType(.wiredEthernet) {
            .ethernet
        } else if path.usesInterfaceType(.wifi) {
            .wifi
        } else if path.usesInterfaceType(.cellular) {
            .cellular
        } else if path.usesInterfaceType(.other) {
            .other
        } else {
            .none
        }
    }

    private static var networkObserver: NetworkObserver? = nil

    private func setNetworkInfo(_ info: UserNetworkInfo) {
        logger.debug("setNetworkInfo Network changed: \(String(describing: info))")
        DispatchQueue.main.sync {
            ChatModel.shared.networkInfo = info
        }
        if !hasChatCtrl() { return }
        self.monitorLock.sync {
            do {
                try apiSetNetworkInfo(info)
            } catch let err {
                logger.error("setNetworkInfo error: \(responseError(err))")
            }
        }
    }
}
