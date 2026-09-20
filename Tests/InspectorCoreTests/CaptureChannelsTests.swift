//
//  CaptureChannelsTests.swift
//  InspectorCoreTests
//
//  Created by DongQing on 2026/9/20.
//  Copyright © 2026 DongQing. All rights reserved.
//

@testable import InspectorCore
import Testing

@Test func deviceGenerationsAreIndependent() throws {
    var channels = CaptureChannels()
    try channels.enable("a")
    try channels.enable("b")
    let a = try #require(channels.generations["a"])
    let b = try #require(channels.generations["b"])
    channels.renew("a")
    #expect(!channels.accepts("a", generation: a))
    #expect(channels.accepts("b", generation: b))
    let paired = try #require(channels.generations["a"])
    channels.disable("a")
    try channels.enable("a")
    #expect(!channels.accepts("a", generation: paired))
    #expect(channels.accepts("b", generation: b))
}

@Test func enablingIsIdempotentAndConnectionsAreBounded() throws {
    var channels = CaptureChannels()
    for id in 0 ..< CaptureChannels.limit {
        try channels.enable(String(id))
    }
    let first = channels.generations["0"]
    try channels.enable("0")
    #expect(channels.generations["0"] == first)
    #expect(throws: InspectorFailure.self) { try channels.enable("overflow") }
    channels.disable("0")
    try channels.enable("replacement")
    #expect(channels.generations.count == CaptureChannels.limit)
    #expect(try !channels.accepts("0", generation: #require(first)))
}
