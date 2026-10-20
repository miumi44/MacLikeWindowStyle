import AppKit
import ApplicationServices
import WindowBridgeCore

@MainActor enum WindowTiler {
    static func tile(_ direction:TileDirection) -> String {
        guard AXIsProcessTrusted(),let app=NSWorkspace.shared.frontmostApplication else { return "손쉬운 사용 권한을 확인해 주세요." }
        let element=AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element,0.3)
        var value:CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,kAXFocusedWindowAttribute as CFString,&value) == .success,
              let value,CFGetTypeID(value) == AXUIElementGetTypeID() else { return "배치할 활성 창이 없습니다." }
        let window=unsafeBitCast(value,to:AXUIElement.self)
        AXUIElementSetMessagingTimeout(window,0.3)
        var fullscreen:CFTypeRef?
        AXUIElementCopyAttributeValue(window,"AXFullScreen" as CFString,&fullscreen)
        guard (fullscreen as? Bool) != true else { return "전체 화면을 종료한 뒤 창을 배치해 주세요." }
        var movable:DarwinBoolean=false,resizable:DarwinBoolean=false
        guard AXUIElementIsAttributeSettable(window,kAXPositionAttribute as CFString,&movable) == .success,movable.boolValue,
              AXUIElementIsAttributeSettable(window,kAXSizeAttribute as CFString,&resizable) == .success,resizable.boolValue,
              let frame=frame(window),let primary=NSScreen.screens.first else { return "이 창은 위치 또는 크기를 변경할 수 없습니다." }
        func axRect(_ rect:CGRect) -> CGRect { CGRect(x:rect.minX,y:primary.frame.maxY-rect.maxY,width:rect.width,height:rect.height) }
        // Largest overlap keeps a window straddling monitors on its current display.
        guard let screen=NSScreen.screens.max(by:{ a,b in
            let x=axRect(a.frame).intersection(frame),y=axRect(b.frame).intersection(frame)
            return (x.isNull ? 0:x.width*x.height) < (y.isNull ? 0:y.width*y.height)
        }) else { return "화면을 찾지 못했습니다." }
        let target=tileFrame(direction,in:axRect(screen.visibleFrame))
        var size=target.size,point=target.origin
        let sizeValue=AXValueCreate(.cgSize,&size)!,pointValue=AXValueCreate(.cgPoint,&point)!
        // Shrink before moving so the old size cannot push the new position off-screen.
        let resize=AXUIElementSetAttributeValue(window,kAXSizeAttribute as CFString,sizeValue)
        let move=AXUIElementSetAttributeValue(window,kAXPositionAttribute as CFString,pointValue)
        guard resize == .success,move == .success else { return "앱이 창 배치를 허용하지 않았습니다." }
        return "창을 배치했습니다. 앱의 최소 창 크기에 따라 절반보다 커질 수 있습니다."
    }
    private static func frame(_ window:AXUIElement) -> CGRect? {
        var p:CFTypeRef?,s:CFTypeRef?,point=CGPoint.zero,size=CGSize.zero
        guard AXUIElementCopyAttributeValue(window,kAXPositionAttribute as CFString,&p) == .success,
              AXUIElementCopyAttributeValue(window,kAXSizeAttribute as CFString,&s) == .success,
              let p,let s,CFGetTypeID(p) == AXValueGetTypeID(),CFGetTypeID(s) == AXValueGetTypeID(),
              AXValueGetValue(unsafeBitCast(p,to:AXValue.self),.cgPoint,&point),
              AXValueGetValue(unsafeBitCast(s,to:AXValue.self),.cgSize,&size) else { return nil }
        return CGRect(origin:point,size:size)
    }
}
