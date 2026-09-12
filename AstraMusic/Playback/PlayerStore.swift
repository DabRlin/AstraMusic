import AVFoundation
import Foundation
import MediaPlayer
import Observation

/// Owns playback: the queue, the `AVPlayer`, and the lyrics for the current track.
///
/// This is the only source of playback truth — views read it and call it, and
/// nothing else touches `AVPlayer`. `@MainActor` because it drives SwiftUI state
/// and because every `AVPlayer` callback below is marshalled onto the main actor.
@Observable
@MainActor
final class PlayerStore {
    var queue: [Song] = []
    var currentIndex: Int = 0
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var lyrics: [LyricLine] = []
    var playbackError: String?
    var playbackMode: PlaybackMode = .loadPersisted(userID: nil)
    /// Current account id, mirrored by AuthStore so per-user preferences land in
    /// the right bucket.
    var currentUserID: String?

    @ObservationIgnored
    let avPlayer = AVPlayer()
    @ObservationIgnored
    var timeObserver: Any?
    @ObservationIgnored
    var endObserver: NSObjectProtocol?
    @ObservationIgnored
    var itemFailObserver: NSObjectProtocol?
    @ObservationIgnored
    var itemStatusObservation: NSKeyValueObservation?
    /// Set while the user is dragging or a programmatic seek is in flight, so the
    /// periodic time observer does not fight the slider.
    @ObservationIgnored
    var isSeeking = false
    @ObservationIgnored
    let nowPlaying = NowPlayingBridge()
    /// Called when a track actually starts, which is how the library records
    /// "Recent". Not called for a rewind or a resume.
    @ObservationIgnored
    var onSongStarted: ((Song) -> Void)?
    @ObservationIgnored
    var musicClient: any MusicClient = KugouMusicClient()

    var currentSong: Song? {
        queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    var currentTimeLabel: String { format(currentTime) }
    var durationLabel: String { format(duration) }

    /// Last lyric whose timestamp is at or before `currentTime`.
    var currentLyricIndex: Int? {
        guard !lyrics.isEmpty else { return nil }
        var match: Int?
        for (index, line) in lyrics.enumerated() {
            if line.time <= currentTime {
                match = index
            } else {
                break
            }
        }
        return match
    }

    init() {
        observePlaybackEnd()
        observeItemFailure()
        observePeriodicTime()
        nowPlaying.attach(self)
    }

    /// Empties playback, e.g. on sign-out. Also clears the AVPlayer item so no
    /// audio can continue after the session is gone.
    func resetQueue() {
        queue = []
        currentIndex = 0
        isPlaying = false
        currentTime = 0
        duration = 0
        lyrics = []
        playbackError = nil
        replaceCurrentItem(autoplay: false)
    }

    func setPlaybackMode(_ mode: PlaybackMode) {
        playbackMode = mode
        mode.persist(userID: currentUserID)
    }

    /// Switches the per-account preference bucket and reloads the playback mode.
    func setUser(_ userID: String?) {
        currentUserID = userID
        playbackMode = .loadPersisted(userID: userID)
    }

    /// Plays one song.
    ///
    /// If it is already in the queue this just jumps to it, otherwise it is
    /// inserted at the front and becomes current — so tapping a track starts it
    /// immediately without disturbing the rest of the queue order.
    func play(_ song: Song) {
        guard SessionStore.isLoggedIn else {
            playbackError = "Sign in is required to play remote songs."
            publishNowPlaying()
            return
        }
        if let index = queue.firstIndex(where: { $0.id == song.id }) {
            currentIndex = index
        } else {
            queue.insert(song, at: 0)
            currentIndex = 0
        }
        lyrics = []
        replaceCurrentItem(autoplay: true)
        notifySongStarted()
        Task { await hydrateCurrentTrack() }
    }

    /// Replaces the queue with `songs` and starts at `song` (or the first track).
    /// This is what a playlist/album "play all" does.
    func play(songs: [Song], startingAt song: Song? = nil) {
        guard SessionStore.isLoggedIn else {
            playbackError = "Sign in is required to play remote songs."
            publishNowPlaying()
            return
        }
        guard !songs.isEmpty else { return }
        queue = songs
        if let song, let index = songs.firstIndex(where: { $0.id == song.id }) {
            currentIndex = index
        } else {
            currentIndex = 0
        }
        lyrics = []
        replaceCurrentItem(autoplay: true)
        notifySongStarted()
        Task { await hydrateCurrentTrack() }
    }

    func togglePlayPause() {
        guard SessionStore.isLoggedIn else {
            resetQueue()
            return
        }
        guard currentSong != nil else { return }
        // No item yet means the URL is still being resolved (or the queue was
        // restored without one): start it instead of toggling nothing.
        if avPlayer.currentItem == nil {
            replaceCurrentItem(autoplay: true)
            notifySongStarted()
            Task { await hydrateCurrentTrack() }
            return
        }
        if isPlaying {
            avPlayer.pause()
            isPlaying = false
        } else {
            avPlayer.play()
            isPlaying = true
        }
        publishNowPlaying()
    }

    func playNext() {
        advance(fromEndOfTrack: false)
    }

    /// Restarts the current track when more than a few seconds in, otherwise
    /// steps back — the conventional "previous" behaviour.
    func playPrevious() {
        guard !queue.isEmpty else { return }
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        currentIndex = (currentIndex - 1 + queue.count) % queue.count
        lyrics = []
        replaceCurrentItem(autoplay: true)
        notifySongStarted()
        Task { await hydrateCurrentTrack() }
    }

    func seek(to time: TimeInterval) {
        let clamped = max(0, min(time, max(duration, 0)))
        isSeeking = true
        currentTime = clamped
        let cmTime = CMTime(seconds: clamped, preferredTimescale: 600)
        avPlayer.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.isSeeking = false
                self?.publishNowPlaying()
            }
        }
    }

    func seek(progress value: Double) {
        seek(to: duration * min(max(value, 0), 1))
    }

    /// Slider drag updates UI without seeking every tick; call `seek(progress:)` on end.
    func previewSeek(progress value: Double) {
        isSeeking = true
        currentTime = duration * min(max(value, 0), 1)
    }

    func commitSeek() {
        seek(to: currentTime)
    }
}
