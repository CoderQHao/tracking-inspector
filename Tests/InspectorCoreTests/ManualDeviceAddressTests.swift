//
//  ManualDeviceAddressTests.swift
//  InspectorCoreTests
//
//  Created by DongQing on 2026/9/20.
//  Copyright © 2026 DongQing. All rights reserved.
//

@testable import InspectorCore
import Testing

@Test func explicitAddressPreservesHostAndPort() throws {
    let address = try ManualDeviceAddress(" 192.168.20.30:54321\n")
    #expect(address.host == "192.168.20.30")
    #expect(address.port == 54321)
    #expect(address.id == "manual:192.168.20.30:54321")
    #expect(try ManualDeviceAddress(address.address) == address)
}

@Test(arguments: ["", "192.168.1.2", "192.168.1.2:0", "192.168.1.2:65536", "192.168.1.2:-1", "999.1.1.1:42", "127.1:42", "host.local:42", "http://192.168.1.2:42", "192.168.1.2:42/path", "user@192.168.1.2:42", "192.168.1.2:42:43"])
func rejectsAmbiguousOrInvalidManualAddresses(_ input: String) {
    #expect(throws: InspectorFailure.self) { try ManualDeviceAddress(input) }
}
