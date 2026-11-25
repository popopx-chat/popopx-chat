//
//  PopopxMeshGroupOutbound.swift
//  PopopxMeshKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  The group send side as a protocol, for the same reason `PopopxMeshOutbound` exists: module 7's UI
//  and this package's tests drive it with a fake instead of a radio. `PopopxMeshEngine` conforms.
//
//  Note what is *not* here: no method returns "delivered". An invite that left the radio and went
//  unanswered is an ACK timeout, which module 4 owns for envelope traffic; group state is not
//  acknowledged, so the honest contract is "the frame was handed to Bluetooth or it was not", and
//  `.deliveryFailed` names the peers for whom it was not.
//

import Foundation

public protocol PopopxMeshGroupOutbound: Sendable {
    /// Creates a group at epoch 1 with this device as sole member and creator. Local-only until the
    /// first invite: nothing has been put on the radio yet.
    func createGroup(named name: String) async throws(PopopxMeshGroupError) -> PopopxMeshGroup

    /// Groups this device holds a usable key for.
    func meshGroups() async -> [PopopxMeshGroup]

    /// Members as the creator last signed them, for a roster sheet.
    func meshGroupMembers(of groupID: Data) async -> [PopopxMeshGroupMember]

    /// Invites one existing peer. Rotates the key, advances the epoch, signs the new roster and puts
    /// each recipient's copy on the radio 1:1 over its Noise session. Throws `.deliveryFailed` after
    /// the local rotation for a peer the radio could not take — the roster has moved and cannot be
    /// moved back, so the failure is reported rather than undone.
    func invite(
        peerMeshPublicKeyHex: String,
        toGroupID groupID: Data
    ) async throws(PopopxMeshGroupError) -> PopopxGroupDistribution

    /// Creator-side removal, same shape as an invite: the remaining members get the new key, the
    /// removee gets a notice that cannot decrypt anything.
    func removeMeshGroupMember(
        _ peerMeshPublicKeyHex: String,
        fromGroupID groupID: Data
    ) async throws(PopopxMeshGroupError) -> PopopxGroupDistribution

    /// Seals one message under the group's current epoch and floods it.
    func sendGroupMessage(_ text: String, toGroupID groupID: Data) async throws(PopopxMeshGroupError)

    /// Our Ed25519 public key hex, i.e. the roster row other members see for us.
    var localSigningPublicKeyHex: String? { get async }

    /// Peers whose signing key this device has heard, and which can therefore be invited at all.
    func invitableMeshPeers() async -> [String]
}
