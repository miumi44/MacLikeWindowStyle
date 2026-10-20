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
