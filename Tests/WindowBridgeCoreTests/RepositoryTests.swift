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

        let mouseFixture=Data(#"{"unknown":42,"schemes":[{"if":{"device":{"category":"mouse"}},"scrolling":{"reverse":false,"distance":{"vertical":3,"horizontal":7}}},{"if":{"device":{"category":"trackpad"}},"custom":true}]}"#.utf8)

        let conflictHome=home.appendingPathComponent("hangul-conflict",isDirectory:true)
        try seed(conflictHome,keyboard:original,mouse:mouseFixture)
        let conflictMappings:[[String:UInt64]]=[["HIDKeyboardModifierMappingSrc":0x700000090,"HIDKeyboardModifierMappingDst":0x70000003a]]
        let conflictHID=try PropertyListSerialization.data(fromPropertyList:conflictMappings,format:.xml,options:0)
        let conflictLoginMappings:[[String:UInt64]]=[["HIDKeyboardModifierMappingSrc":0x700000090,"HIDKeyboardModifierMappingDst":0x700000039]]
        let loginPayload=try JSONSerialization.data(withJSONObject:["UserKeyMapping":conflictLoginMappings],options:[.sortedKeys])
        let loginAgent:[String:Any]=["Label":"com.codex.hangul-key-remap","RunAtLoad":true,"ProgramArguments":["/usr/bin/hidutil","property","--set",String(data:loginPayload,encoding:.utf8)!]]
        let loginAgentData=try PropertyListSerialization.data(fromPropertyList:loginAgent,format:.xml,options:0)
        let conflictAgentURL=conflictHome.appendingPathComponent("Library/LaunchAgents/com.codex.hangul-key-remap.plist")
        try FileManager.default.createDirectory(at:conflictAgentURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        try loginAgentData.write(to:conflictAgentURL)
        let conflictKeyboardURL=conflictHome.appendingPathComponent(".config/karabiner/karabiner.json")
        let conflictMouseURL=conflictHome.appendingPathComponent(".config/linearmouse/linearmouse.json")
        var conflictSetCount=0
        let conflictRepo=InputSettingsRepository(home:conflictHome,runner:{ args in
            if args[0] == "/usr/bin/hidutil" {
                if args.contains("--set") { conflictSetCount += 1 }
                return conflictHID
            }
            return Data("0\n".utf8)
        })
        var rejectedConflict=false
        do { _=try conflictRepo.apply(snapshot:try conflictRepo.load(),features:[.hangul:true],reverse:nil,smooth:nil,distance:nil,globalChanges:[:]) }
        catch InputConfigurationError.invalid { rejectedConflict=true }
        assert(rejectedConflict,"conflicting live Hangul mapping was accepted")
        assert(conflictSetCount == 0,"conflicting Hangul mapping reached hidutil write")
        let keyboardAfterConflict=try Data(contentsOf:conflictKeyboardURL)
        let mouseAfterConflict=try Data(contentsOf:conflictMouseURL)
        let agentAfterConflict=try Data(contentsOf:conflictAgentURL)
        assert(keyboardAfterConflict == original)
        assert(mouseAfterConflict == mouseFixture)
        assert(agentAfterConflict == loginAgentData)
        assert(conflictRepo.latestBackup == nil,"conflicting mapping created a backup")

        let persistHome=home.appendingPathComponent("mouse-global-persistence",isDirectory:true)
        try seed(persistHome,keyboard:original,mouse:mouseFixture)
        let persistMouseURL=persistHome.appendingPathComponent(".config/linearmouse/linearmouse.json")
        let persistMouseBefore=try Data(contentsOf:persistMouseURL)
        var liveGlobals=["com.apple.swipescrolldirection":"1","AppleMomentumScrollSupported":"0"]
        let persistRepo=InputSettingsRepository(home:persistHome,runner:{ args in
            if args[0] == "/usr/bin/hidutil" { return Data("(null)".utf8) }
            if args[0] == "/usr/bin/defaults" {
                if args[1] == "read" {
                    guard let value=liveGlobals[args[3]] else { throw NSError(domain:"RepositoryTests",code:1) }
                    return Data("\(value)\n".utf8)
                }
                if args[1] == "write" { liveGlobals[args[3]]=args.last!;return Data() }
                if args[1] == "delete" { liveGlobals.removeValue(forKey:args[3]);return Data() }
            }
            return Data("0\n".utf8)
        })
        let originalGlobals=liveGlobals
        _=try persistRepo.apply(snapshot:try persistRepo.load(),features:[:],reverse:true,smooth:true,distance:5,globalChanges:["com.apple.swipescrolldirection":"0","AppleMomentumScrollSupported":"1","com.apple.scrollwheel.scaling":"2"])
        let appliedMouse=try MouseConfiguration(data:Data(contentsOf:persistMouseURL))
        assert(appliedMouse.reverse && appliedMouse.smooth && appliedMouse.distance == 5,"mouse settings were not persisted")
        assert(liveGlobals == ["com.apple.swipescrolldirection":"0","AppleMomentumScrollSupported":"1","com.apple.scrollwheel.scaling":"2"],"global preferences were not persisted")
        let appliedSchemes=(try JSONSerialization.jsonObject(with:Data(contentsOf:persistMouseURL)) as! [String:Any])["schemes"] as! [[String:Any]]
        assert(appliedSchemes[1]["custom"] as? Bool == true,"unrelated mouse scheme was lost")
        assert(persistRepo.latestBackup != nil)
        try persistRepo.restoreLatest()
        let restoredMouse=try Data(contentsOf:persistMouseURL)
        assert(restoredMouse == persistMouseBefore,"mouse settings were not restored")
        assert(liveGlobals == originalGlobals,"global preferences, including an originally absent value, were not restored")
        assert(persistRepo.latestBackup == nil)

        let retryHome=home.appendingPathComponent("restore-retry",isDirectory:true)
        try seed(retryHome,keyboard:original,mouse:mouseFixture)
        let retryMouseURL=retryHome.appendingPathComponent(".config/linearmouse/linearmouse.json")
        let retryMouseBefore=try Data(contentsOf:retryMouseURL)
        var retryGlobals=["com.apple.swipescrolldirection":"1"]
        var injectRestoreFailures=false
        var failedRestoreWrite=false
        var failedRollbackWrite=false
        let retryRepo=InputSettingsRepository(home:retryHome,runner:{ args in
            if args[0] == "/usr/bin/hidutil" { return Data("(null)".utf8) }
            if args[0] == "/usr/bin/defaults" {
                if args[1] == "read" {
                    guard let value=retryGlobals[args[3]] else { throw NSError(domain:"RepositoryTests",code:1) }
                    return Data("\(value)\n".utf8)
                }
                if args[1] == "write" {
                    let key=args[3],value=args.last!
                    if injectRestoreFailures && key == "com.apple.swipescrolldirection" {
                        if value == "1" && !failedRestoreWrite { failedRestoreWrite=true;throw NSError(domain:"RepositoryTests",code:2) }
                        if value == "0" && !failedRollbackWrite { failedRollbackWrite=true;throw NSError(domain:"RepositoryTests",code:3) }
                    }
                    retryGlobals[key]=value;return Data()
                }
                if args[1] == "delete" { retryGlobals.removeValue(forKey:args[3]);return Data() }
            }
            return Data("0\n".utf8)
        })
        _=try retryRepo.apply(snapshot:try retryRepo.load(),features:[:],reverse:true,smooth:nil,distance:nil,globalChanges:["com.apple.swipescrolldirection":"0"])
        let mouseAfterApply=try Data(contentsOf:retryMouseURL)
        injectRestoreFailures=true
        var restoreFailed=false
        do { try retryRepo.restoreLatest() } catch { restoreFailed=true }
        assert(restoreFailed && failedRestoreWrite && failedRollbackWrite,"restore failure and rollback failure were not both exercised")
        assert(retryRepo.pendingRecovery != nil && retryRepo.canRetryRecovery,"failed restore did not preserve a retryable recovery")
        assert(retryRepo.latestBackup != nil,"failed restore discarded its original backup")
        let mouseAfterFailedRestore=try Data(contentsOf:retryMouseURL)
        assert(mouseAfterFailedRestore == mouseAfterApply,"failed restore did not return files to the applied state")
        assert(retryGlobals["com.apple.swipescrolldirection"] == "0","failed restore changed the applied global preference")
        try retryRepo.restoreLatest()
        let mouseAfterRetry=try Data(contentsOf:retryMouseURL)
        assert(mouseAfterRetry == retryMouseBefore,"retry did not restore the original mouse settings")
        assert(retryGlobals == ["com.apple.swipescrolldirection":"1"],"retry did not restore the original global preference")
        assert(retryRepo.pendingRecovery == nil && retryRepo.latestBackup == nil,"successful retry left recovery state behind")

        print("PASS: no-op, backup/restore, conflicts, Hangul safety, mouse/global persistence, rollback and failed-recovery retry")
    }
    static func tryState(_ repo:InputSettingsRepository) -> FeatureState { try! repo.load().keyboard.state(.altF4) }

    static func seed(_ home:URL,keyboard:Data,mouse:Data) throws {
        let keyboardURL=home.appendingPathComponent(".config/karabiner/karabiner.json")
        let mouseURL=home.appendingPathComponent(".config/linearmouse/linearmouse.json")
        try FileManager.default.createDirectory(at:keyboardURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:mouseURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        try keyboard.write(to:keyboardURL)
        try mouse.write(to:mouseURL)
    }
}
