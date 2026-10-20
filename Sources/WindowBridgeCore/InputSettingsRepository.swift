import Foundation

public struct InputSnapshot {
    public let keyboardData:Data
    public let mouseData:Data
    public let agentData:Data?
    public let hidData:Data
    public let globals:[String:String]
    public var keyboard:KeyboardConfiguration { try! KeyboardConfiguration(data:keyboardData) }
    public var mouse:MouseConfiguration { try! MouseConfiguration(data:mouseData) }
}
private struct InputBackup:Codable {
    var before:[String:Data]
    var after:[String:Data]
    var hidBefore:Data
    var hidAfter:Data
    var globalsBefore:[String:String]
    var globalsAfter:[String:String]
    var globalsChanged:[String]
    var hangulChanged:Bool
}
private struct PendingInputRecovery:Codable {
    let backup:InputBackup
    let expectedFiles:[String:Data]
    let expectedHID:Data?
    let expectedGlobals:[String:String]
    let complete:Bool
    let clearLatestOnSuccess:Bool
}
public final class InputSettingsRepository {
    public typealias Runner=([String]) throws -> Data
    private let home:URL
    private let run:Runner
    public let backupDirectory:URL
    private let keys=["com.apple.swipescrolldirection","AppleMomentumScrollSupported","com.apple.scrollwheel.scaling"]
    private let keyboardPath=".config/karabiner/karabiner.json"
    private let mousePath=".config/linearmouse/linearmouse.json"
    private let agentPath="Library/LaunchAgents/com.codex.hangul-key-remap.plist"
    public init(home:URL=FileManager.default.homeDirectoryForCurrentUser,runner:Runner?=nil) {
        self.home=home;self.run=runner ?? Self.execute
        backupDirectory=home.appendingPathComponent("Library/Application Support/WindowBridge/Backups",isDirectory:true)
    }
    private static func execute(_ args:[String]) throws -> Data {
        let p=Process();p.executableURL=URL(fileURLWithPath:args[0]);p.arguments=Array(args.dropFirst())
        let out=Pipe();let err=Pipe();p.standardOutput=out;p.standardError=err
        try p.run();let result=out.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let message=String(data:err.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) ?? "명령 실행 실패"
            throw NSError(domain:"WindowBridge",code:Int(p.terminationStatus),userInfo:[NSLocalizedDescriptionKey:message])
        }
        return result
    }
    private func file(_ path:String) -> URL { home.appendingPathComponent(path) }
    private func read(_ path:String) throws -> Data { try Data(contentsOf:file(path)) }
    private func globals() -> [String:String] {
        var values:[String:String]=[:]
        for key in keys {
            if let data=try? run(["/usr/bin/defaults","read","NSGlobalDomain",key]),let text=String(data:data,encoding:.utf8) {
                values[key]=text.trimmingCharacters(in:.whitespacesAndNewlines)
            }
        }
        return values
    }
    public func load() throws -> InputSnapshot {
        let kd=try read(keyboardPath);let md=try read(mousePath)
        _=try KeyboardConfiguration(data:kd);_=try MouseConfiguration(data:md)
        let hid=try run(["/usr/bin/hidutil","property","--get","UserKeyMapping"])
        _=try mappings(hid)
        return InputSnapshot(keyboardData:kd,mouseData:md,agentData:try? read(agentPath),hidData:hid,globals:globals())
    }
    private func mappings(_ data:Data) throws -> [[String:UInt64]] {
        let text=String(data:data,encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        if text == "(null)" || text == "null" { return [] }
        guard let array=try PropertyListSerialization.propertyList(from:data,options:[],format:nil) as? [[String:Any]] else { throw InputConfigurationError.invalid("hidutil 한영키") }
        return try normalizeMappings(array)
    }
    private func normalizeMappings(_ array:[[String:Any]]) throws -> [[String:UInt64]] {
        try array.map { entry in
            var result:[String:UInt64]=[:]
            for (key,value) in entry {
                if let number=value as? NSNumber { result[key]=number.uint64Value }
                else if let text=value as? String,let number=UInt64(text) { result[key]=number }
                else { throw InputConfigurationError.invalid("hidutil 숫자 매핑") }
            }
            guard result["HIDKeyboardModifierMappingSrc"] != nil,result["HIDKeyboardModifierMappingDst"] != nil else { throw InputConfigurationError.invalid("hidutil 매핑 필드") }
            return result
        }
    }
    private func hidPayload(_ array:[[String:UInt64]]) throws -> String {
        String(data:try JSONSerialization.data(withJSONObject:["UserKeyMapping":array],options:[.sortedKeys]),encoding:.utf8)!
    }
    private func applyHID(_ data:Data) throws { _=try run(["/usr/bin/hidutil","property","--set",try hidPayload(mappings(data))]) }
    private func globalSet(_ key:String,_ value:String?) throws {
        if let value {
            _=try run(["/usr/bin/defaults","write","NSGlobalDomain",key,key == "com.apple.scrollwheel.scaling" ? "-float":"-bool",value])
        } else { _=try run(["/usr/bin/defaults","delete","NSGlobalDomain",key]) }
    }
    private func write(_ values:[String:Data]) throws {
        for (path,data) in values { try data.write(to:file(path),options:.atomic) }
    }
    public func apply(snapshot:InputSnapshot,features:[InputFeature:Bool],reverse:Bool?,smooth:Bool?,distance:Double?,globalChanges:[String:String]) throws -> URL? {
        guard pendingRecovery == nil else { throw InputConfigurationError.invalid("미완료 복구가 있습니다. 백업·복원에서 먼저 복구") }
        let now=try load()
        guard now.keyboardData == snapshot.keyboardData,now.mouseData == snapshot.mouseData,now.agentData == snapshot.agentData else {
            throw InputConfigurationError.conflict
        }
        guard try mappings(now.hidData) == mappings(snapshot.hidData),now.globals == snapshot.globals else { throw InputConfigurationError.conflict }
        var keyboard=snapshot.keyboard;var mouse=snapshot.mouse
        for (feature,enabled) in features { keyboard.set(feature,enabled:enabled) }
        if let reverse { mouse.reverse=reverse };if let smooth { mouse.smooth=smooth };if let distance { mouse.distance=distance }
        var before=[String:Data]();var after=[String:Data]()
        if !features.isEmpty { before[keyboardPath]=snapshot.keyboardData;after[keyboardPath]=try keyboard.serialized() }
        if reverse != nil || smooth != nil || distance != nil { before[mousePath]=snapshot.mouseData;after[mousePath]=try mouse.serialized() }
        var hidAfter=snapshot.hidData
        if let hangul=features[.hangul] {
            func adjusted(_ original:[[String:UInt64]]) throws -> [[String:UInt64]] {
                var array=original
                let sources:Set<UInt64>=[0x700000090,0x7000000e6]
                if hangul && array.contains(where:{sources.contains($0["HIDKeyboardModifierMappingSrc"] ?? 0) && $0["HIDKeyboardModifierMappingDst"] != 0x700000039}) { throw InputConfigurationError.invalid("다른 동작에 사용 중인 오른쪽 한영키") }
                array.removeAll { sources.contains($0["HIDKeyboardModifierMappingSrc"] ?? 0) && $0["HIDKeyboardModifierMappingDst"] == 0x700000039 }
                if hangul { for source in sources.sorted() { array.append(["HIDKeyboardModifierMappingSrc":source,"HIDKeyboardModifierMappingDst":0x700000039]) } }
                return array
            }
            hidAfter=try PropertyListSerialization.data(fromPropertyList:adjusted(mappings(snapshot.hidData)),format:.xml,options:0)
            guard let agentData=snapshot.agentData,var agent=try PropertyListSerialization.propertyList(from:agentData,options:[],format:nil) as? [String:Any],
                  var args=agent["ProgramArguments"] as? [String],args.count == 4,args[0] == "/usr/bin/hidutil",args[1] == "property",args[2] == "--set",
                  var payload=try JSONSerialization.jsonObject(with:Data(args[3].utf8),options:[.json5Allowed]) as? [String:Any],
                  let loginMappings=payload["UserKeyMapping"] as? [[String:Any]] else { throw InputConfigurationError.invalid("기존 한영키 로그인 설정") }
            // This known one-shot LaunchAgent reads the updated plist at next login.
            // Do not bootstrap it now: its asynchronous hidutil could overwrite live-only mappings.
            let triggers=["StartInterval","StartCalendarInterval","WatchPaths","QueueDirectories","MachServices","Sockets","LaunchEvents"]
            guard !triggers.contains(where:{agent[$0] != nil}),agent["KeepAlive"] == nil || agent["KeepAlive"] as? Bool == false else { throw InputConfigurationError.invalid("자동 반복 실행이 추가된 한영키 로그인 설정") }
            payload["UserKeyMapping"]=try adjusted(normalizeMappings(loginMappings))
            args[3]=String(data:try JSONSerialization.data(withJSONObject:payload,options:.sortedKeys),encoding:.utf8)!
            agent["ProgramArguments"]=args
            before[agentPath]=agentData;after[agentPath]=try PropertyListSerialization.data(fromPropertyList:agent,format:.xml,options:0)
        }
        let changedGlobals=globalChanges.filter { keys.contains($0.key) && snapshot.globals[$0.key] != $0.value }
        guard !after.isEmpty || !changedGlobals.isEmpty else { return nil }
        var globalsAfter=snapshot.globals;for (key,value) in changedGlobals { globalsAfter[key]=value }
        let backup=InputBackup(before:before,after:after,hidBefore:snapshot.hidData,hidAfter:hidAfter,globalsBefore:snapshot.globals,globalsAfter:globalsAfter,globalsChanged:Array(changedGlobals.keys),hangulChanged:features[.hangul] != nil)
        try FileManager.default.createDirectory(at:backupDirectory,withIntermediateDirectories:true)
        let backupURL=backupDirectory.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).json")
        try JSONEncoder().encode(backup).write(to:backupURL,options:.atomic)
        do {
            try write(after)
            if backup.hangulChanged { try applyHID(hidAfter) }
            for (key,value) in changedGlobals { try globalSet(key,value) }
            try backupURL.lastPathComponent.write(to:backupDirectory.appendingPathComponent("latest"),atomically:true,encoding:.utf8)
        } catch {
            let originalError=error
            let errors=recover(files:before,hid:snapshot.hidData,globals:snapshot.globals,keys:Array(changedGlobals.keys),hangul:backup.hangulChanged)
            if !errors.isEmpty {
                try savePending(backup)
                throw NSError(domain:"WindowBridge",code:2,userInfo:[NSLocalizedDescriptionKey:"일부 설정을 자동 복구하지 못했습니다. 백업·복원에서 복구를 재시도하세요. 백업: \(backupURL.path) / \(errors.joined(separator:"; "))"])
            }
            throw originalError
        }
        return backupURL
    }
    public var latestBackup:URL? {
        guard let name=try? String(contentsOf:backupDirectory.appendingPathComponent("latest"),encoding:.utf8),!name.contains("/") else { return nil }
        return backupDirectory.appendingPathComponent(name)
    }
    public func restoreLatest() throws {
        if let pending=pendingRecovery { try retryRecovery(pending);return }
        guard let url=latestBackup else { throw InputConfigurationError.invalid("복원할 백업") }
        let b=try JSONDecoder().decode(InputBackup.self,from:Data(contentsOf:url))
        for (path,data) in b.after { guard try read(path) == data else { throw InputConfigurationError.conflict } }
        let current=try load()
        for key in b.globalsChanged { guard current.globals[key] == b.globalsAfter[key] else { throw InputConfigurationError.conflict } }
        if b.hangulChanged { guard try mappings(current.hidData) == mappings(b.hidAfter) else { throw InputConfigurationError.conflict } }
        do {
            try write(b.before)
            if b.hangulChanged { try applyHID(b.hidBefore) }
            for key in b.globalsChanged { try globalSet(key,b.globalsBefore[key]) }
            try FileManager.default.removeItem(at:backupDirectory.appendingPathComponent("latest"))
        } catch {
            let originalError=error
            let errors=recover(files:b.after,hid:b.hidAfter,globals:b.globalsAfter,keys:b.globalsChanged,hangul:b.hangulChanged)
            if !errors.isEmpty {
                // Keep the original restore target and capture the actual partial state for safe retry.
                try savePending(b,clearLatestOnSuccess:true)
                throw NSError(domain:"WindowBridge",code:3,userInfo:[NSLocalizedDescriptionKey:"복원과 되돌리기가 일부 실패했습니다. 백업·복원에서 복구를 재시도하세요. \(errors.joined(separator:"; "))"])
            }
            throw originalError
        }
    }
    private func recover(files:[String:Data],hid:Data,globals:[String:String],keys:[String],hangul:Bool) -> [String] {
        var errors:[String]=[]
        func attempt(_ label:String,_ work:() throws -> Void) {
            do { try work() } catch { errors.append("\(label): \(error.localizedDescription)") }
        }
        for (path,data) in files { attempt(path) { try data.write(to:file(path),options:.atomic) } }
        if hangul {
            attempt("현재 한영키") { try applyHID(hid) }
        }
        for key in keys { attempt(key) { try globalSet(key,globals[key]) } }
        return errors
    }
    public var pendingRecovery:URL? {
        let url=backupDirectory.appendingPathComponent("pending-recovery.json")
        return FileManager.default.fileExists(atPath:url.path) ? url:nil
    }
    public var canRetryRecovery:Bool {
        guard let url=pendingRecovery,let data=try? Data(contentsOf:url),let recovery=try? JSONDecoder().decode(PendingInputRecovery.self,from:data) else { return false }
        return recovery.complete
    }
    private func savePending(_ backup:InputBackup,clearLatestOnSuccess:Bool=false) throws {
        var expected:[String:Data]=[:]
        for path in backup.before.keys { expected[path]=try? read(path) }
        let hid=try? run(["/usr/bin/hidutil","property","--get","UserKeyMapping"])
        let pending=PendingInputRecovery(backup:backup,expectedFiles:expected,expectedHID:hid,expectedGlobals:globals(),complete:expected.count == backup.before.count && (!backup.hangulChanged || hid != nil),clearLatestOnSuccess:clearLatestOnSuccess)
        try JSONEncoder().encode(pending).write(to:backupDirectory.appendingPathComponent("pending-recovery.json"),options:.atomic)
    }
    private func retryRecovery(_ url:URL) throws {
        let pending=try JSONDecoder().decode(PendingInputRecovery.self,from:Data(contentsOf:url))
        guard pending.complete else { throw InputConfigurationError.invalid("복구 당시 상태를 읽지 못했습니다. 백업 폴더의 원본을 확인") }
        for (path,data) in pending.expectedFiles { guard try read(path) == data else { throw InputConfigurationError.conflict } }
        let live=try run(["/usr/bin/hidutil","property","--get","UserKeyMapping"])
        if pending.backup.hangulChanged,let expected=pending.expectedHID { guard try mappings(live) == mappings(expected) else { throw InputConfigurationError.conflict } }
        let currentGlobals=globals()
        for key in pending.backup.globalsChanged { guard currentGlobals[key] == pending.expectedGlobals[key] else { throw InputConfigurationError.conflict } }
        let b=pending.backup
        let errors=recover(files:b.before,hid:b.hidBefore,globals:b.globalsBefore,keys:b.globalsChanged,hangul:b.hangulChanged)
        if !errors.isEmpty { try savePending(b,clearLatestOnSuccess:pending.clearLatestOnSuccess);throw NSError(domain:"WindowBridge",code:4,userInfo:[NSLocalizedDescriptionKey:errors.joined(separator:"; ")]) }
        try FileManager.default.removeItem(at:url)
        if pending.clearLatestOnSuccess { try? FileManager.default.removeItem(at:backupDirectory.appendingPathComponent("latest")) }
    }
}
