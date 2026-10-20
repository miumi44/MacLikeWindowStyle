import Foundation

public enum InputFeature:String,CaseIterable {
    case hangul,altF4,finderDelete,permanentDelete,rename,moveFiles,ctrlShortcuts,ctrlEditing,navigation
    public var title:String {
        switch self {
        case .hangul:return "오른쪽 한영 / Alt 키로 한영 전환"
        case .altF4:return "왼쪽 Alt+F4로 현재 창 닫기"
        case .finderDelete:return "Finder에서 Delete로 휴지통 이동"
        case .permanentDelete:return "Finder에서 Shift+Delete로 영구 삭제 확인"
        case .rename:return "Finder에서 F2로 이름 변경"
        case .moveFiles:return "Finder에서 Ctrl+Shift+V로 파일 이동"
        case .ctrlShortcuts:return "기타 Windows Ctrl 단축키"
        case .ctrlEditing:return "왼쪽 Ctrl+C/V/A (복사·붙여넣기·전체 선택)"
        case .navigation:return "Windows 탐색키 (Home·End·Ctrl+방향키)"
        }
    }
}
public enum FeatureState { case on,off,mixed,unavailable }
public enum InputConfigurationError:LocalizedError {
    case invalid(String),conflict
    public var errorDescription:String? {
        switch self {
        case .invalid(let name):return "\(name) 설정 형식을 읽을 수 없습니다. 기존 파일은 변경하지 않았습니다."
        case .conflict:return "다른 앱에서 설정을 변경했습니다. ‘다시 읽기’ 후 적용해 주세요."
        }
    }
}
public struct KeyboardConfiguration {
    private var root:[String:Any]
    private var selected:Int
    private static let marker="windowbridge.disabled"
    public init(data:Data) throws {
        guard let root=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let profiles=root["profiles"] as? [[String:Any]],let index=profiles.firstIndex(where:{$0["selected"] as? Bool == true}) else { throw InputConfigurationError.invalid("Karabiner") }
        self.root=root;selected=index
    }
    public var profileName:String { profiles[selected]["name"] as? String ?? "선택 프로필" }
    private var profiles:[[String:Any]] { root["profiles"] as! [[String:Any]] }
    private var rules:[[String:Any]] { (profiles[selected]["complex_modifications"] as? [String:Any])?["rules"] as? [[String:Any]] ?? [] }
    private static let developmentApps=["^com\\.microsoft\\.VSCode","^com\\.todesktop\\.230313mzl4w4u92$","^com\\.jetbrains\\.","^dev\\.zed\\.","^com\\.openai\\.codex$"]
    private static let ctrlEditingKeys=["a","c","v"]
    private static let ctrlEditingDescription="Windows Ctrl shortcuts and navigation (development tools excluded)"
    private func feature(_ rule:[String:Any],_ m:[String:Any]) -> InputFeature? {
        let description=rule["description"] as? String ?? ""
        let from=m["from"] as? [String:Any] ?? [:]
        let key=from["key_code"] as? String ?? ""
        let modifiers=(from["modifiers"] as? [String:Any])?["mandatory"] as? [String] ?? []
        if description == "Preserve existing Hangul: LANG1 / Right Alt to Caps Lock (same as hidutil)" { return .hangul }
        if description == "Left Alt+F4: close current window (browser and Finder include all tabs)" { return .altF4 }
        if description == "Finder: Delete trash, Shift+Delete permanent confirmation, F2 rename, Ctrl+Shift+V move" {
            if key == "delete_forward" { return modifiers.contains("shift") ? .permanentDelete:.finderDelete }
            if key == "f2" { return .rename };if key == "v" { return .moveFiles }
        }
        if description == Self.ctrlEditingDescription {
            if Self.ctrlEditingKeys.contains(key) && (modifiers == ["control"] || modifiers == ["left_control"]) { return .ctrlEditing }
            return ["home","end","left_arrow","right_arrow"].contains(key) ? .navigation:.ctrlShortcuts
        }
        return nil
    }
    private func disabled(_ m:[String:Any]) -> Bool {
        (m["conditions"] as? [[String:Any]] ?? []).contains { $0["name"] as? String == Self.marker }
    }
    public func state(_ feature:InputFeature) -> FeatureState {
        if feature == .ctrlEditing { return ctrlEditingState() }
        let states=rules.flatMap { rule in (rule["manipulators"] as? [[String:Any]] ?? []).compactMap { m -> Bool? in
            self.feature(rule,m) == feature ? !disabled(m):nil
        } }
        guard !states.isEmpty else { return .unavailable }
        return states.allSatisfy{$0} ? .on : states.allSatisfy{!$0} ? .off:.mixed
    }
    private func ctrlEditingState() -> FeatureState {
        let mappings=rules.flatMap { rule -> [[String:Any]] in
            guard rule["description"] as? String == Self.ctrlEditingDescription else { return [] }
            return rule["manipulators"] as? [[String:Any]] ?? []
        }.filter { m in
            let from=m["from"] as? [String:Any] ?? [:]
            let key=from["key_code"] as? String ?? ""
            let modifiers=(from["modifiers"] as? [String:Any])?["mandatory"] as? [String] ?? []
            return Self.ctrlEditingKeys.contains(key) && (modifiers == ["control"] || modifiers == ["left_control"])
        }
        let byKey=Dictionary(grouping:mappings,by:{ ($0["from"] as? [String:Any])?["key_code"] as? String ?? "" })
        guard Self.ctrlEditingKeys.allSatisfy({ !(byKey[$0] ?? []).isEmpty }) else { return .unavailable }
        let all=mappings.flatMap { m -> [Bool] in
            let from=m["from"] as? [String:Any] ?? [:]
            let modifiers=(from["modifiers"] as? [String:Any])?["mandatory"] as? [String] ?? []
            let conditions=m["conditions"] as? [[String:Any]] ?? []
            let excluded=conditions.compactMap { condition -> [String]? in
                guard condition["type"] as? String == "frontmost_application_unless" else { return nil }
                return condition["bundle_identifiers"] as? [String]
            }.flatMap { $0 }
            return [!disabled(m) && modifiers == ["left_control"] &&
                !Self.developmentApps.contains(where:excluded.contains)]
        }
        guard !all.isEmpty else { return .unavailable }
        if all.allSatisfy({ !$0 }) && mappings.allSatisfy(disabled) { return .off }
        if all.allSatisfy({ $0 }) { return .on }
        return .mixed
    }
    public mutating func set(_ wanted:InputFeature,enabled:Bool) {
        var updated=rules
        for i in updated.indices {
            var ms=updated[i]["manipulators"] as? [[String:Any]] ?? []
            for j in ms.indices where feature(updated[i],ms[j]) == wanted {
                if wanted == .ctrlEditing {
                    if enabled {
                        var from=ms[j]["from"] as? [String:Any] ?? [:]
                        var fromModifiers=from["modifiers"] as? [String:Any] ?? [:]
                        fromModifiers["mandatory"]=["left_control"]
                        from["modifiers"]=fromModifiers;ms[j]["from"]=from
                        var conditions=ms[j]["conditions"] as? [[String:Any]] ?? []
                        conditions=conditions.compactMap { condition in
                            guard condition["type"] as? String == "frontmost_application_unless",
                                  var apps=condition["bundle_identifiers"] as? [String] else { return condition }
                            apps.removeAll { Self.developmentApps.contains($0) }
                            var copy=condition
                            if apps.isEmpty {
                                copy.removeValue(forKey:"bundle_identifiers")
                                return copy.count > 1 ? copy:nil
                            }
                            copy["bundle_identifiers"]=apps;return copy
                        }
                        ms[j]["conditions"]=conditions
                    }
                }
                var conditions=ms[j]["conditions"] as? [[String:Any]] ?? []
                conditions.removeAll { $0["name"] as? String == Self.marker }
                if !enabled { conditions.append(["type":"variable_if","name":Self.marker,"value":"disabled_by_windowbridge"]) }
                if conditions.isEmpty { ms[j].removeValue(forKey:"conditions") } else { ms[j]["conditions"]=conditions }
            }
            if updated[i]["manipulators"] != nil { updated[i]["manipulators"]=ms }
        }
        var ps=profiles
        var complex=ps[selected]["complex_modifications"] as? [String:Any] ?? [:]
        complex["rules"]=updated;ps[selected]["complex_modifications"]=complex;root["profiles"]=ps
    }
    public func serialized() throws -> Data { try JSONSerialization.data(withJSONObject:root,options:[.prettyPrinted,.sortedKeys]) }
}

public struct MouseConfiguration {
    private var root:[String:Any]
    private var index:Int
    public init(data:Data) throws {
        guard let root=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let schemes=root["schemes"] as? [[String:Any]],let index=schemes.firstIndex(where:{ scheme in
                  let condition=scheme["if"] as? [String:Any] ?? [:]
                  let device=condition["device"] as? [String:Any] ?? [:]
                  return device["category"] as? String == "mouse" && device.count == 1 && condition.count == 1
              }) else { throw InputConfigurationError.invalid("LinearMouse 기본 마우스") }
        self.root=root;self.index=index
    }
    private var scrolling:[String:Any] {
        get { (root["schemes"] as! [[String:Any]])[index]["scrolling"] as? [String:Any] ?? [:] }
        set { var schemes=root["schemes"] as! [[String:Any]];schemes[index]["scrolling"]=newValue;root["schemes"]=schemes }
    }
    public var reverse:Bool { get { scrolling["reverse"] as? Bool ?? false } set { var s=scrolling;s["reverse"]=newValue;scrolling=s } }
    public var smooth:Bool {
        get { (scrolling["smoothed"] as? [String:Any])?["enabled"] as? Bool ?? false }
        set { var s=scrolling;var sm=s["smoothed"] as? [String:Any] ?? [:];sm["enabled"]=newValue;s["smoothed"]=sm;scrolling=s }
    }
    public var distance:Double {
        get { (scrolling["distance"] as? [String:Any])?["vertical"] as? Double ?? 3 }
        set { var s=scrolling;var d=s["distance"] as? [String:Any] ?? [:];d["vertical"]=newValue;s["distance"]=d;scrolling=s }
    }
    public func serialized() throws -> Data { try JSONSerialization.data(withJSONObject:root,options:[.prettyPrinted,.sortedKeys]) }
}
