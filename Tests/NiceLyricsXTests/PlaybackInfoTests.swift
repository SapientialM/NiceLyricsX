//
//  PlaybackInfoTests.swift
//  NiceLyricsXTests
//
//  PlaybackState + PlaybackInfo 状态机测试
//

import XCTest
@testable import NiceLyricsX

final class PlaybackInfoTests: XCTestCase {

    // MARK: - PlaybackState.time

    func testStoppedTimeIsZero() {
        XCTAssertEqual(PlaybackState.stopped.time, 0)
    }

    func testPausedTimeIsFrozen() {
        XCTAssertEqual(PlaybackState.paused(time: 12.5).time, 12.5)
        // paused 时间为负时保护为 0
        XCTAssertEqual(PlaybackState.paused(time: -1).time, 0)
    }

    func testPlayingTimeComputesFromNow() {
        let start = Date(timeIntervalSinceNow: -10)
        let state = PlaybackState.playing(start: start)
        // 误差 0.1s,允许 clock skew
        XCTAssertEqual(state.time, 10, accuracy: 0.1)
    }

    // MARK: - PlaybackState.approximateEqual

    func testApproximateEqualStopped() {
        XCTAssertTrue(PlaybackState.stopped.approximateEqual(to: .stopped))
    }

    func testApproximateEqualPausedWithinTolerance() {
        XCTAssertTrue(PlaybackState.paused(time: 5.0).approximateEqual(to: .paused(time: 5.8)))
        XCTAssertFalse(PlaybackState.paused(time: 5.0).approximateEqual(to: .paused(time: 7.0)))
    }

    func testApproximateEqualPlaying() {
        let now = Date()
        XCTAssertTrue(PlaybackState.playing(start: now)
            .approximateEqual(to: .playing(start: now.addingTimeInterval(0.5))))
        XCTAssertFalse(PlaybackState.playing(start: now)
            .approximateEqual(to: .playing(start: now.addingTimeInterval(3))))
    }

    func testApproximateEqualDifferentKinds() {
        XCTAssertFalse(PlaybackState.stopped.approximateEqual(to: .paused(time: 0)))
    }

    // MARK: - PlaybackInfo

    func testSearchQuerySkipsEmpty() {
        let info = PlaybackInfo(title: "Song", artist: "Artist")
        XCTAssertEqual(info.searchQuery, "Song Artist")
    }

    func testSearchQueryOmitsEmpty() {
        let info = PlaybackInfo(title: "Song", artist: "")
        XCTAssertEqual(info.searchQuery, "Song")
    }

    func testIsPlayingFlag() {
        let playing = PlaybackInfo(title: "t", artist: "a", state: .playing(start: Date()))
        let paused = PlaybackInfo(title: "t", artist: "a", state: .paused(time: 0))
        let stopped = PlaybackInfo.empty
        XCTAssertTrue(playing.isPlaying)
        XCTAssertFalse(paused.isPlaying)
        XCTAssertFalse(stopped.isPlaying)
    }
}
