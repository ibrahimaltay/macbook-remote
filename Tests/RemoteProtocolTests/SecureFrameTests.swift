import Foundation
import XCTest

@testable import RemoteProtocol

final class SecureFrameTests: XCTestCase {
    private func assertError(
        _ expected: SecureWireError, file: StaticString = #filePath, line: UInt = #line,
        _ action: () throws -> Void
    ) {
        XCTAssertThrowsError(try action(), file: file, line: line) {
            XCTAssertEqual($0 as? SecureWireError, expected, file: file, line: line)
        }
    }

    func testBinaryHeaderAndMinimumMTUWithSlices() throws {
        let data = Data([99, 98, 10, 11, 12, 13, 14]).dropFirst(2)
        let frames = try SecureFrame.fragment(data, kind: .clientHello, id: 0x0102030405060708, mtu: 20)
        XCTAssertEqual(frames, [
            Data([0xA7, 2, 1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 0, 5, 0, 0, 10, 11, 12, 13]),
            Data([0xA7, 2, 1, 1, 1, 2, 3, 4, 5, 6, 7, 8, 0, 5, 0, 4, 14]),
        ])
        var assembler = SecureFrameAssembler()
        XCTAssertNil(try assembler.accept((Data([99]) + frames[0]).dropFirst(), now: 0))
        let complete = try XCTUnwrap(assembler.accept((Data([99]) + frames[1]).dropFirst(), now: 1))
        XCTAssertEqual(complete.kind, .clientHello)
        XCTAssertEqual(complete.id, 0x0102030405060708)
        XCTAssertEqual(complete.data, data)
    }

    func testAllKindsAtTheirBounds() throws {
        for kind in [SecureFrameKind.clientHello, .serverHello, .clientFinish, .encryptedControl, .encryptedInput] {
            let limit = kind.rawValue <= 3 ? 1024 : 8192
            let data = Data(repeating: 0xAB, count: limit)
            let frames = try SecureFrame.fragment(data, kind: kind, id: .max, mtu: 20)
            var assembler = SecureFrameAssembler()
            for frame in frames.dropLast() {
                XCTAssertEqual(frame.count, 20)
                XCTAssertNil(try assembler.accept(frame, now: 0))
            }
            let complete = try XCTUnwrap(assembler.accept(try XCTUnwrap(frames.last), now: 0))
            XCTAssertEqual(complete.kind, kind)
            XCTAssertEqual(complete.id, .max)
            XCTAssertEqual(complete.data, data)
            assertError(.oversized) {
                _ = try SecureFrame.fragment(data + Data([0]), kind: kind, id: 0, mtu: 20)
            }
            var oversized = [UInt8](frames[0])
            oversized[12] = UInt8((limit + 1) >> 8)
            oversized[13] = UInt8((limit + 1) & 0xFF)
            assertError(.oversized) { _ = try assembler.accept(Data(oversized), now: 0) }
        }
    }

    func testFragmentArgumentsAndSingleFragment() throws {
        assertError(.malformed) {
            _ = try SecureFrame.fragment(Data(), kind: .clientHello, id: 0, mtu: 20)
        }
        assertError(.malformed) {
            _ = try SecureFrame.fragment(Data([1]), kind: .clientHello, id: 0, mtu: 19)
        }
        let frame = try XCTUnwrap(SecureFrame.fragment(Data([42]), kind: .encryptedInput, id: 0, mtu: .max).first)
        var assembler = SecureFrameAssembler()
        for _ in 0..<2 {
            XCTAssertEqual(try assembler.accept(frame, now: 0)?.data, Data([42]))
        }
    }

    func testMalformedHeadersAndFinalFlagsClearState() throws {
        let frames = try SecureFrame.fragment(Data(repeating: 7, count: 8), kind: .clientHello, id: 1, mtu: 20)
        var invalidFrames = [Data(), Data([0, 1]), Data(frames[0].prefix(16))]
        for (index, value) in [(0, 0), (1, 1), (2, 0), (2, 6), (3, 2), (3, 1), (12, 1), (13, 0), (14, 1)] {
            var bytes = [UInt8](frames[0])
            bytes[index] = UInt8(value)
            invalidFrames.append(Data(bytes))
        }
        var missingFinal = [UInt8](frames[1])
        missingFinal[3] = 0
        invalidFrames.append(Data(missingFinal))
        invalidFrames.append(frames[1] + Data([7]))
        for invalid in invalidFrames {
            var assembler = SecureFrameAssembler()
            XCTAssertNil(try assembler.accept(frames[0], now: 0))
            assertError(.malformed) { _ = try assembler.accept(invalid, now: 1) }
            XCTAssertNil(try assembler.accept(frames[0], now: 2))
            XCTAssertNotNil(try assembler.accept(frames[1], now: 3))
        }
    }

    func testRejectsOrderDuplicatesOverlapAndReplacement() throws {
        let frames = try SecureFrame.fragment(Data(repeating: 3, count: 12), kind: .encryptedControl, id: 4, mtu: 20)
        var assembler = SecureFrameAssembler()
        assertError(.malformed) { _ = try assembler.accept(frames[1], now: 0) }
        var invalidFrames = [frames[0], frames[2]]
        for (index, value) in [(2, 5), (11, 5), (13, 13), (15, 2)] {
            var bytes = [UInt8](frames[1])
            bytes[index] = UInt8(value)
            invalidFrames.append(Data(bytes))
        }
        invalidFrames.append(try XCTUnwrap(SecureFrame.fragment(Data([1]), kind: .clientHello, id: 9, mtu: 20).first))
        for invalid in invalidFrames {
            XCTAssertNil(try assembler.accept(frames[0], now: 0))
            assertError(.malformed) { _ = try assembler.accept(invalid, now: 1) }
            XCTAssertNil(try assembler.accept(frames[0], now: 2))
            assembler.reset()
        }
    }

    func testIdleAndTotalExpiryClearState() throws {
        let frames = try SecureFrame.fragment(Data(repeating: 1, count: 24), kind: .serverHello, id: 2, mtu: 20)
        var assembler = SecureFrameAssembler()
        XCTAssertNil(try assembler.accept(frames[0], now: 0))
        assertError(.expired) { _ = try assembler.accept(frames[1], now: 10) }
        XCTAssertNil(try assembler.accept(frames[0], now: 20))
        assembler.reset()
        for (index, time) in [0.0, 8, 16, 24, 29].enumerated() {
            XCTAssertNil(try assembler.accept(frames[index], now: time))
        }
        assertError(.expired) { _ = try assembler.accept(frames[5], now: 30) }
        XCTAssertNil(try assembler.accept(frames[0], now: 31))
        assembler.reset()
        for (index, time) in [0.0, 9, 18, 27, 28, 29].enumerated() {
            let result = try assembler.accept(frames[index], now: time)
            XCTAssertEqual(result != nil, index == 5)
        }
    }

    func testOversizedAndInvalidTimeAlsoClearState() throws {
        let frames = try SecureFrame.fragment(Data(repeating: 1, count: 8), kind: .clientFinish, id: 1, mtu: 20)
        var oversized = [UInt8](frames[1])
        oversized[12] = 5
        for time in [TimeInterval.nan, .infinity, -.infinity] {
            var assembler = SecureFrameAssembler()
            XCTAssertNil(try assembler.accept(frames[0], now: 0))
            assertError(.malformed) { _ = try assembler.accept(frames[1], now: time) }
            XCTAssertNil(try assembler.accept(frames[0], now: 1))
            assertError(.oversized) { _ = try assembler.accept(Data(oversized), now: 2) }
            XCTAssertNil(try assembler.accept(frames[0], now: 3))
            XCTAssertNotNil(try assembler.accept(frames[1], now: 4))
        }
    }
}