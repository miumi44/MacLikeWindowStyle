import AppKit
import WindowBridgeCore

@MainActor final class UnifiedSettingsController:NSObject {
    let window:NSWindow
    private let repository=InputSettingsRepository()
    private var snapshot:InputSnapshot?
    private var featureButtons:[InputFeature:NSButton]=[:]
    private let reverse=NSButton(checkboxWithTitle:"LinearMouse에서 휠 방향 한 번 더 반전",target:nil,action:nil)
    private let smooth=NSButton(checkboxWithTitle:"부드러운 스크롤",target:nil,action:nil)
    private let natural=NSButton(checkboxWithTitle:"macOS 자연스러운 스크롤",target:nil,action:nil)
    private let momentum=NSButton(checkboxWithTitle:"macOS 관성 스크롤",target:nil,action:nil)
    private let distance=NSPopUpButton()
    private let scaling=NSPopUpButton()
    private let feedback=NSTextField(wrappingLabelWithString:"")
    private let profile=NSTextField(labelWithString:"")
    private let backupLabel=NSTextField(wrappingLabelWithString:"")
    private var applyButton:NSButton!
    private var restoreButton:NSButton!
    private var baseline:[InputFeature:NSControl.StateValue]=[:]
    private var busy=false
    init(switcherView:NSView) {
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:720,height:700),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.title="WindowBridge · Windows 스타일 설정";window.isReleasedWhenClosed=false;window.center()
        super.init()
        let root=NSStackView();root.orientation = .vertical;root.alignment = .leading;root.spacing=12
        root.translatesAutoresizingMaskIntoConstraints=false;window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:24),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-24),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:22),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-20)])
        let title=NSTextField(labelWithString:"Windows 스타일, 한곳에서.");title.font = .systemFont(ofSize:23,weight:.semibold);root.addArrangedSubview(title)
        root.addArrangedSubview(note("키보드·마우스는 ‘변경 적용’을 눌러 저장합니다. 창 전환 켜기/끄기는 즉시 적용됩니다."))
        let tabs=NSTabView();tabs.translatesAutoresizingMaskIntoConstraints=false
        for (name,view) in [("키보드",keyboardPane()),("마우스",mousePane()),("창 전환",switcherView),("백업·복원",backupPane())] {
            let item=NSTabViewItem(identifier:name);item.label=name;item.view=view;tabs.addTabViewItem(item)
        }
        root.addArrangedSubview(tabs);tabs.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true
        tabs.heightAnchor.constraint(greaterThanOrEqualToConstant:450).isActive=true
        let actions=NSStackView();actions.spacing=10
        applyButton=button("변경 적용",#selector(apply));applyButton.bezelColor = .controlAccentColor
        actions.addArrangedSubview(applyButton);actions.addArrangedSubview(button("다시 읽기",#selector(reload)))
        actions.addArrangedSubview(button("Windows 권장값",#selector(recommended)));root.addArrangedSubview(actions)
        feedback.font = .systemFont(ofSize:12);feedback.textColor = .secondaryLabelColor;root.addArrangedSubview(feedback)
        reload()
    }
    private func button(_ title:String,_ selector:Selector) -> NSButton { NSButton(title:title,target:self,action:selector) }
    private func note(_ text:String) -> NSTextField {
        let n=NSTextField(wrappingLabelWithString:text);n.font = .systemFont(ofSize:12);n.textColor = .secondaryLabelColor;return n
    }
    private func pane() -> NSStackView {
        let stack=NSStackView();stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=11
        stack.edgeInsets=NSEdgeInsets(top:20,left:18,bottom:18,right:18);return stack
    }
    private func keyboardPane() -> NSView {
        let s=pane();s.addArrangedSubview(profile)
        for feature in InputFeature.allCases {
            let b=NSButton(checkboxWithTitle:feature.title,target:nil,action:nil);b.allowsMixedState=true
            featureButtons[feature]=b;s.addArrangedSubview(b)
        }
        s.addArrangedSubview(note("한영키는 기존 Caps Lock 입력 소스 전환을 사용합니다. Ctrl+C/V/A를 켜면 왼쪽 Ctrl만 Command로 바뀌며, 오른쪽 Ctrl은 IDE 통합 터미널의 인터럽트용으로 유지됩니다. Shift+Delete는 Finder 확인 창을 거칩니다."))
        s.addArrangedSubview(button("Karabiner 고급 설정 열기",#selector(openKarabiner)))
        return s
    }
    private func mousePane() -> NSView {
        let s=pane();s.addArrangedSubview(note("현재 마우스 전체에 적용합니다. 장치별 사용자 규칙은 유지됩니다."))
        s.addArrangedSubview(natural);s.addArrangedSubview(reverse);s.addArrangedSubview(smooth)
        distance.addItems(withTitles:(1...20).map(String.init));scaling.addItems(withTitles:["0.125","0.25","0.5","1","2"])
        let row=NSStackView();row.spacing=10;row.addArrangedSubview(NSTextField(labelWithString:"휠 이동 간격"));row.addArrangedSubview(distance);s.addArrangedSubview(row)
        s.addArrangedSubview(momentum)
        let speed=NSStackView();speed.spacing=10;speed.addArrangedSubview(NSTextField(labelWithString:"macOS 기본 휠 배율"));speed.addArrangedSubview(scaling);s.addArrangedSubview(speed)
        s.addArrangedSubview(note("Windows 권장값: 자연스러운 스크롤·추가 반전·부드러운 스크롤·관성 끄기. LinearMouse가 휠 간격을 처리하므로 macOS 배율의 체감은 앱마다 다를 수 있습니다."))
        s.addArrangedSubview(button("LinearMouse 고급 설정 열기",#selector(openLinearMouse)))
        return s
    }
    private func backupPane() -> NSView {
        let s=pane();s.addArrangedSubview(note("적용 전 원본을 자동 보관합니다. 다른 앱에서 이후 설정을 바꾼 경우에는 덮어쓰지 않고 복원을 멈춥니다."))
        backupLabel.maximumNumberOfLines=4;s.addArrangedSubview(backupLabel)
        restoreButton=button("마지막 적용 되돌리기",#selector(restore));s.addArrangedSubview(restoreButton)
        s.addArrangedSubview(button("백업 폴더 열기",#selector(openBackups)))
        s.addArrangedSubview(note("백업은 이 Mac의 사용자 폴더에만 저장됩니다. WindowBridge는 설정 화면을 여는 것만으로 입력 설정을 바꾸지 않습니다."))
        return s
    }
    private func state(_ value:FeatureState) -> NSControl.StateValue { value == .on ? .on : value == .mixed ? .mixed:.off }
    private func updateBackup() {
        if let pending=repository.pendingRecovery {
            restoreButton.title="미완료 복구 재시도";restoreButton.isEnabled=repository.canRetryRecovery
            backupLabel.stringValue="미완료 복구가 있습니다. 백업 폴더: \(pending.deletingLastPathComponent().path)"
            applyButton.isEnabled=false
            return
        }
        restoreButton.title="마지막 적용 되돌리기"
        restoreButton.isEnabled=repository.latestBackup != nil
        backupLabel.stringValue=repository.latestBackup.map { "마지막 적용 백업: \($0.lastPathComponent)" } ?? "아직 WindowBridge에서 적용한 변경이 없습니다. 현재 설정은 그대로 보존됩니다."
    }
    @objc private func reload() {
        guard !busy else { return }
        do {
            let current=try repository.load();snapshot=current
            let keyboard=current.keyboard;profile.stringValue="현재 키보드 프로필: \(keyboard.profileName)"
            baseline=[:]
            for feature in InputFeature.allCases {
                let currentState=keyboard.state(feature);let value=state(currentState)
                featureButtons[feature]?.state=value;featureButtons[feature]?.isEnabled=currentState != .unavailable
                featureButtons[feature]?.toolTip = currentState == .unavailable ? "기존 관리 규칙을 찾지 못했습니다. 고급 설정에서 확인해 주세요." : feature == .ctrlEditing && currentState == .mixed ? "기존 Ctrl+C/V/A 규칙은 왼쪽·오른쪽 Ctrl을 구분하지 않고 일부 개발 도구에서 제외합니다. 켜고 적용하면 왼쪽 Ctrl만 모든 대상 앱에 적용합니다.":nil
                baseline[feature]=value
            }
            reverse.state=current.mouse.reverse ? .on:.off;smooth.state=current.mouse.smooth ? .on:.off
            let currentDistance=String(current.mouse.distance)
            if !distance.itemTitles.contains(currentDistance) { distance.addItem(withTitle:currentDistance) }
            distance.selectItem(withTitle:currentDistance)
            natural.allowsMixedState=true;momentum.allowsMixedState=true
            natural.state=current.globals["com.apple.swipescrolldirection"].map { $0 == "1" ? .on:.off } ?? .mixed
            momentum.state=current.globals["AppleMomentumScrollSupported"].map { $0 == "1" ? .on:.off } ?? .mixed
            let scale=current.globals["com.apple.scrollwheel.scaling"] ?? "시스템 기본값"
            if !scaling.itemTitles.contains(scale) { scaling.addItem(withTitle:scale) };scaling.selectItem(withTitle:scale)
            feedback.stringValue="현재 설정을 읽었습니다. 체크만 바꾸고 적용하지 않으면 저장되지 않습니다."
            applyButton.isEnabled=true;updateBackup()
        } catch { snapshot=nil;applyButton.isEnabled=false;feedback.stringValue=error.localizedDescription;updateBackup() }
    }
    @objc private func recommended() {
        guard !busy else { return }
        for b in featureButtons.values where b.isEnabled { b.state = .on }
        reverse.state = .off;smooth.state = .off;natural.state = .off;momentum.state = .off
        distance.selectItem(withTitle:"3");scaling.selectItem(withTitle:"0.25")
        feedback.stringValue="Windows 권장값을 선택했습니다. ‘변경 적용’을 눌러 저장하세요."
    }
    @objc private func apply() {
        guard !busy,let snapshot else { return }
        var changes:[InputFeature:Bool]=[:]
        for (feature,b) in featureButtons where b.isEnabled && b.state != baseline[feature] && b.state != .mixed { changes[feature]=b.state == .on }
        var globals:[String:String]=[:]
        for (key,b) in [("com.apple.swipescrolldirection",natural),("AppleMomentumScrollSupported",momentum)] where b.state != .mixed {
            let value=b.state == .on ? "1":"0";if snapshot.globals[key] != value { globals[key]=value }
        }
        if let value=scaling.titleOfSelectedItem,Double(value) != nil,snapshot.globals["com.apple.scrollwheel.scaling"] != value { globals["com.apple.scrollwheel.scaling"]=value }
        let mouse=snapshot.mouse
        do {
            let backup=try repository.apply(snapshot:snapshot,features:changes,
                reverse:(reverse.state == .on) != mouse.reverse ? reverse.state == .on:nil,
                smooth:(smooth.state == .on) != mouse.smooth ? smooth.state == .on:nil,
                distance:Double(distance.titleOfSelectedItem ?? "3") != mouse.distance ? Double(distance.titleOfSelectedItem ?? "3"):nil,globalChanges:globals)
            reload();feedback.stringValue=backup == nil ? "변경된 설정이 없습니다. 파일을 수정하지 않았습니다.":"적용했습니다. ‘백업·복원’에서 마지막 적용을 되돌릴 수 있습니다."
        } catch { feedback.stringValue=error.localizedDescription;updateBackup() }
    }
    @objc private func restore() {
        guard !busy else { return }
        do { try repository.restoreLatest();reload();feedback.stringValue="마지막 적용 이전 설정으로 복원했습니다." }
        catch { feedback.stringValue=error.localizedDescription }
    }
    @objc private func openBackups() {
        try? FileManager.default.createDirectory(at:repository.backupDirectory,withIntermediateDirectories:true)
        NSWorkspace.shared.open(repository.backupDirectory)
    }
    @objc private func openKarabiner() { NSWorkspace.shared.open(URL(fileURLWithPath:"/Applications/Karabiner-Elements.app")) }
    @objc private func openLinearMouse() { NSWorkspace.shared.open(URL(fileURLWithPath:"/Applications/LinearMouse.app")) }
    func refreshWhenOpened() { reload() }
}
