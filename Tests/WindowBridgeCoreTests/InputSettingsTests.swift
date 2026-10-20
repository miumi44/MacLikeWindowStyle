import Foundation
@main struct InputSettingsTests {
    static func main() throws {
        assert(rejects({ _ = try KeyboardConfiguration(data:Data("{".utf8)) }),"malformed Karabiner JSON accepted")
        assert(rejects({ _ = try KeyboardConfiguration(data:Data(#"{"profiles":[{"selected":false}]}"#.utf8)) }),"Karabiner without a selected profile accepted")
        assert(rejects({ _ = try MouseConfiguration(data:Data("{".utf8)) }),"malformed LinearMouse JSON accepted")
        assert(rejects({ _ = try MouseConfiguration(data:Data(#"{"schemes":[{"if":{"device":{"category":"trackpad"}}}]}"#.utf8)) }),"LinearMouse without a generic mouse scheme accepted")
        var unsupported=try KeyboardConfiguration(data:Data(#"{"profiles":[{"selected":true,"name":"Unsupported"}]}"#.utf8))
        assert(unsupported.state(.altF4) == .unavailable,"missing supported rule reported as disabled")
        unsupported.set(.altF4,enabled:false)
        assert(unsupported.state(.altF4) == .unavailable,"unsupported rule became available after an edit")

        let data=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
        var root=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        var profiles=root["profiles"] as! [[String:Any]]
        var complex=profiles[0]["complex_modifications"] as! [String:Any]
        var rules=complex["rules"] as! [[String:Any]]
        let ctrlRule=rules.firstIndex { $0["description"] as? String == "Windows Ctrl shortcuts and navigation (development tools excluded)" }!
        var manipulators=rules[ctrlRule]["manipulators"] as! [[String:Any]]
        let copyIndex=manipulators.firstIndex { m in
            let from=m["from"] as? [String:Any] ?? [:]
            return from["key_code"] as? String == "c" && ((from["modifiers"] as? [String:Any])?["mandatory"] as? [String] ?? []) == ["control"]
        }!
        var customConditions=manipulators[copyIndex]["conditions"] as! [[String:Any]]
        customConditions.append(["type":"variable_if","name":"keep_my_condition","value":1])
        customConditions.append(["type":"frontmost_application_unless","bundle_identifiers":["^com\\.openai\\.codex$"],"file_paths":["/Applications/Codex.app"]])
        manipulators[copyIndex]["conditions"]=customConditions;rules[ctrlRule]["manipulators"]=manipulators
        complex["rules"]=rules;profiles[0]["complex_modifications"]=complex;root["profiles"]=profiles
        let customized=try JSONSerialization.data(withJSONObject:root)
        var ctrlConfig=try KeyboardConfiguration(data:customized)
        assert(ctrlConfig.state(.ctrlEditing) == .mixed,"legacy C/V/A rule should show partial coverage")
        assert(ctrlConfig.state(.ctrlShortcuts) == .on,"legacy shifted and other Ctrl shortcuts disappeared from their control")
        ctrlConfig.set(.ctrlEditing,enabled:true)
        assert(ctrlConfig.state(.ctrlEditing) == .on,"expanded left-Control policy was not detected")
        assert(ctrlConfig.state(.ctrlShortcuts) == .on && ctrlConfig.state(.navigation) == .on && ctrlConfig.state(.moveFiles) == .on,"Ctrl editing migration changed another feature")
        let expandedRoot=try JSONSerialization.jsonObject(with:ctrlConfig.serialized()) as! [String:Any]
        let expandedProfile=(expandedRoot["profiles"] as! [[String:Any]])[0]
        let expandedRules=(expandedProfile["complex_modifications"] as! [String:Any])["rules"] as! [[String:Any]]
        let expandedManipulators=expandedRules.first { $0["description"] as? String == "Windows Ctrl shortcuts and navigation (development tools excluded)" }!["manipulators"] as! [[String:Any]]
        let letters=expandedManipulators.filter { m in ["a","c","v"].contains((m["from"] as? [String:Any])?["key_code"] as? String ?? "") }
        let unshifted=letters.filter { m in ((m["from"] as? [String:Any])?["modifiers"] as? [String:Any])?["mandatory"] as? [String] == ["left_control"] }
        let shifted=letters.filter { m in ((m["from"] as? [String:Any])?["modifiers"] as? [String:Any])?["mandatory"] as? [String] == ["control","shift"] }
        assert(unshifted.count == 3 && shifted.count == 3,"migration must touch only unshifted A/C/V")
        for m in unshifted {
            let conditions=m["conditions"] as! [[String:Any]]
            let apps=conditions.filter { $0["type"] as? String == "frontmost_application_unless" }.flatMap { $0["bundle_identifiers"] as? [String] ?? [] }
            assert(!apps.contains("^com\\.openai\\.codex$"),"Codex exception survived migration")
            assert(apps.contains("^com\\.apple\\.Terminal$") && apps.contains("^com\\.parallels\\."),"terminal and VM exceptions must remain")
            assert(((m["from"] as! [String:Any])["modifiers"] as! [String:Any])["mandatory"] as? [String] == ["left_control"],"right Control must remain native for IDE terminal interrupts")
        }
        let migratedCopy=unshifted.first { ($0["from"] as? [String:Any])?["key_code"] as? String == "c" }!
        assert((migratedCopy["conditions"] as! [[String:Any]]).contains { $0["name"] as? String == "keep_my_condition" },"user conditions were lost during migration")
        let migratedFileCondition=(migratedCopy["conditions"] as! [[String:Any]]).first { $0["type"] as? String == "frontmost_application_unless" && $0["file_paths"] != nil }
        assert(migratedFileCondition? ["bundle_identifiers"] == nil && migratedFileCondition?["file_paths"] as? [String] == ["/Applications/Codex.app"],"other fields on an emptied app condition were lost")
        ctrlConfig.set(.ctrlEditing,enabled:false)
        assert(ctrlConfig.state(.ctrlEditing) == .off,"disabled C/V/A mappings were not reported off")
        assert(ctrlConfig.state(.ctrlShortcuts) == .on && ctrlConfig.state(.navigation) == .on && ctrlConfig.state(.moveFiles) == .on,"disabling C/V/A changed another feature")
        let disabledRoot=try JSONSerialization.jsonObject(with:ctrlConfig.serialized()) as! [String:Any]
        let disabledProfile=(disabledRoot["profiles"] as! [[String:Any]])[0]
        let disabledRules=(disabledProfile["complex_modifications"] as! [String:Any])["rules"] as! [[String:Any]]
        let disabledManipulators=disabledRules.first { $0["description"] as? String == "Windows Ctrl shortcuts and navigation (development tools excluded)" }!["manipulators"] as! [[String:Any]]
        let disabledLetters=disabledManipulators.filter { m in
            let from=m["from"] as? [String:Any] ?? [:]
            return ["a","c","v"].contains(from["key_code"] as? String ?? "") && ((from["modifiers"] as? [String:Any])?["mandatory"] as? [String] ?? []) == ["left_control"]
        }
        assert(disabledLetters.count == 3 && disabledLetters.allSatisfy { ($0["conditions"] as? [[String:Any]] ?? []).contains { $0["name"] as? String == "windowbridge.disabled" } },"off should disable only unshifted A/C/V without rewriting the expanded source conditions")
        let disabledCopy=disabledLetters.first { ($0["from"] as? [String:Any])?["key_code"] as? String == "c" }!
        assert((disabledCopy["conditions"] as! [[String:Any]]).contains { $0["name"] as? String == "keep_my_condition" },"user conditions were lost when disabling")

        if CommandLine.arguments.count > 2 {
            let exampleRoot=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))) as! [String:Any]
            let wrappedExample=try JSONSerialization.data(withJSONObject:["profiles":[["selected":true,"complex_modifications":["rules":exampleRoot["rules"]!]]]])
            let example=try KeyboardConfiguration(data:wrappedExample)
            assert(example.state(.ctrlEditing) == .on,"published example does not contain the expanded Ctrl editing policy")
        }

        var config=try KeyboardConfiguration(data:data)
        let original=try config.serialized()
        config.set(.altF4,enabled:false)
        assert(config.state(.altF4) == .off)
        assert(config.state(.hangul) == .on)
        config.set(.altF4,enabled:true)
        let before=try JSONSerialization.jsonObject(with:original) as! [String:Any]
        let after=try JSONSerialization.jsonObject(with:config.serialized()) as! [String:Any]
        assert(NSDictionary(dictionary:before).isEqual(to:after))
        config.set(.permanentDelete,enabled:false)
        assert(config.state(.finderDelete) == .on && config.state(.rename) == .on)
        assert(config.state(.permanentDelete) == .off)
        config.set(.permanentDelete,enabled:false)
        config.set(.permanentDelete,enabled:true)
        assert(config.state(.permanentDelete) == .on)
        let mouse=Data("{\"unknown\":42,\"schemes\":[{\"if\":{\"device\":{\"category\":\"mouse\"}},\"scrolling\":{\"reverse\":false,\"distance\":{\"vertical\":3,\"horizontal\":7}}},{\"if\":{\"device\":{\"category\":\"trackpad\"}},\"custom\":true}]}".utf8)
        var m=try MouseConfiguration(data:mouse)
        m.reverse=true;m.distance=5;m.smooth=true
        let mj=try JSONSerialization.jsonObject(with:m.serialized()) as! [String:Any]
        assert(mj["unknown"] as? Int == 42)
        let schemes=mj["schemes"] as! [[String:Any]]
        assert(schemes[1]["custom"] as? Bool == true)
        let scrolling=schemes[0]["scrolling"] as! [String:Any]
        assert((scrolling["distance"] as! [String:Any])["horizontal"] as? Int == 7)
        assert(m.reverse && m.smooth && m.distance == 5)
        m.distance=30.5
        let custom=try MouseConfiguration(data:m.serialized())
        assert(custom.distance == 30.5,"custom wheel distance truncated or clamped")
        print("PASS: independent keyboard controls, lossless disable/enable, mouse preservation and custom fractional distance")
    }

    static func rejects(_ work:() throws -> Void) -> Bool {
        do { try work();return false } catch { return true }
    }
}
