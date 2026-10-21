import AppKit
import Combine

/// State of the library window: which capture is open and whether the side panes show.
final class LibraryModel: ObservableObject {
    @Published private(set) var openURL: URL?
    @Published private(set) var session: EditSession?
    @Published var showSidebar = true
    @Published var showInspector = true

    let prefs: Preferences
    let library: CaptureLibrary
    let previews: PreviewCache
    var commands: CaptureCommands!
    var onCapture: ((CaptureKind) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onEditsSaved: ((URL) -> Void)?

    private var cancellables = Set<AnyCancellable>()

    init(prefs: Preferences, library: CaptureLibrary, previews: PreviewCache) {
        self.prefs = prefs
        self.library = library
        self.previews = previews
        // Close the editor when its file disappears (for example deleted in Finder).
        library.$captures.sink { [weak self] captures in
            guard let self, let url = self.openURL, !captures.contains(where: { $0.url == url }),
                  !FileManager.default.fileExists(atPath: url.path) else { return }
            self.open(nil)
        }.store(in: &cancellables)
    }

    func open(_ url: URL?) {
        guard url != openURL || (url != nil && session == nil) else { return }
        closeSession()
        openURL = url
        guard let url, let doc = MarkupDocument.load(url: url) else {
            session = nil
            return
        }
        let s = EditSession(document: doc)
        s.onPin = { [weak self] url in self?.commands.pin(url) }
        s.onDelete = { [weak self] url in self?.commands.delete(url) }
        session = s
    }

    /// Persist and release the open capture.
    func closeSession() {
        guard let session else { return }
        session.close()
        onEditsSaved?(session.document.url)
        self.session = nil
    }

    /// Opens the neighbour of a capture that is about to be removed.
    func openNeighbor(of url: URL) {
        let captures = library.captures
        guard openURL == url, let i = captures.firstIndex(where: { $0.url == url }) else { return }
        let next = captures.indices.contains(i + 1) ? captures[i + 1].url : (i > 0 ? captures[i - 1].url : nil)
        session = nil
        openURL = nil
        open(next)
    }

    /// Moves the selection up or down the list (↑ / ↓ in the sidebar).
    func openAdjacent(_ delta: Int) {
        let captures = library.captures
        guard !captures.isEmpty else { return }
        let i = captures.firstIndex { $0.url == openURL } ?? -delta
        let j = min(max(i + delta, 0), captures.count - 1)
        open(captures[j].url)
    }
}
