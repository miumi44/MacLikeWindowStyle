import AppKit

final class SwitcherPanel: NSPanel {
    override init(contentRect:NSRect,styleMask:NSWindow.StyleMask,backing:NSWindow.BackingStoreType,defer flag:Bool) {
        super.init(contentRect:contentRect,styleMask:styleMask.union(.nonactivatingPanel),backing:backing,defer:flag)
        hidesOnDeactivate=false
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
