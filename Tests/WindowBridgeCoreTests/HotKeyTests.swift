import AppKit
import WindowBridgeCore

// These tests call HotKey.receive with locally created CGEvent values. They never
// create an event tap, post an event, synthesize system input, or change settings.
@main struct HotKeyTests {
    static func main() {
        testOrdinaryInputPassesThrough()
        testTileShortcutConsumesPairAndCommitsOnce()
        testEscapeCancelsWithoutConsumingEscape()
        testDisabledTilingDrainsHeldRelease()
        testMissedReleaseDoesNotEatFreshOrdinaryPress()
        print("PASS: direct HotKey.receive routing, release, repeat, cancel, and drain")
    }

    private static func testOrdinaryInputPassesThrough() {
        let hook=HotKey()
        hook.configure(switching:true,tiling:true)
        let leftAlt=CGEventFlags.maskAlternate.union(CGEventFlags(rawValue:0x20))
        let rightAlt=CGEventFlags.maskAlternate.union(CGEventFlags(rawValue:0x40))

        check(passes(hook,.keyDown,event(type:.keyDown,keyCode:57,flags:.maskAlphaShift)),"Caps Lock down passes")
        check(passes(hook,.keyUp,event(type:.keyUp,keyCode:57,flags:.maskAlphaShift)),"Caps Lock up passes")
        check(passes(hook,.keyDown,event(type:.keyDown,keyCode:123,flags:.maskCommand.union(rightAlt))),"Command + right Option + arrow passes")
        check(passes(hook,.keyDown,event(type:.keyDown,keyCode:0,flags:.maskCommand.union(leftAlt))),"ordinary letter passes under shortcut modifiers")
        check(passes(hook,.flagsChanged,event(type:.flagsChanged,keyCode:57,flags:.maskAlphaShift)),"Caps Lock flagsChanged passes")
        check(passes(hook,.flagsChanged,event(type:.flagsChanged,keyCode:61,flags:rightAlt)),"right Option flagsChanged passes")
        check(passes(hook,.flagsChanged,event(type:.flagsChanged,keyCode:58,flags:leftAlt)),"left Option flagsChanged passes")
    }

    private static func testTileShortcutConsumesPairAndCommitsOnce() {
        let hook=HotKey()
        hook.configure(switching:false,tiling:true)
        let chord=CGEventFlags.maskCommand.union(.maskAlternate).union(CGEventFlags(rawValue:0x20))
        var starts:[Int]=[]
        var actions:[WindowAction]=[]
        hook.onWindowActionStart={ starts.append($0) }
        hook.onWindowAction={ _,action in actions.append(action) }

        check(consumes(hook,.keyDown,event(type:.keyDown,keyCode:123,flags:chord)),"Command + left Option + Left starts tile")
        check(consumes(hook,.keyDown,event(type:.keyDown,keyCode:123,flags:chord,autorepeat:1)),"shortcut autorepeat remains paired")
        pumpMainQueue { starts.count==1 }
        check(starts.count==1,"autorepeat does not start another capture")
        check(consumes(hook,.keyUp,event(type:.keyUp,keyCode:123,flags:chord)),"matching arrow up is consumed")
        check(actions.isEmpty,"action waits for modifiers to be released")
        check(passes(hook,.flagsChanged,event(type:.flagsChanged,keyCode:58,flags:.maskCommand)),"left Option release passes")
        check(actions.isEmpty,"action still waits for Command release")
        check(passes(hook,.flagsChanged,event(type:.flagsChanged,keyCode:55,flags:[])),"Command release passes")
        pumpMainQueue { actions.count==1 }
        check(actions == [.tile(.left)],"all key releases commit the requested action once")
        check(passes(hook,.keyUp,event(type:.keyUp,keyCode:0,flags:[])),"unmatched ordinary key up passes")
    }

    private static func testEscapeCancelsWithoutConsumingEscape() {
        let hook=HotKey()
        hook.configure(switching:false,tiling:true)
        let chord=CGEventFlags.maskCommand.union(.maskAlternate).union(CGEventFlags(rawValue:0x20))
        var cancellations=0
        var actions:[WindowAction]=[]
        hook.onWindowActionCancel={ cancellations += 1 }
        hook.onWindowAction={ _,action in actions.append(action) }

        check(consumes(hook,.keyDown,event(type:.keyDown,keyCode:123,flags:chord)),"tile shortcut starts before Escape")
        check(passes(hook,.keyDown,event(type:.keyDown,keyCode:53,flags:chord)),"Escape down remains available to the frontmost app")
        check(passes(hook,.keyUp,event(type:.keyUp,keyCode:53,flags:chord)),"Escape up remains paired")
        pumpMainQueue { cancellations==1 }
        check(cancellations==1,"Escape cancels pending capture once")
        check(consumes(hook,.keyUp,event(type:.keyUp,keyCode:123,flags:chord)),"cancelled shortcut still drains its arrow up")
        _=hook.receive(.flagsChanged,event(type:.flagsChanged,keyCode:58,flags:.maskCommand))
        _=hook.receive(.flagsChanged,event(type:.flagsChanged,keyCode:55,flags:[]))
        pumpMainQueue { false }
        check(actions.isEmpty,"cancelled action is never dispatched")
    }

    private static func testDisabledTilingDrainsHeldRelease() {
        let hook=HotKey()
        hook.configure(switching:false,tiling:true)
        let chord=CGEventFlags.maskCommand.union(.maskAlternate).union(CGEventFlags(rawValue:0x20))
        var actions:[WindowAction]=[]
        hook.onWindowAction={ _,action in actions.append(action) }

        check(consumes(hook,.keyDown,event(type:.keyDown,keyCode:124,flags:chord)),"right tile shortcut is captured")
        hook.configure(switching:false,tiling:false)
        check(consumes(hook,.keyUp,event(type:.keyUp,keyCode:124,flags:chord)),"turning tiling off still consumes the held key up")
        pumpMainQueue { false }
        check(actions.isEmpty,"disabled tiling cancels the pending action")
    }

    private static func testMissedReleaseDoesNotEatFreshOrdinaryPress() {
        let hook=HotKey()
        hook.configure(switching:false,tiling:true)
        let chord=CGEventFlags.maskCommand.union(.maskAlternate).union(CGEventFlags(rawValue:0x20))
        var cancellations=0
        hook.onWindowActionCancel={ cancellations += 1 }

        check(consumes(hook,.keyDown,event(type:.keyDown,keyCode:36,flags:chord)),"Return shortcut down is consumed")
        _=hook.receive(.tapDisabledByTimeout,event(type:.tapDisabledByTimeout,keyCode:0,flags:[]))
        pumpMainQueue { cancellations==1 }
        check(cancellations==1,"tap timeout cancels pending target capture")
        // The Return key-up is intentionally omitted to model it passing while the tap is disabled.
        check(passes(hook,.keyDown,event(type:.keyDown,keyCode:36,flags:[])),"fresh unmodified Return down passes after a missed release")
        check(passes(hook,.keyUp,event(type:.keyUp,keyCode:36,flags:[])),"fresh unmodified Return up remains paired")
    }

    private static func event(type:CGEventType,keyCode:Int64,flags:CGEventFlags,autorepeat:Int64=0) -> CGEvent {
        let event=CGEvent(source:nil)!
        event.type=type
        event.setIntegerValueField(.keyboardEventKeycode,value:keyCode)
        event.setIntegerValueField(.keyboardEventAutorepeat,value:autorepeat)
        event.flags=flags
        return event
    }

    private static func consumes(_ hook:HotKey,_ type:CGEventType,_ event:CGEvent) -> Bool {
        hook.receive(type,event) == nil
    }

    private static func passes(_ hook:HotKey,_ type:CGEventType,_ event:CGEvent) -> Bool {
        guard let result=hook.receive(type,event) else { return false }
        return result.takeUnretainedValue() === event
    }

    private static func pumpMainQueue(until condition:()->Bool) {
        let deadline=Date().addingTimeInterval(0.5)
        while !condition() && Date()<deadline {
            _=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01))
        }
    }

    private static func check(_ condition:Bool,_ message:String) {
        if !condition { fputs("FAIL: \(message)\n",stderr);exit(1) }
    }
}
