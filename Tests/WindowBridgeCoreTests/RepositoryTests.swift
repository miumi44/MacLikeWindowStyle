import Foundation
@main struct RepositoryTests {
    static func main() throws {
        let home=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:home) }
        try FileManager.default.createDirectory(at:home.appendingPathComponent(".config/karabiner"),withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:home.appendingPathComponent(".config/linearmouse"),withIntermediateDirectories:true)
        let original=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
        let keyboard=home.appendingPathComponent(".config/karabiner/karabiner.json")
        try original.write(to:keyboard)
        try Data("{\"schemes\":[{\"if\":{\"device\":{\"category\":\"mouse\"}},\"scrolling\":{\"reverse\":false}}]}".utf8).write(to:home.appendingPathComponent(".config/linearmouse/linearmouse.json"))
        let repo=InputSettingsRepository(home:home,runner:{ args in
            if args[0].contains("hidutil") { return Data("( { HIDKeyboardModifierMappingSrc = 30064771216; HIDKeyboardModifierMappingDst = 30064771129; } )".utf8) }
            return Data("0\n".utf8)
        })
        let snapshot=try repo.load()
        let noop=try repo.apply(snapshot:snapshot,features:[:],reverse:nil,smooth:nil,distance:nil,globalChanges:[:])
        assert(noop == nil && !FileManager.default.fileExists(atPath:repo.backupDirectory.path))
        _=try repo.apply(snapshot:snapshot,features:[.altF4:false],reverse:nil,smooth:nil,distance:nil,globalChanges:[:])
        assert(tryState(repo) == .off)
        assert(repo.latestBackup != nil)
        do { _=try repo.apply(snapshot:snapshot,features:[.rename:false],reverse:nil,smooth:nil,distance:nil,globalChanges:[:]);fatalError("stale snapshot accepted") } catch InputConfigurationError.conflict {}
        try repo.restoreLatest()
        let restored=try Data(contentsOf:keyboard)
        assert(restored == original)
        _=try repo.apply(snapshot:try repo.load(),features:[.altF4:false],reverse:nil,smooth:nil,distance:nil,globalChanges:[:])
        try Data("external change".utf8).write(to:keyboard)
        do { try repo.restoreLatest();fatalError("external edit overwritten") } catch InputConfigurationError.conflict {}
        try original.write(to:keyboard)
        let agentDir=home.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at:agentDir,withIntermediateDirectories:true)
        let agent:[String:Any]=["Label":"com.codex.hangul-key-remap","RunAtLoad":true,"ProgramArguments":["/usr/bin/hidutil","property","--set","{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":0x700000090,\"HIDKeyboardModifierMappingDst\":0x700000039},{\"HIDKeyboardModifierMappingSrc\":987,\"HIDKeyboardModifierMappingDst\":654}]}"]]
        let agentFile=agentDir.appendingPathComponent("com.codex.hangul-key-remap.plist")
        let agentBefore=try PropertyListSerialization.data(fromPropertyList:agent,format:.xml,options:0)
        try agentBefore.write(to:agentFile)
        var liveHID=try PropertyListSerialization.data(fromPropertyList:[["HIDKeyboardModifierMappingSrc":UInt64(0x700000090),"HIDKeyboardModifierMappingDst":UInt64(0x700000039)],["HIDKeyboardModifierMappingSrc":UInt64(123),"HIDKeyboardModifierMappingDst":UInt64(456)]],format:.xml,options:0)
        let initialHID=liveHID
        var failWrite=false
        var hidFailures=0
        var launchctlCalls=0
        var globalWriteCount=0
        var hidSetCount=0
        let hidRepo=InputSettingsRepository(home:home,runner:{ args in
            if args[0].contains("hidutil") {
                if args.contains("--get") { return liveHID }
                hidSetCount += 1
                if hidFailures > 0 { hidFailures -= 1;throw InputConfigurationError.invalid("injected HID failure") }
                let j=try JSONSerialization.jsonObject(with:Data(args.last!.utf8)) as! [String:Any]
                liveHID=try PropertyListSerialization.data(fromPropertyList:j["UserKeyMapping"]!,format:.xml,options:0)
            }
            if args[0].contains("launchctl") { launchctlCalls += 1 }
            if args[0].contains("defaults") && args.contains("write") { globalWriteCount += 1 }
            if args[0].contains("defaults") && args.contains("write") && failWrite { failWrite=false;throw InputConfigurationError.invalid("injected failure") }
            return Data("0\n".utf8)
        })
        _=try hidRepo.apply(snapshot:try hidRepo.load(),features:[.hangul:false],reverse:nil,smooth:nil,distance:nil,globalChanges:[:])
        let mappings=try PropertyListSerialization.propertyList(from:liveHID,options:[],format:nil) as! [[String:NSNumber]]
        assert(mappings.count == 1 && mappings[0]["HIDKeyboardModifierMappingSrc"]?.uint64Value == 123)
        let agentApplied=try PropertyListSerialization.propertyList(from:Data(contentsOf:agentFile),options:[],format:nil) as! [String:Any]
        let agentArgs=agentApplied["ProgramArguments"] as! [String]
        let payload=try JSONSerialization.jsonObject(with:Data(agentArgs[3].utf8)) as! [String:Any]
        let loginMappings=payload["UserKeyMapping"] as! [[String:NSNumber]]
        assert(loginMappings.count == 1 && loginMappings[0]["HIDKeyboardModifierMappingSrc"]?.uint64Value == 987,"login-only mapping lost")
        try hidRepo.restoreLatest()
        assert(liveHID == initialHID)
        let restoredAgent=try Data(contentsOf:agentFile)
        assert(restoredAgent == agentBefore)
        let mouseURL=home.appendingPathComponent(".config/linearmouse/linearmouse.json")
        let mouseBefore=try Data(contentsOf:mouseURL)
        failWrite=true
        do { _=try hidRepo.apply(snapshot:try hidRepo.load(),features:[:],reverse:true,smooth:nil,distance:nil,globalChanges:["AppleMomentumScrollSupported":"1"]);fatalError("injected failure ignored") } catch {}
        let mouseAfter=try Data(contentsOf:mouseURL)
        assert(mouseAfter == mouseBefore)
        hidFailures=2
        let globalsBefore=globalWriteCount
        let setsBefore=hidSetCount
        do { _=try hidRepo.apply(snapshot:try hidRepo.load(),features:[.hangul:false],reverse:nil,smooth:nil,distance:nil,globalChanges:["AppleMomentumScrollSupported":"1"]);fatalError("HID failure ignored") } catch {}
        assert(hidSetCount == setsBefore+2,"live HID recovery not attempted")
        assert(globalWriteCount > globalsBefore,"global recovery skipped after HID recovery failure")
        assert(launchctlCalls == 0,"one-shot login agent must not run during live mapping updates")
        assert(hidRepo.pendingRecovery != nil && hidRepo.canRetryRecovery)
        try hidRepo.restoreLatest()
        assert(hidRepo.pendingRecovery == nil)
        let recoveredKeyboard=try Data(contentsOf:keyboard)
        assert(recoveredKeyboard == original)
        print("PASS: no-op, backup/restore, conflicts, independent login/live mappings, rollback and failed-recovery retry")
    }
    static func tryState(_ repo:InputSettingsRepository) -> FeatureState { try! repo.load().keyboard.state(.altF4) }
}
