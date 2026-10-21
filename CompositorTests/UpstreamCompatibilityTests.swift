import Foundation
import Testing
@testable import Compositor

struct UpstreamCompatibilityTests {
    @Test func cameraRawResourcesLoadFromTheAppBundle() throws {
        _ = try #require(CameraRawTables.tables)
        _ = try #require(CameraRawShadows.tables)
    }

    @Test func shadowsInterpolateThroughZeroAndClampAtEndpoints() {
        let tables = CameraRawShadows.Tables(normalFrom: 1020, amounts: [-100, 100],
            coefficients: [[[-2, -4, -6], [2, 4, 6]]], xCount: 1, kCount: 1,
            xLow: 0, xStep: 1, kLow: 0, kStep: 1)
        #expect(CameraRawShadows.coefficients(for: -200, set: 0, in: tables) == [-2, -4, -6])
        #expect(CameraRawShadows.coefficients(for: -50, set: 0, in: tables) == [-1, -2, -3])
        #expect(CameraRawShadows.coefficients(for: 0, set: 0, in: tables) == [0, 0, 0])
        #expect(CameraRawShadows.coefficients(for: 50, set: 0, in: tables) == [1, 2, 3])
        #expect(CameraRawShadows.coefficients(for: 200, set: 0, in: tables) == [2, 4, 6])
    }
}
