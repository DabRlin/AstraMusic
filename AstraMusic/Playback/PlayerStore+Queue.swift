import AVFoundation
import Foundation

/// `PlayerStore` queue traversal: end-of-track / next-track advancement, index
/// moves, and the song-start notification.
extension PlayerStore {
    func notifySongStarted() {
        if let song = currentSong {
            onSongStarted?(song)
        }
    }

    /// Next-track vs end-of-track differ for sequential (stop) and repeat-one (restart).
    func advance(fromEndOfTrack: Bool) {
        guard !queue.isEmpty else { return }

        switch playbackMode {
        case .repeatOne:
            if fromEndOfTrack {
                seek(to: 0)
                avPlayer.play()
                isPlaying = true
                publishNowPlaying()
                return
            }
            moveToIndex((currentIndex + 1) % queue.count)
        case .repeatList:
            moveToIndex((currentIndex + 1) % queue.count)
        case .sequential:
            if currentIndex + 1 < queue.count {
                moveToIndex(currentIndex + 1)
            } else if fromEndOfTrack {
                // End of the queue: stop and stay parked at the end.
                avPlayer.pause()
                isPlaying = false
                currentTime = duration
                publishNowPlaying()
            } else {
                moveToIndex(0)
            }
        case .shuffle:
            if queue.count == 1 {
                if fromEndOfTrack {
                    seek(to: 0)
                    avPlayer.play()
                    isPlaying = true
                    publishNowPlaying()
                }
                return
            }
            // Re-roll until it differs: avoids replaying the current track
            // immediately, at the cost of a short loop for tiny queues.
            var next = Int.random(in: 0..<queue.count)
            while next == currentIndex {
                next = Int.random(in: 0..<queue.count)
            }
            moveToIndex(next)
        }
    }

    private func moveToIndex(_ index: Int) {
        currentIndex = index
        lyrics = []
        replaceCurrentItem(autoplay: true)
        notifySongStarted()
        Task { await hydrateCurrentTrack() }
    }
}
