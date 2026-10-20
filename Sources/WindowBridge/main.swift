import AppKit
import ApplicationServices
import ScreenCaptureKit
import WindowBridgeCore

@MainActor final class AppDelegate: NSObject,NSApplicationDelegate,NSWindowDelegate,NSMenuDelegate {
    let store = WindowStore()
    let hook = HotKey()
    let grid = SwitcherView()
    var panel: SwitcherPanel!
    var settings: NSWindow!
    var unifiedSettings: UnifiedSettingsController?
    var status: NSStatusItem!
    var message: NSTextField!
    var toggle: NSButton!
    var hoverToggle:NSButton!
    var tileToggle:NSButton!
    var windowActionTarget:(session:Int,target:WindowTiler.Target)?
    var menuWindowTarget:WindowTiler.Target?
    var windowActionBusy=false
    var windowActionTask:Task<Void,Never>?
    var timer: Timer?
    var thumbnailTask: Task<Void,Never>?
    var selection = WindowSelection()
    var presenting = false
    var isDemo = false
    var refreshing = false
    var showGeneration = 0
    var hotkeySession: Int?

    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApp.setActivationPolicy(.accessory)
        let menu=NSMenu();let root=NSMenuItem();let sub=NSMenu()
        sub.addItem(withTitle:"WindowBridge 종료",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        root.submenu=sub;menu.addItem(root);NSApp.mainMenu=menu
        panel=SwitcherPanel(contentRect:NSRect(x:0,y:0,width:1010,height:545),styleMask:[.borderless],backing:.buffered,defer:false)
        panel.title="WindowBridge 미리보기"
        panel.appearance=NSAppearance(named:.darkAqua)
        panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=true;panel.level = .floating
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary];panel.contentView=grid
        grid.onStep = { [weak self] d in self?.step(d) }
        grid.onRow = { [weak self] d in self?.moveRow(d) }
        grid.onCancel = { [weak self] in self?.dismiss() }
        grid.onPick = { [weak self] id in self?.commit(id) }
        store.onChange = { [weak self] in self?.updateGrid() }
        hook.onTab = { [weak self] session,reverse in self?.hotTab(session,reverse) }
        hook.onRelease = { [weak self] session in guard self?.hotkeySession == session else{return};self?.releaseSelection() }
        hook.onEscape = { [weak self] session in guard self?.hotkeySession == session else{return};self?.dismiss() }
        hook.onWindowActionStart = { [weak self] session in
            guard let self,!self.presenting,!self.windowActionBusy,self.tileToggle.state == .on else { return }
            self.windowActionTarget=WindowTiler.captureTarget().map { (session,$0) }
        }
        hook.onWindowActionCancel = { [weak self] in self?.windowActionTarget=nil }
        hook.onWindowAction = { [weak self] session,action in
            guard let self,self.tileToggle.state == .on,let captured=self.windowActionTarget,captured.session == session else { return }
            self.windowActionTarget=nil
            self.performWindowAction(action,target:captured.target)
        }
        status=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        status.button?.image=NSImage(systemSymbolName:"rectangle.3.group",accessibilityDescription:"WindowBridge")
        status.button?.toolTip="WindowBridge · 창 전환"
        let sm=NSMenu();sm.delegate=self
        sm.addItem(withTitle:"창 전환 사용",action:#selector(toggleFromMenu),keyEquivalent:"").target=self
        sm.addItem(withTitle:"창 미리보기",action:#selector(loadWindows),keyEquivalent:"").target=self
        let layoutItem=NSMenuItem(title:"창 배치",action:nil,keyEquivalent:"")
        let layoutMenu=NSMenu()
        for (title,selector) in [("왼쪽 절반",#selector(tileLeft)),("오른쪽 절반",#selector(tileRight)),("위쪽 절반",#selector(tileUp)),("아래쪽 절반",#selector(tileDown)),("최대화 / 이전 크기",#selector(maximizeWindow)),("배치 전 크기로 복원",#selector(restoreWindow)),("현재 창 최소화",#selector(minimizeWindow))] {
            layoutMenu.addItem(withTitle:title,action:selector,keyEquivalent:"").target=self
        }
        layoutItem.submenu=layoutMenu;sm.addItem(layoutItem)
        sm.addItem(.separator())
        sm.addItem(withTitle:"설정…",action:#selector(openSettings),keyEquivalent:",").target=self
        sm.addItem(.separator())
        sm.addItem(withTitle:"WindowBridge 종료",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        status.menu=sm
        grid.hoverEnabled=UserDefaults.standard.object(forKey:"hoverFeedbackEnabled") as? Bool ?? true
        makeSettings();openSettings()
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(willSleep),name:NSWorkspace.willSleepNotification,object:nil)
    }
    func makeSettings() {
        makeWindowSwitcherSettings()
        let switching=settings.contentView!
        settings.contentView=nil
        let controller=UnifiedSettingsController(switcherView:switching)
        unifiedSettings=controller;settings=controller.window
    }
    func makeWindowSwitcherSettings() {
        settings=NSWindow(contentRect:NSRect(x:0,y:0,width:590,height:430),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        settings.title="WindowBridge 설정";settings.isReleasedWhenClosed=false;settings.center()
        let stack=NSStackView();stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=10
        stack.translatesAutoresizingMaskIntoConstraints=false;settings.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:settings.contentView!.leadingAnchor,constant:28),stack.trailingAnchor.constraint(equalTo:settings.contentView!.trailingAnchor,constant:-28),stack.topAnchor.constraint(equalTo:settings.contentView!.topAnchor,constant:28)])
        let title=NSTextField(labelWithString:"창 전환");title.font = .systemFont(ofSize:20,weight:.semibold);stack.addArrangedSubview(title)
        let desc=NSTextField(wrappingLabelWithString:"왼쪽 Alt + Tab으로 창 선택 · Alt를 놓으면 전환\n방향키로 상하좌우 이동 · 클릭/Enter로 선택 · Esc로 취소")
        desc.font = .systemFont(ofSize:13);desc.textColor = .secondaryLabelColor;stack.addArrangedSubview(desc)
        let actions=NSStackView();actions.spacing=10
        actions.addArrangedSubview(button("열린 창 미리보기",#selector(loadWindows)));stack.addArrangedSubview(actions)
        let perms=NSStackView();perms.spacing=10
        perms.addArrangedSubview(button("화면 기록 권한",#selector(screenPermission)))
        perms.addArrangedSubview(button("손쉬운 사용 권한",#selector(accessPermission)));stack.addArrangedSubview(perms)
        toggle=NSButton(checkboxWithTitle:"백그라운드에서 왼쪽 Alt+Tab 사용",target:self,action:#selector(toggleHotkey));stack.addArrangedSubview(toggle)
        tileToggle=NSButton(checkboxWithTitle:"Command + 왼쪽 Alt 창 관리 단축키 (실험)",target:self,action:#selector(toggleTiling))
        stack.addArrangedSubview(tileToggle)
        let layoutHelp=NSTextField(wrappingLabelWithString:"← → ↑ ↓: 절반 배치 · Return: 최대화/복원 · M: 최소화\n동작키와 Command·Alt를 모두 놓으면 실행됩니다. 메뉴의 ‘창 배치’로도 사용할 수 있습니다.")
        layoutHelp.font = .systemFont(ofSize:11);layoutHelp.textColor = .secondaryLabelColor;stack.addArrangedSubview(layoutHelp)
        hoverToggle=NSButton(checkboxWithTitle:"마우스를 올린 카드 강조 효과",target:self,action:#selector(toggleHover))
        hoverToggle.state=grid.hoverEnabled ? .on:.off;stack.addArrangedSubview(hoverToggle)
        message=NSTextField(wrappingLabelWithString:"상단 메뉴 막대에서 창 전환을 켜고 끌 수 있습니다.\n실제 창 썸네일은 화면 기록, 창 전환은 손쉬운 사용 권한이 필요합니다.")
        message.maximumNumberOfLines=3;message.font = .systemFont(ofSize:12);message.textColor = .secondaryLabelColor;stack.addArrangedSubview(message)
        let note=NSTextField(wrappingLabelWithString:"키보드·마우스 탭의 변경은 적용 버튼으로 저장합니다.\n창 전환을 켤 때 BetterCmdTab이 실행 중이면 종료 여부를 확인합니다.")
        note.font = .systemFont(ofSize:11);note.textColor = .secondaryLabelColor;stack.addArrangedSubview(note)
    }
    func button(_ title:String,_ action:Selector)->NSButton { let b=NSButton(title:title,target:self,action:action);b.bezelStyle = .rounded;return b }
    @objc func openSettings() { unifiedSettings?.refreshWhenOpened();settings.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true) }
    @objc func preview() { guard !refreshing else { return };dismiss();store.demo();isDemo=true;show(reverse:false) }
    @objc func screenPermission() {
        if !CGPreflightScreenCaptureAccess() { _=CGRequestScreenCaptureAccess() }
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        message.stringValue="WindowBridge의 화면 기록을 허용한 뒤 필요하면 앱을 다시 실행해 주세요."
    }
    @objc func accessPermission() {
        _=AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary)
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func loadWindows() {
        guard CGPreflightScreenCaptureAccess() else { message.stringValue="먼저 ‘화면 기록 권한’을 허용해 주세요. 실제 화면은 권한 승인 후에만 읽습니다."; return }
        guard !refreshing else { return };refreshing=true
        Task { @MainActor in
            defer { refreshing=false }
            do { try await store.refresh();isDemo=false;show(reverse:false);message.stringValue="열린 창 \(store.windows.count)개를 불러왔습니다." }
            catch { message.stringValue="창 목록을 불러오지 못했습니다: \(error.localizedDescription)" }
        }
    }
    func performWindowAction(_ action:WindowAction,target:WindowTiler.Target) {
        guard !windowActionBusy,!presenting else { return }
        windowActionBusy=true
        windowActionTask=Task { @MainActor in
            defer { windowActionBusy=false;windowActionTask=nil }
            let result=await WindowTiler.perform(action:action,target:target)
            message.stringValue=result.components(separatedBy:" · 전 ").first ?? result;message.toolTip=result;status.button?.toolTip=result
        }
    }
    func menuWindowAction(_ action:WindowAction) {
        guard let target=menuWindowTarget else {
            message.stringValue="배치할 앱 창을 먼저 선택한 뒤 메뉴를 열어 주세요.";return
        }
        performWindowAction(action,target:target)
    }
    @objc func tileLeft() { menuWindowAction(.tile(.left)) }
    @objc func tileRight() { menuWindowAction(.tile(.right)) }
    @objc func tileUp() { menuWindowAction(.tile(.up)) }
    @objc func tileDown() { menuWindowAction(.tile(.down)) }
    @objc func maximizeWindow() { menuWindowAction(.toggleMaximize) }
    @objc func restoreWindow() { menuWindowAction(.restore) }
    @objc func minimizeWindow() { menuWindowAction(.minimize) }
    @objc func toggleTiling() {
        hook.cancelWindowAction()
        if tileToggle.state == .on && !AXIsProcessTrusted() {
            tileToggle.state = .off;message.stringValue="창 배치에는 손쉬운 사용 권한이 필요합니다.";return
        }
        hook.configure(switching:toggle.state == .on,tiling:tileToggle.state == .on)
        if tileToggle.state == .on {
            if !hook.start() { tileToggle.state = .off;hook.configure(switching:toggle.state == .on,tiling:false) }
        } else if toggle.state == .off { hook.stopIfUnused() }
        message.stringValue=tileToggle.state == .on ? "창 관리 단축키 켜짐 · 모든 키를 놓으면 실행합니다.":"창 관리 단축키를 껐습니다. 메뉴에서 창 배치는 사용할 수 있습니다."
    }
    @objc func toggleHover() {
        grid.hoverEnabled=hoverToggle.state == .on
        UserDefaults.standard.set(grid.hoverEnabled,forKey:"hoverFeedbackEnabled")
        grid.clearHover()
    }
    func menuWillOpen(_ menu:NSMenu) {
        menuWindowTarget=WindowTiler.captureTarget()
        menu.items.first(where:{$0.action == #selector(toggleFromMenu)})?.state=toggle.state
    }
    @objc func toggleFromMenu() {
        toggle.state = toggle.state == .on ? .off : .on
        toggleHotkey()
    }
    @objc func toggleHotkey() {
        guard toggle.state == .on else { hook.configure(switching:false,tiling:tileToggle.state == .on);if tileToggle.state == .off { hook.stopIfUnused() };timer?.invalidate();timer=nil;dismiss();message.stringValue="창 전환을 껐습니다. 상단 메뉴에서 다시 켤 수 있습니다.";return }
        guard AXIsProcessTrusted(),CGPreflightScreenCaptureAccess() else {
            toggle.state = .off;message.stringValue="화면 기록과 손쉬운 사용 권한을 먼저 허용해 주세요.";return
        }
        let competitors=NSRunningApplication.runningApplications(withBundleIdentifier:"pro.bettercmdtab.BetterCmdTab")
        if !competitors.isEmpty {
            let alert=NSAlert();alert.messageText="BetterCmdTab을 종료하고 테스트할까요?";alert.informativeText="두 앱이 Alt+Tab을 동시에 처리하지 않도록 BetterCmdTab을 종료합니다. 설정과 자동 실행 항목은 유지됩니다."
            alert.addButton(withTitle:"종료하고 테스트");alert.addButton(withTitle:"취소")
            guard alert.runModal() == .alertFirstButtonReturn else { toggle.state = .off;return }
            competitors.forEach { _=$0.terminate() }
        }
        hook.configure(switching:true,tiling:tileToggle.state == .on)
        guard hook.start() else {toggle.state = .off;message.stringValue="단축키를 등록하지 못했습니다. 손쉬운 사용 권한을 확인하고 앱을 다시 실행해 주세요.";return}
        isDemo=false;store.windows=[]
        message.stringValue="백그라운드 전환 켜짐 · 설정 창을 닫아도 작동합니다.\n왼쪽 Alt+Tab / Shift+Tab / Esc\n로그인 시 자동 실행은 아직 설정하지 않았습니다."
        Task { @MainActor in try? await store.refresh() }
        timer=Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in
            Task { @MainActor in guard let self,!self.presenting else{return};try? await self.store.refresh() }
        }
    }
    func hotTab(_ session:Int,_ reverse:Bool) {
        hook.cancelWindowAction()
        if presenting && hotkeySession == session { step(reverse ? -1:1);return }
        hotkeySession=session
        isDemo=false;show(reverse:reverse)
    }
    func show(reverse:Bool) {
        grid.clearHover()
        presenting=true;showGeneration += 1
        selection.begin(ids:store.windows.map(\.id),reverse:reverse)
        let count=min(9,max(1,store.windows.count));let columns=min(3,count);let rows=(count+columns-1)/columns
        let size=NSSize(width:CGFloat(columns)*310+56,height:CGFloat(rows)*210+115)
        let screen=NSScreen.screens.first(where:{$0.frame.contains(NSEvent.mouseLocation)}) ?? NSScreen.main!
        let visible=screen.visibleFrame;let scale=min(1,min((visible.width-40)/size.width,(visible.height-40)/size.height))
        panel.setContentSize(NSSize(width:size.width*scale,height:size.height*scale))
        grid.setBoundsSize(size)
        panel.setFrameOrigin(NSPoint(x:visible.midX-panel.frame.width/2,y:visible.midY-panel.frame.height/2))
        settings.orderOut(nil)
        updateGrid();panel.makeKeyAndOrderFront(nil);panel.makeFirstResponder(grid)
        if !isDemo { capturePage() }
    }
    func updateGrid() {
        guard presenting else{return}
        grid.items=store.windows;grid.selection=selection;grid.demo=isDemo;grid.needsDisplay=true
    }
    func capturePage() {
        let page=selection.index/9;let ids=Array(store.windows.dropFirst(page*9).prefix(9)).map(\.id)
        let ordered=thumbnailCaptureOrder(ids:ids,selected:selection.selected)
        let previous=thumbnailTask
        previous?.cancel()
        thumbnailTask=Task { @MainActor in
            // Let an already-running ScreenCaptureKit request finish before starting another.
            await previous?.value
            guard !Task.isCancelled else { return }
            await store.capture(ids:ordered)
        }
    }
    func step(_ delta:Int) { grid.clearHover();let oldPage=selection.index/9;selection.step(delta);updateGrid();if !isDemo && oldPage != selection.index/9 {capturePage()} }
    func moveRow(_ delta:Int) {
        grid.clearHover()
        let oldPage=selection.index/9
        selection.moveRow(delta,columns:min(3,max(1,selection.ids.count)))
        updateGrid()
        if !isDemo && oldPage != selection.index/9 { capturePage() }
    }
    func releaseSelection() { guard presenting,let id=selection.selected else {dismiss();return};commit(id) }
    func commit(_ id:UInt32) {
        if isDemo { dismiss();message.stringValue="디자인 미리보기입니다. ‘실제 창 불러오기’로 실제 창을 선택할 수 있습니다.";return }
        guard AXIsProcessTrusted() else { dismiss();message.stringValue="창 전환에는 손쉬운 사용 권한이 필요합니다.";return }
        dismiss()
        Task { @MainActor in
            if await store.activate(id) { message.stringValue="선택한 창의 실제 포커스 전환을 확인했습니다.";status.button?.toolTip="WindowBridge" }
            else {
                // A background verification failure must never interrupt the user or steal focus.
                message.stringValue="선택한 창으로 포커스가 이동하지 않았습니다. 창이 닫혔거나 접근이 제한되었을 수 있습니다."
                status.button?.toolTip=message.stringValue
            }
        }
    }
    func dismiss() { grid.clearHover();thumbnailTask?.cancel();presenting=false;showGeneration += 1;if let session=hotkeySession { hook.cancel(session:session) };hotkeySession=nil;panel.orderOut(nil);if isDemo { openSettings() } }
    @objc func willSleep() { windowActionTask?.cancel();hook.cancelWindowAction();dismiss() }
    func applicationWillTerminate(_ notification:Notification) {windowActionTask?.cancel();thumbnailTask?.cancel();hook.stop();timer?.invalidate()}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool)->Bool { openSettings();return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {false}
}
MainActor.assumeIsolated {
    let app=NSApplication.shared
    let delegate=AppDelegate();app.delegate=delegate
    withExtendedLifetime(delegate) { app.run() }
}
