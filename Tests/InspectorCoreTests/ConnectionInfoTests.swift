//
//  ConnectionInfoTests.swift
//  InspectorCoreTests
//
//  Created by DongQing on 2026/9/20.
//  Copyright © 2026 DongQing. All rights reserved.
//

import Foundation
import InspectorCore
import Testing

private let validInfo = "TRACKING-INSPECTOR/1\n" + #"{"address":"192.168.20.30:54321","pairingCode":"00112233445566778899aabbccddeeff"}"#

@Test func acceptsPhoneConnectionInfoAndClipboardLineEndings() throws {
    for text in [validInfo, " \n" + validInfo + "\n", validInfo.replacingOccurrences(of: "\n", with: "\r\n")] {
        let info = try ConnectionInfo(text)
        #expect(info.address.address == "192.168.20.30:54321")
        #expect(info.pairingCode == "00112233445566778899aabbccddeeff")
    }
}

@Test(arguments: [
    "", "192.168.20.30:54321", "00112233445566778899aabbccddeeff",
    validInfo.replacingOccurrences(of: "/1", with: "/2"),
    validInfo.replacingOccurrences(of: "192.168.20.30:54321", with: "https://example.com"),
    validInfo.replacingOccurrences(of: "00112233445566778899aabbccddeeff", with: "bad-key"),
    "TRACKING-INSPECTOR/1\n{}", validInfo + "unrelated text", String(repeating: "x", count: 4097),
])
func rejectsInvalidConnectionInfoWithoutEchoingClipboard(_ text: String) {
    do {
        _ = try ConnectionInfo(text)
        Issue.record("Invalid connection information was accepted")
    } catch {
        #expect(!error.localizedDescription.contains("00112233445566778899aabbccddeeff"))
        #expect(!error.localizedDescription.contains("bad-key"))
    }
}
