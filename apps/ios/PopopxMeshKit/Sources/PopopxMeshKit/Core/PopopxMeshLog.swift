//
//  PopopxMeshLog.swift
//  PopopxMeshKit
//

import Foundation
import os

public enum PopopxMeshLog {
    private static let subsystem = "chat.popopx.mesh"

    public static let ble = Logger(subsystem: subsystem, category: "ble")
    public static let noise = Logger(subsystem: subsystem, category: "noise")
    public static let route = Logger(subsystem: subsystem, category: "route")
    public static let pairing = Logger(subsystem: subsystem, category: "pairing")
    public static let store = Logger(subsystem: subsystem, category: "store")
    public static let health = Logger(subsystem: subsystem, category: "health")
    public static let offline = Logger(subsystem: subsystem, category: "offline")
}
