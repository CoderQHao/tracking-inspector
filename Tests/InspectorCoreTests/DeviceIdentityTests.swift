//
//  DeviceIdentityTests.swift
//  InspectorCoreTests
//
//  Created by DongQing on 2026/9/20.
//  Copyright © 2026 DongQing. All rights reserved.
//

import InspectorCore
import Testing

struct DeviceIdentityTests {
    let first = "D3AC3C42-20AA-450E-B962-5F6F4CDF4D25"
    let second = "6E4CA9CD-EC10-48C2-A151-07A9B4845141"

    @Test func authenticatedAliasesMergeAcrossSessionsAndSeparateApps() throws {
        var registry = DeviceIdentity()
        let a: [String: Any] = ["deviceID": first, "session": "one", "app": ["bundleID": "sample.app"]]
        let b: [String: Any] = ["deviceID": first, "session": "two", "app": ["bundleID": "sample.app"]]
        let group = try registry.identify("usb:serial", snapshot: a)
        #expect(try registry.identify("manual:address", snapshot: b) == group)
        #expect(registry.endpoints(for: group).count == 2)
        #expect(try DeviceIdentity.identifier(["deviceID": first, "session": "one", "app": ["bundleID": "other.app"]]) != group)
    }

    @Test func reusedAddressMovesToNewDevice() throws {
        var registry = DeviceIdentity()
        let old = try registry.identify("address", snapshot: ["deviceID": first])
        let new = try registry.identify("address", snapshot: ["deviceID": second])
        #expect(old != new)
        #expect(registry.endpoints(for: old).isEmpty)
        #expect(registry.group(for: "address") == new)
        registry.forget("address")
        #expect(registry.group(for: "address") == "address")
    }

    @Test func legacySessionsMergeWithoutTrustingDeviceNames() throws {
        var registry = DeviceIdentity()
        let a = try registry.identify("usb", snapshot: ["session": "one"])
        #expect(try registry.identify("bonjour", snapshot: ["session": "one"]) == a)
        #expect(try registry.identify("other", snapshot: ["session": "two"]) != a)
        #expect(throws: InspectorFailure.self) { try DeviceIdentity.identifier(["name": "same name"]) }
    }
}
