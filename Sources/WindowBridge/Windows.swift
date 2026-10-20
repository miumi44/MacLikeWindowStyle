import AppKit
import ScreenCaptureKit
import ApplicationServices
import WindowBridgeCore

struct WindowItem {
    let id: UInt32
    let pid: pid_t
    let title: String
    let app: String
    let frame: CGRect
    let source: SCWindow?
    var thumbnail: NSImage?
    let icon: NSImage?
}

@MainActor final class WindowStore {
    var windows: [WindowItem] = []
    private var recent: [UInt32] = []
    private var refreshing = false
    private var icons: [pid_t:NSImage] = [:]
    private var freshness=ThumbnailFreshness()
    var onChange: (() -> Void)?
    func refresh() async throws {
        guard !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let old = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.thumbnail) })
        let pids=Set(content.windows.compactMap { $0.owningApplication?.processID })
        let applications=Dictionary(uniqueKeysWithValues:pids.compactMap { pid in
            NSRunningApplication(processIdentifier:pid).map { (pid,$0) }
        })
        let regularPIDs=Set(applications.filter { $0.value.activationPolicy == .regular }.keys)
        icons=icons.filter { pids.contains($0.key) }
        for pid in regularPIDs where icons[pid] == nil { icons[pid]=applications[pid]?.icon }
        let items = content.windows.compactMap { w -> WindowItem? in
            guard w.windowLayer == 0, w.frame.width >= 120, w.frame.height >= 80,
                  let owner = w.owningApplication, owner.processID != ownPID,
                  regularPIDs.contains(owner.processID),
                  !["com.apple.dock", "com.apple.WindowManager", "com.apple.controlcenter"].contains(owner.bundleIdentifier),
                  true else { return nil }
            let title = (w.title?.isEmpty == false) ? w.title! : "제목 없는 창"
            return WindowItem(id: w.windowID, pid: owner.processID, title: title, app: owner.applicationName,
                              frame: w.frame, source: w, thumbnail: old[w.windowID] ?? nil, icon:icons[owner.processID])
        }
        let cg = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String:Any]] ?? []
        let front = cg.compactMap { $0[kCGWindowNumber as String] as? UInt32 }.first { id in items.contains { $0.id == id } }
        if let front { recent.removeAll { $0 == front }; recent.insert(front, at: 0) }
        let cgIDs = cg.compactMap { $0[kCGWindowNumber as String] as? UInt32 }.filter { id in items.contains { $0.id == id } }
        let ids = orderedWindows(available: orderedWindows(available:items.map(\.id),recent:cgIDs), recent: recent)
        let map = Dictionary(uniqueKeysWithValues: items.map { ($0.id,$0) })
        windows = ids.compactMap { map[$0] }; freshness.retain(ids:Set(ids));onChange?()
    }
    func capture(ids: [UInt32]) async {
        for id in ids {
            guard !Task.isCancelled else { return }
            guard freshness.needsCapture(id,now:ProcessInfo.processInfo.systemUptime) else { continue }
            guard let index = windows.firstIndex(where: { $0.id == id }), let w = windows[index].source else { continue }
            let filter = SCContentFilter(desktopIndependentWindow: w)
            let cfg = SCStreamConfiguration()
            cfg.width = 600; cfg.height = max(120, min(420, Int(600 * w.frame.height / max(1,w.frame.width))))
            cfg.showsCursor = false; cfg.scalesToFit = true
            do {
                let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                guard !Task.isCancelled else { return }
                if let i = windows.firstIndex(where: { $0.id == id }) {
                    windows[i].thumbnail = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    freshness.record(id,now:ProcessInfo.processInfo.systemUptime);onChange?()
                }
            } catch { /* A closed/protected window keeps its app icon as fallback. */ }
        }
    }
    func activate(_ id: UInt32) async -> Bool {
        guard let item = windows.first(where: { $0.id == id }), let app = NSRunningApplication(processIdentifier: item.pid) else { return false }
        let element = AXUIElementCreateApplication(item.pid)
        AXUIElementSetMessagingTimeout(element,1.0)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &result) == .success,
              let axWindows = result as? [AXUIElement] else { return false }
        // Title plus frame distinguishes same-title windows without private AX APIs.
        let candidates = axWindows.filter { ax in
            var title: CFTypeRef?; AXUIElementCopyAttributeValue(ax,kAXTitleAttribute as CFString,&title)
            return (title as? String ?? "") == (item.source?.title ?? "")
        }
        let target = candidates.map { ($0,distance($0,item.frame)) }.min { $0.1 < $1.1 }?.0
        guard let target else { return false }
        AXUIElementSetAttributeValue(target,kAXMinimizedAttribute as CFString,kCFBooleanFalse)
        if app.isHidden { app.unhide() }
        // Raising a window does not transfer keyboard focus from another app.
        AXUIElementSetAttributeValue(element,kAXFrontmostAttribute as CFString,kCFBooleanTrue)
        _=app.activate(options: [])
        AXUIElementSetAttributeValue(element,kAXFocusedWindowAttribute as CFString,target)
        AXUIElementSetAttributeValue(target,kAXMainAttribute as CFString,kCFBooleanTrue)
        let raised = AXUIElementPerformAction(target,kAXRaiseAction as CFString) == .success
        var verified=false
        for _ in 0..<8 {
            var focused: CFTypeRef?
            AXUIElementCopyAttributeValue(element,kAXFocusedWindowAttribute as CFString,&focused)
            verified=windowActivationSucceeded(raised:raised,targetPID:item.pid,
                frontPID:NSWorkspace.shared.frontmostApplication?.processIdentifier,
                focused:focused.map { CFEqual($0,target) } ?? false)
            if verified { break }
            try? await Task.sleep(nanoseconds:50_000_000)
        }
        if verified {
            recent.removeAll { $0 == id }; recent.insert(id,at:0)
            // Update immediately so rapid Alt+Tab toggles back, without waiting for the timer.
            if let index = windows.firstIndex(where: { $0.id == id }) {
                let current = windows.remove(at:index); windows.insert(current,at:0)
            }
        }
        return verified
    }
    private func distance(_ window: AXUIElement, _ frame: CGRect) -> CGFloat {
        var value: CFTypeRef?; var point = CGPoint.zero
        if AXUIElementCopyAttributeValue(window,kAXPositionAttribute as CFString,&value) == .success,
           let value, CFGetTypeID(value) == AXValueGetTypeID() { AXValueGetValue(value as! AXValue,.cgPoint,&point) }
        return abs(point.x-frame.minX)+abs(point.y-frame.minY)
    }
    func demo() {
        windows = [("Safari", "개발 문서 — Safari"),("Finder", "프로젝트 폴더"),("Terminal", "개발 서버"),("메모", "오늘의 작업")].enumerated().map { i,pair in
            WindowItem(id: UInt32(900000+i),pid:0,title:pair.1,app:pair.0,frame:CGRect(x:0,y:0,width:1200,height:800),source:nil,thumbnail:nil,icon:nil)
        }; onChange?()
    }
}
