// The native reader overlays the existing response only on request. Its tab
// owns one bounded index, released on raw mode, navigation, sleep or close.
// MIME detection adds no scripts to ordinary pages. One serial parsing worker
// keeps parsing off the UI thread; cancelled reads never publish a late result.
// At most 1,000 rows are drawn, so Expand All on a large document stays cheap
// to show; the footer says so only when rows are hidden.
import SwiftUI
import WebKit

@MainActor
final class JSONReader: ObservableObject {
    @Published private(set) var available = false
    @Published private(set) var shown = false
    @Published private(set) var document: JSONDocument?
    @Published private(set) var error: String?
    @Published var query = "" { didSet { rows() } }
    @Published private(set) var visible: [Int] = []
    @Published private(set) var expanded: Set<Int> = [0]
    /// Rows drawn at most, in the tab and in the panel.
    static let cap = 1000
    private static let script = Bundled.script("json-response.js")
    private var revision = 0
    private var operation: BlockOperation?
    private static let worker: OperationQueue = {
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .userInitiated
        return queue
    }()
    func detect(_ response: URLResponse) {
        let mime = response.mimeType?.lowercased() ?? ""
        available = mime == "application/json" || mime == "text/json" || mime.hasSuffix("+json") ||
            (response.url?.isFileURL == true && response.url?.pathExtension.lowercased() == "json" && mime != "text/html")
    }
    func reset() { raw(); available = false }
    func raw() {
        revision += 1; operation?.cancel(); operation = nil
        shown = false; document = nil; error = nil; visible = []; query = ""; expanded = [0]
    }
    func open(_ web: WKWebView?) {
        guard available, !shown, let web else { return }
        shown = true
        let asked = revision
        web.evaluateJavaScript(Self.script, in: nil, in: .defaultClient) { [weak self] result in
            guard let self, self.revision == asked, self.shown else { return }
            switch result {
            case .failure(let error): self.error = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            case .success(let value):
                guard let text = value as? String else { self.error = "The response could not be read."; return }
                self.parse(text, asked: asked)
            }
        }
    }
    /// A response already in hand, from the API Calls panel (Calls.swift):
    /// the same parsing and limits, without a page to read it from.
    func show(_ text: String) {
        raw()
        shown = true
        parse(text, asked: revision)
    }
    private func parse(_ text: String, asked: Int) {
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard operation?.isCancelled == false else { return }
            let parsed = Result { try JSONDocument(text) }
            guard operation?.isCancelled == false else { return }
            DispatchQueue.main.async {
                guard let self, self.revision == asked, self.shown else { return }
                self.operation = nil
                switch parsed {
                case .success(let document): self.document = document; self.rows()
                case .failure(let error): self.error = error.localizedDescription
                }
            }
        }
        self.operation = operation
        Self.worker.addOperation(operation)
    }
    /// Opens or closes one row; `all` does its whole subtree, as ⌥-click
    /// on a disclosure triangle does in Finder.
    func toggle(_ id: Int, all: Bool = false) {
        guard all, let document else {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
            rows()
            return
        }
        let containers = document.subtree(id).filter { !document.nodes[$0].children.isEmpty }
        if expanded.contains(id) { expanded.subtract(containers) } else { expanded.formUnion(containers) }
        rows()
    }
    /// Every object and array open, or back to the top level as on opening.
    func openAll(_ open: Bool) {
        guard let document else { return }
        expanded = open ? Set(document.nodes.lazy.filter { !$0.children.isEmpty }.map(\.id)) : [0]
        rows()
    }
    /// What the cap hides, said only when it hides something.
    var hidden: String? {
        visible.count > Self.cap ? "\(visible.count) lines; the first 1,000 are shown. Search narrows them." : nil
    }
    /// Whether the click being handled holds ⌥.
    static var option: Bool { NSApp.currentEvent?.modifierFlags.contains(.option) == true }
    private func rows() {
        guard let document else { visible = []; return }
        var showing: Set<Int> = []
        visible = document.nodes.compactMap { node in
            let show: Bool
            if query.isEmpty { show = node.parent.map { showing.contains($0) && expanded.contains($0) } ?? true }
            else { show = node.label.localizedCaseInsensitiveContains(query) || (node.children.isEmpty && document.value(node.id).localizedCaseInsensitiveContains(query)) }
            if show { showing.insert(node.id) }
            return show ? node.id : nil
        }
    }
}

struct JSONPage: View {
    @ObservedObject var reader: JSONReader
    let page: PageView?
    let corner: CGFloat
    let opening: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            if reader.available {
                HStack {
                    Text("JSON").font(.headline)
                    Spacer()
                    if reader.shown { Button("Raw Response") { reader.raw() } }
                    else { Button("Structured View") { opening(); reader.open(page) } }
                }
                .padding(Metrics.toolInset)
                .glass(.chip, in: Rectangle())
            }
            ZStack {
                WebStage(page: page, corner: corner)
                    .opacity(reader.shown ? 0 : 1)
                    .allowsHitTesting(!reader.shown)
                    .accessibilityHidden(reader.shown)
                JSONSurface(reader: reader)
            }
        }
    }
}

struct JSONSurface: View {
    @ObservedObject var reader: JSONReader
    var body: some View {
        if reader.shown {
            VStack(alignment: .leading, spacing: Metrics.toolGap) {
                if reader.shown {
                    HStack {
                        TextField("Search keys and values", text: $reader.query).textFieldStyle(.roundedBorder)
                        Button("Expand All") { reader.openAll(true) }
                        Button("Collapse All") { reader.openAll(false) }
                    }.padding(.horizontal, Metrics.toolInset)
                    if let error = reader.error { Text(error).foregroundStyle(Palette.danger).padding(Metrics.toolInset) }
                    else if let document = reader.document {
                        List(Array(reader.visible.prefix(JSONReader.cap)), id: \.self) { id in
                            let node = document.nodes[id]
                            HStack {
                                if !node.children.isEmpty {
                                    Button { reader.toggle(id, all: JSONReader.option) } label: {
                                        Image(systemName: reader.expanded.contains(id) ? "chevron.down" : "chevron.right")
                                    }.accessibilityLabel("Expand or collapse \(node.label)")
                                }
                                Text(node.label).foregroundStyle(Palette.ink).lineLimit(1)
                                Text(node.children.isEmpty ? String(document.value(id).prefix(200)) : "\(node.kind) · \(node.children.count)")
                                    .foregroundStyle(node.kind == "string" ? Palette.safe : Palette.muted).lineLimit(2)
                                Spacer()
                                Menu("Copy") { JSONCopies(document: document, id: id) }
                                    .menuStyle(.borderlessButton).fixedSize()
                            }
                            .buttonStyle(.borderless)
                            .accessibilityElement(children: .contain)
                            .padding(.leading, CGFloat(min(node.depth, 12)) * Metrics.toolIndent)
                            .font(.system(size: Metrics.toolFont, design: .monospaced))
                        }.scrollContentBackground(.hidden)
                        Text(reader.hidden ?? "\(reader.visible.count) \(reader.query.isEmpty ? "lines" : "matches")")
                            .font(.caption).foregroundStyle(Palette.muted).padding(Metrics.toolInset)
                    } else { ProgressView().padding(Metrics.toolInset) }
                    Spacer(minLength: 0)
                } else { Spacer(minLength: 0) }
            }
            .background { if reader.shown { Color.clear.glass(.panel, in: Rectangle(), lifted: false) } }
            .foregroundStyle(Palette.ink)
        }
    }
    static func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}
