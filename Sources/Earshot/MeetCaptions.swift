import AppKit
import ApplicationServices
import Foundation

/// Reads Google Meet's live captions from the browser's accessibility tree. Meet shows each caption under the
/// speaker's name, so a caption that is still growing tells us who is talking right now. These moments become
/// `SpeakerHint`s that name the diarizer's "Speaker N" clusters.
///
/// Needs Earshot in System Settings → Privacy & Security → Accessibility, and captions (CC) on in Meet.
/// Nothing is sent anywhere and Meet's own caption text is not used for the transcript.
final class MeetCaptionWatcher: @unchecked Sendable {
    /// Meet's aria-label for the captions region, in the UI languages we expect.
    static let regionLabels: Set<String> = ["captions", "subtitrări", "subtitrari", "untertitel", "sous-titres", "subtítulos",
                                            "sottotitoli", "legendas", "ondertiteling", "napisy"]
    /// Meet labels your own captions with this; the microphone track already covers you.
    static let selfLabels: Set<String> = ["you", "tu", "dvs.", "dumneavoastră", "du", "sie", "vous", "tú", "usted"]

    private let app: AXUIElement
    private let onHint: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "earshot.captions", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var region: AXUIElement?
    private var nextSearch = Date.distantPast
    private var lastText: [String: String] = [:]
    private(set) var active = false

    init?(bundleID: String, onHint: @escaping @Sendable (String) -> Void) {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier else { return nil }
        app = AXUIElementCreateApplication(pid)
        self.onHint = onHint
    }

    static var trusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt once per launch of a meeting; afterwards the user grants it in System Settings.
    static func requestTrust() {
        guard !trusted, !UserDefaults.standard.bool(forKey: "askedAccessibility") else { return }
        UserDefaults.standard.set(true, forKey: "askedAccessibility")
        ask()
    }

    /// Asking is what puts Earshot into System Settings → Privacy & Security → Accessibility (switched off);
    /// then open that pane so the user can switch it on.
    static func ask() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func start() {
        // Chromium only builds the web accessibility tree for assistive apps that ask for it.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        guard Self.trusted else { return }
        if region == nil || attribute(region!, kAXRoleAttribute) == nil {
            region = nil
            active = false
            guard Date() >= nextSearch else { return }
            nextSearch = Date().addingTimeInterval(10)
            region = findRegion()
            if region != nil { LiveDebug.log("[captions] found Meet captions region") }
        }
        guard let region else { return }
        active = true
        // Region → (single-child wrappers) → one block per caption run: [name, text, text…].
        var node = region
        while case let kids = children(node), kids.count == 1 { node = kids[0] }
        for block in children(node).suffix(3) {
            let texts = staticTexts(block, limit: 60)
            guard texts.count >= 2 else { continue }
            let name = texts[0]
            let caption = texts.dropFirst().joined(separator: " ")
            guard lastText[name] != caption else { continue }
            lastText[name] = caption
            if !Self.selfLabels.contains(name.lowercased()), name.count <= 60 { onHint(name) }
        }
    }

    /// Breadth-first through the browser's windows for the captions landmark; bounded so it stays cheap.
    private func findRegion() -> AXUIElement? {
        var queue = (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).filter {
            (attribute($0, kAXTitleAttribute) as? String ?? "").localizedCaseInsensitiveContains("meet")
        }
        var visited = 0
        while !queue.isEmpty, visited < 8000 {
            let e = queue.removeFirst()
            visited += 1
            for key in [kAXDescriptionAttribute, kAXTitleAttribute] {
                if let label = attribute(e, key) as? String, Self.regionLabels.contains(label.lowercased()) { return e }
            }
            queue += children(e)
        }
        return nil
    }

    private func staticTexts(_ e: AXUIElement, limit: Int) -> [String] {
        var out: [String] = []
        var stack = [e]
        var visited = 0
        while let n = stack.popLast(), visited < limit {
            visited += 1
            if attribute(n, kAXRoleAttribute) as? String == kAXStaticTextRole,
               let v = (attribute(n, kAXValueAttribute) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                out.append(v)
            }
            stack += children(n).reversed()
        }
        return out
    }

    private func children(_ e: AXUIElement) -> [AXUIElement] {
        attribute(e, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private func attribute(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
    }
}
