//
//  BundledMLModelManagerTests.swift
//  pocket-tts-macosTests
//
//  Lifecycle tests for `BundledMLModelManager` that don't touch
//  the real HuggingFace endpoint, the user's container, or
//  Core ML compile. Strategy mirrors `DemucsModelManagerTests`:
//
//    1. Reuse `MockHTTPResponder` (declared at the bottom of
//       DemucsModelManagerTests.swift) to intercept the
//       manager's URLSession traffic with canned responses.
//    2. Per-test temp `baseDir` + `.fast` backoff so each test
//       takes < 1 s of wall clock.
//    3. Assert on observable post-conditions — isReady,
//       installed set membership, staging dir contents,
//       MockHTTPResponder.requestCount.
//
//  What we DON'T exercise here:
//
//    * The full download → unzip → MLModel.compileModel(at:) →
//      install path. The compile step requires a real
//      `.mlpackage` and ~3 s of wall clock per model; that
//      lives in a future parity test (mirrors
//      `DemucsSourceSeparatorParityTests`'s scope), gated on
//      the actual asset being present in the dev cache.
//    * Per-byte progress reporting — production code doesn't
//      wire it (no `URLSessionDownloadDelegate` yet) so there's
//      nothing to assert.

import XCTest
@testable import pocket_tts_macos

@MainActor
final class BundledMLModelManagerTests: XCTestCase {

    // MARK: - Per-test sandbox

    private var tempBase: URL!
    private var session: URLSession!

    override func setUp() async throws {
        try await super.setUp()
        tempBase = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BundledMLModelManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTPResponder.self]
        session = URLSession(configuration: config)

        MockHTTPResponder.reset()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempBase)
        MockHTTPResponder.reset()
        try await super.tearDown()
    }

    // MARK: - Readiness gate

    func test_freshManager_isNotReady() throws {
        let manager = BundledMLModelManager(
            urlSession: session,
            backoffPolicy: .none,
            baseDir: tempBase
        )
        XCTAssertFalse(manager.isReady,
                       "fresh manager with empty baseDir must not report ready")
        XCTAssertEqual(manager.installed.count, 0,
                       "installed set should be empty on a fresh dir")
        XCTAssertEqual(Set(manager.missing), Set(BundledMLModel.allCases),
                       "missing should list every required model")
    }

    func test_manager_isReadyWhenAllFourCompiledFoldersExist() throws {
        // Manually fake the post-install layout: one non-empty
        // `<model>.mlmodelc` folder per BundledMLModel under
        // `installed/<model>-v1/`. We're testing the disk-scan
        // logic, not the download pipeline — content of the
        // folder doesn't have to be a real Core ML build.
        for model in BundledMLModel.allCases {
            let folder = tempBase
                .appendingPathComponent("installed", isDirectory: true)
                .appendingPathComponent("\(model.rawValue)-v1", isDirectory: true)
                .appendingPathComponent("\(model.rawValue).mlmodelc", isDirectory: true)
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true
            )
            // Drop a placeholder file so the non-empty check
            // passes. An empty dir is intentionally treated as
            // "not installed" (see test_emptyFolder_doesNotCountAsInstalled).
            let placeholder = folder.appendingPathComponent("model.mlmodel")
            try Data().write(to: placeholder)
        }

        let manager = BundledMLModelManager(
            urlSession: session,
            backoffPolicy: .none,
            baseDir: tempBase
        )
        XCTAssertTrue(manager.isReady,
                      "manager with all four compiled folders must report ready")
        XCTAssertEqual(manager.installed.count, BundledMLModel.allCases.count,
                       "installed set should match the required catalog")
        XCTAssertTrue(manager.missing.isEmpty,
                      "missing must be empty when isReady is true")
    }

    func test_partialInstall_isReadyFalse() throws {
        // Install three of the four — the all-four AND should
        // still fail. Order doesn't matter; pick the first three.
        let installedCases = Array(BundledMLModel.allCases.prefix(3))
        for model in installedCases {
            let folder = tempBase
                .appendingPathComponent("installed", isDirectory: true)
                .appendingPathComponent("\(model.rawValue)-v1", isDirectory: true)
                .appendingPathComponent("\(model.rawValue).mlmodelc", isDirectory: true)
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true
            )
            try Data().write(to: folder.appendingPathComponent("model.mlmodel"))
        }

        let manager = BundledMLModelManager(
            urlSession: session,
            backoffPolicy: .none,
            baseDir: tempBase
        )
        XCTAssertFalse(manager.isReady,
                       "3-of-4 install must not flip isReady true")
        XCTAssertEqual(manager.installed.count, 3)
        XCTAssertEqual(manager.missing.count, 1)
    }

    func test_emptyFolder_doesNotCountAsInstalled() throws {
        // A `<model>-v1/<model>.mlmodelc/` folder that exists but is
        // empty (stale partial install left over from a failed run, or
        // a user who ran `mkdir` by hand) MUST be treated as
        // not-installed, otherwise Core ML's MLModel(contentsOf:) would
        // throw at engine load time instead of the manager triggering a
        // re-download.
        let model = BundledMLModel.promptPhase
        let folder = tempBase
            .appendingPathComponent("installed", isDirectory: true)
            .appendingPathComponent("\(model.rawValue)-v1", isDirectory: true)
            .appendingPathComponent("\(model.rawValue).mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true
        )
        // Intentionally NO placeholder file written.

        let manager = BundledMLModelManager(
            urlSession: session,
            backoffPolicy: .none,
            baseDir: tempBase
        )
        XCTAssertFalse(manager.isInstalled(model),
                       "empty mlmodelc folder must be treated as not-installed")
        XCTAssertNil(manager.compiledModelURL(for: model),
                     "compiledModelURL must return nil for the empty-folder case")
    }

    // MARK: - SHA mismatch cleanup

    func test_shaMismatch_throwsAndCleansStagingDir() async throws {
        // Respond once with 16 bytes that don't match the
        // expected SHA. The download itself "succeeds" (200);
        // SHA verify is what triggers cleanup.
        MockHTTPResponder.enqueueSuccess(
            bytes: Data(repeating: 0xAB, count: 16),
            statusCode: 200
        )
        let manager = BundledMLModelManager(
            urlSession: session,
            backoffPolicy: .none,    // one shot, no retries
            baseDir: tempBase
        )

        do {
            try await manager.downloadAndInstallAll()
            XCTFail("expected SHA mismatch to throw")
        } catch BundledMLModelManager.ManagerError.shaMismatch(_, _, _) {
            // Pass — exactly the case we want.
        } catch {
            XCTFail("expected .shaMismatch, got \(error)")
        }

        // Staging zip + unzip dir should both be swept by the
        // `runFullDownloadFlow` defer block.
        let stagingDir = tempBase.appendingPathComponent("staging", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: stagingDir.path)) ?? []
        XCTAssertTrue(entries.isEmpty,
                      "staging dir should be empty after SHA-mismatch cleanup; got \(entries)")
        XCTAssertTrue(manager.installed.isEmpty,
                      "no model should land in `installed` on SHA mismatch")
    }

    // MARK: - Backoff retry

    func test_backoffRetryOn500_attemptsRequestedNumberOfTimes() async throws {
        // 500 / 500 / 500 / 500 — all four attempts fail. With
        // `.fast` policy (3 retries, ms-level sleep), the manager
        // must hit the endpoint exactly 4 times before giving up.
        for _ in 0..<4 {
            MockHTTPResponder.enqueueSuccess(bytes: Data(), statusCode: 500)
        }
        let manager = BundledMLModelManager(
            urlSession: session,
            backoffPolicy: .fast,
            baseDir: tempBase
        )

        do {
            try await manager.downloadAndInstallAll()
            XCTFail("expected 500 retries to ultimately fail")
        } catch BundledMLModelManager.ManagerError.downloadFailed {
            // Pass.
        } catch {
            XCTFail("expected .downloadFailed, got \(error)")
        }

        // `.fast` has 3 retry delays → 4 total attempts on the
        // FIRST model. The batch loop never reaches model #2
        // because model #1 throws, so requestCount must be
        // exactly 4 (not 16).
        XCTAssertEqual(MockHTTPResponder.requestCount, 4,
                       "expected 4 attempts on first model before throwing")
    }
}
