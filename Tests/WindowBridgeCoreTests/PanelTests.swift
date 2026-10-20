import AppKit
@main struct PanelTests {
    static func main() {
        _=NSApplication.shared
        let panel=SwitcherPanel(contentRect:.zero,styleMask:[.borderless],backing:.buffered,defer:false)
        guard !panel.hidesOnDeactivate else { fputs("FAIL: switcher hides when another app is active\n",stderr);exit(1) }
        guard panel.styleMask.contains(.nonactivatingPanel) else { fputs("FAIL: switcher requires app activation\n",stderr);exit(1) }
        guard panel.canBecomeKey && !panel.canBecomeMain else { exit(1) }
        print("PASS: background panel visibility and keyboard focus configuration")
    }
}
