import Foundation
import MediaPlayer

/// Media keys and Now Playing live off the store so `deinit` isolation stays simple.
///
/// `MPRemoteCommandCenter` invokes its handlers on an arbitrary queue, hence
/// `@unchecked Sendable` plus the explicit main-actor hop in `run(_:)`.
final class NowPlayingBridge: @unchecked Sendable {
    private weak var store: PlayerStore?

    /// Registers the lock-screen / media-key commands once, wiring each to the store.
    func attach(_ store: PlayerStore) {
        self.store = store
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true

        center.playCommand.addTarget { [weak self] _ in
            self?.run { store in
                if !store.isPlaying { store.togglePlayPause() }
            } ?? .commandFailed
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.run { store in
                if store.isPlaying { store.togglePlayPause() }
            } ?? .commandFailed
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.run { $0.togglePlayPause() } ?? .commandFailed
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.run { $0.playNext() } ?? .commandFailed
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.run { $0.playPrevious() } ?? .commandFailed
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            return self?.run { $0.seek(to: event.positionTime) } ?? .commandFailed
        }
    }

    /// Republishes the system Now Playing panel. Fields are optional so a
    /// half-known track still shows what is known.
    func publish(
        title: String?,
        artist: String?,
        album: String?,
        elapsed: TimeInterval,
        duration: TimeInterval,
        isPlaying: Bool
    ) {
        var info: [String: Any] = [:]
        if let title { info[MPMediaItemPropertyTitle] = title }
        if let artist { info[MPMediaItemPropertyArtist] = artist }
        if let album { info[MPMediaItemPropertyAlbumTitle] = album }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Runs `work` on the main actor, hopping there when the caller is not already
    /// on it, and reports `.commandFailed` if the store has gone away.
    @discardableResult
    private func run(_ work: @escaping @MainActor (PlayerStore) -> Void) -> MPRemoteCommandHandlerStatus {
        guard let store else { return .commandFailed }
        if Thread.isMainThread {
            MainActor.assumeIsolated { work(store) }
        } else {
            DispatchQueue.main.async { work(store) }
        }
        return .success
    }
}
