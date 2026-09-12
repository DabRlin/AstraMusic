import Foundation

/// The Kugou implementation of `MusicClient` and `LoginClient`: it talks to the
/// local KuGouMusicApi sidecar (unofficial; personal learning only — no VIP
/// claim, paywall bypass, or captcha solving).
///
/// Every method lives in a `KugouMusicClient+…` extension file next to this one,
/// grouped by domain (library, search, playback, auth, lyrics, recommend). This
/// file holds only the stored `api` client and the initializer.
struct KugouMusicClient: MusicClient, LoginClient {
    /// Internal so the extension files in this folder can build requests with it.
    let api: APIClient

    init(api: APIClient = APIClient()) {
        self.api = api
    }
}
