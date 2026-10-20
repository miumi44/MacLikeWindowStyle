import CoreGraphics
import Foundation

@main struct WindowGeometryTests {
    static func main() {
        let visible=CGRect(x:0,y:0,width:1000,height:800)
        let rightHalf=CGRect(x:500,y:0,width:500,height:800)
        let constrained=WindowGeometry.visiblePlacement(size:CGSize(width:650,height:900),alignedTo:rightHalf,within:visible)
        check(constrained == CGRect(x:350,y:0,width:650,height:900),"oversized constrained window stays as visible as possible")

        let small=WindowGeometry.visiblePlacement(size:CGSize(width:320,height:240),alignedTo:rightHalf,within:visible)
        check(small == CGRect(x:500,y:0,width:320,height:240),"smaller window keeps the requested tile origin")
        check(WindowGeometry.approximatelyEqual(CGRect(x:1,y:2,width:300,height:200),CGRect(x:1.5,y:2,width:300,height:200)),"frame comparison accepts small AX rounding")
        check(!WindowGeometry.approximatelyEqual(CGRect(x:1,y:2,width:300,height:200),CGRect(x:3,y:2,width:300,height:200)),"frame comparison detects material position mismatch")
        check(WindowGeometry.approximatelyEqual(CGSize(width:300,height:200),CGSize(width:300.5,height:200)),"size comparison accepts AX rounding")
        check(WindowGeometry.shouldRecordMaximizedFrame(placementVerified:true,cancelled:false),"visible constrained placement is a verified maximize result")
        check(!WindowGeometry.shouldRecordMaximizedFrame(placementVerified:false,cancelled:false),"unverified partial maximize does not become restore state")
        check(!WindowGeometry.shouldRecordMaximizedFrame(placementVerified:true,cancelled:true),"cancelled maximize does not become restore state")
        check(WindowAction.tile(.left) == WindowAction.tile(.left) && WindowAction.tile(.left) != WindowAction.tile(.right),"window actions compare their tile direction")

        let original=CGRect(x:80,y:90,width:420,height:300)
        let tiled=CGRect(x:0,y:0,width:500,height:800)
        let maximized=visible
        var restore=WindowRestoreState<String>()
        restore.rememberOriginalFrame(for:"editor",frame:original)
        check(restore.toggleMaximize(for:"editor",current:tiled,target:maximized) == .maximize(maximized),"maximizing a tiled window does not mistake the tile for maximized state")
        check(restore.toggleMaximize(for:"editor",current:maximized,target:maximized) == .maximize(maximized),"unverified maximize is retried instead of toggled to restore")
        restore.recordMaximizedFrame(for:"editor",originalFrame:tiled,frame:CGRect(x:0,y:0,width:900,height:800))
        check(restore.toggleMaximize(for:"editor",current:CGRect(x:0,y:0,width:900,height:800),target:maximized) == .restore(original),"toggle after constrained maximize restores the pre-tile original frame")
        check(restore.toggleMaximize(for:"editor",current:original,target:maximized) == .maximize(maximized),"re-maximize preserves the first original frame")
        restore.recordMaximizedFrame(for:"editor",originalFrame:original,frame:maximized)
        check(restore.toggleMaximize(for:"editor",current:maximized,target:maximized) == .restore(original),"toggle after exact maximize restores the original frame")
        check(restore.originalFrame(for:"editor") == original,"repeated maximize does not overwrite the saved frame")
        restore.remove(for:"editor")
        check(restore.toggleMaximize(for:"editor",current:maximized,target:maximized) == .unchanged,"already-maximized window without restore history is unchanged")

        restore.rememberOriginalFrame(for:"old-window",frame:original)
        restore.rememberOriginalFrame(for:"live-window",frame:original)
        restore.retain { $0 == "live-window" }
        check(restore.originalFrame(for:"old-window") == nil,"stale window restore state can be pruned")
        check(restore.originalFrame(for:"live-window") == original,"live window restore state is retained")

        print("PASS: constrained window placement, AX frame tolerance, maximize/restore state and stale state pruning")
    }

    static func check(_ condition:Bool,_ label:String) {
        if !condition { fputs("FAIL: \(label)\n",stderr);exit(1) }
    }
}
