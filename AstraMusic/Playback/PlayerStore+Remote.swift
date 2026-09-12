import AVFoundation
import Foundation

/// `PlayerStore` remote-stream plumbing: AVPlayer item setup and hydration,
/// periodic-time / end / failure observation, and Now Playing publication.
extension PlayerStore {
    /// Rebuilds the AVPlayer item for `currentSong`.
    ///
    /// Three cases: an already-resolved URL starts immediately; a remote track
    /// without a URL moves to "Resolving stream…" and waits for
    /// `hydrateCurrentTrack()`; anything else has no audio source at all.
    func replaceCurrentItem(autoplay: Bool) {
        avPlayer.pause()
        currentTime = 0

        guard let song = currentSong else {
            avPlayer.replaceCurrentItem(with: nil)
            isPlaying = false
            duration = 0
            lyrics = []
            publishNowPlaying()
            return
        }

        duration = song.duration
        playbackError = nil

        if let url = song.playbackURL {
            startItem(url: url, fallbackDuration: song.duration, autoplay: autoplay)
        } else if needsRemoteURL(song) {
            avPlayer.replaceCurrentItem(with: nil)
            isPlaying = false
            playbackError = "Resolving stream…"
            publishNowPlaying()
        } else {
            avPlayer.replaceCurrentItem(with: nil)
            isPlaying = false
            playbackError = "No audio file for this track."
            publishNowPlaying()
        }
    }

    /// True when the track must be resolved over the network. The `local_` prefix
    /// marks tracks that are not backed by a Kugou hash.
    private func needsRemoteURL(_ song: Song) -> Bool {
        guard let hash = song.hash else { return false }
        return !hash.hasPrefix("local_")
    }

    private func startItem(url: URL, fallbackDuration: TimeInterval, autoplay: Bool) {
        // Play `url[0]` directly — no extra CDN headers.
        let item = AVPlayerItem(url: url)
        observeItemStatus(item)
        avPlayer.replaceCurrentItem(with: item)

        if autoplay {
            avPlayer.play()
            isPlaying = true
        } else {
            isPlaying = false
        }

        Task { [weak self] in
            await self?.refreshDuration(from: item, fallback: fallbackDuration)
        }
        publishNowPlaying()
    }

    /// Resolves the stream URL and fetches lyrics for the current track.
    ///
    /// Both awaits can outlive the track they were started for, so the captured
    /// `index` is re-checked after each one: a fast "next" must not write the old
    /// track's URL or lyrics onto the new one.
    func hydrateCurrentTrack() async {
        let index = currentIndex
        guard let song = currentSong else { return }
        let client = musicClient

        if needsRemoteURL(song), song.playbackURL == nil {
            do {
                let url = try await client.playbackURL(for: song)
                guard currentIndex == index else { return }
                queue[index].playbackURL = url
                startItem(url: url, fallbackDuration: song.duration, autoplay: true)
                playbackError = nil
            } catch {
                guard currentIndex == index else { return }
                playbackError = error.localizedDescription
                publishNowPlaying()
            }
        }

        do {
            let remote = try await client.lyrics(for: song)
            guard currentIndex == index else { return }
            if !remote.isEmpty {
                lyrics = remote
            }
        } catch {
            // Keep whatever lyrics are already on the store.
        }
    }

    /// Prefers the real asset duration once known, falling back to the metadata
    /// value (which can be wrong for some streams).
    private func refreshDuration(from item: AVPlayerItem, fallback: TimeInterval) async {
        let resolved: TimeInterval
        do {
            let loaded = try await item.asset.load(.duration)
            if loaded.isNumeric, loaded.seconds.isFinite, loaded.seconds > 0 {
                resolved = loaded.seconds
            } else {
                resolved = fallback
            }
        } catch {
            resolved = fallback
        }
        duration = resolved
        publishNowPlaying()
    }

    /// Drives the progress UI at 4 Hz, but never while a seek is in flight.
    func observePeriodicTime() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isSeeking else { return }
                let seconds = time.seconds
                if seconds.isFinite {
                    self.currentTime = max(0, seconds)
                }
            }
        }
    }

    /// Auto-advances at end of track. Filtered to the *current* item, because the
    /// notification is posted for every item that ever played.
    func observePlaybackEnd() {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let ended = notification.object as? AVPlayerItem,
                      ended == self.avPlayer.currentItem
                else { return }
                self.advance(fromEndOfTrack: true)
            }
        }
    }

    /// Surfaces mid-stream failures (network drops, dead URLs).
    func observeItemFailure() {
        itemFailObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let failed = notification.object as? AVPlayerItem,
                      failed == self.avPlayer.currentItem
                else { return }
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                    ?? failed.error
                self.reportPlaybackFailure(error)
            }
        }
    }

    /// Watches the item's status. `.readyToPlay` clears the transient
    /// "Resolving stream…" message; `.failed` reports why.
    private func observeItemStatus(_ item: AVPlayerItem) {
        itemStatusObservation?.invalidate()
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            Task { @MainActor in
                guard let self, observed == self.avPlayer.currentItem else { return }
                switch observed.status {
                case .failed:
                    self.reportPlaybackFailure(observed.error)
                case .readyToPlay:
                    if self.playbackError != nil {
                        self.playbackError = nil
                    }
                default:
                    break
                }
            }
        }
    }

    private func reportPlaybackFailure(_ error: Error?) {
        isPlaying = false
        avPlayer.pause()
        let detail = error?.localizedDescription ?? "Unknown AVPlayer error"
        playbackError = "Could not play this stream: \(detail)"
        publishNowPlaying()
    }

    func publishNowPlaying() {
        nowPlaying.publish(
            title: currentSong?.title,
            artist: currentSong?.artistName,
            album: currentSong?.albumTitle,
            elapsed: currentTime,
            duration: duration,
            isPlaying: isPlaying
        )
    }

    func format(_ time: TimeInterval) -> String {
        guard time.isFinite else { return "0:00" }
        let total = max(0, Int(time.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
