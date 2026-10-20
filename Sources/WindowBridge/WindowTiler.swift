import AppKit
import ApplicationServices
import WindowBridgeCore

fileprivate struct WindowIdentity:Equatable {
    let processIdentifier:pid_t
    let application:AXUIElement
    let window:AXUIElement

    static func == (lhs:WindowIdentity,rhs:WindowIdentity) -> Bool {
        lhs.processIdentifier == rhs.processIdentifier && CFEqual(lhs.window,rhs.window)
    }
}

@MainActor enum WindowTiler {
    struct Target {
        fileprivate let identity:WindowIdentity
    }

    private struct ScreenArea {
        let visible:CGRect
    }

    private struct FrameChange {
        let before:CGRect
        let target:CGRect
        let after:CGRect?
        let placementVerified:Bool
        let exact:Bool
        let sizeError:AXError?
        let positionError:AXError?
        let cancelled:Bool

        init(before:CGRect,target:CGRect,after:CGRect?,placementVerified:Bool,exact:Bool,
             sizeError:AXError?=nil,positionError:AXError?=nil,cancelled:Bool=false) {
            self.before=before;self.target=target;self.after=after
            self.placementVerified=placementVerified;self.exact=exact
            self.sizeError=sizeError;self.positionError=positionError;self.cancelled=cancelled
        }
    }

    private static var restoreState=WindowRestoreState<WindowIdentity>()
    private static let frameTolerance:CGFloat=1
    private static let retryCount=3

    static func captureTarget() -> Target? {
        guard AXIsProcessTrusted(),let app=NSWorkspace.shared.frontmostApplication,!app.isTerminated else { return nil }
        let application=AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application,0.3)
        guard let window=focusedWindow(in:application) else { return nil }
        AXUIElementSetMessagingTimeout(window,0.3)
        return Target(identity:WindowIdentity(processIdentifier:app.processIdentifier,application:application,window:window))
    }

    static func performCurrent(action:WindowAction) async -> String {
        guard let target=captureTarget() else { return "배치할 활성 창이 없습니다. 손쉬운 사용 권한과 현재 창을 확인해 주세요." }
        return await perform(action:action,target:target)
    }

    static func perform(action:WindowAction,target:Target) async -> String {
        guard !Task.isCancelled else { return "창 동작이 취소됐습니다." }
        guard AXIsProcessTrusted() else { return "창 관리에는 손쉬운 사용 권한이 필요합니다." }
        pruneStaleRestoreState()
        let identity=target.identity
        guard let frontmost=NSWorkspace.shared.frontmostApplication,
              !frontmost.isTerminated,frontmost.processIdentifier == identity.processIdentifier,
              let focused=focusedWindow(in:identity.application),CFEqual(focused,identity.window) else {
            return "단축키를 시작할 때의 앱 창이 바뀌어 동작을 취소했습니다. 다시 시도해 주세요."
        }

        guard let before=frame(identity.window) else { return "현재 창의 위치와 크기를 읽지 못했습니다." }
        switch action {
        case let .tile(direction):
            guard let area=screenArea(for:before) else { return "화면 정보를 읽지 못했습니다." }
            guard canSetFrame(identity.window),!isFullscreen(identity.window) else {
                return "이 창은 위치 또는 크기를 변경할 수 없거나 전체 화면 상태입니다."
            }
            let targetFrame=tileFrame(direction,in:area.visible)
            let change=await applyFrame(targetFrame,to:identity,visible:area.visible,before:before)
            if let after=change.after,!WindowGeometry.approximatelyEqual(after,before,tolerance:frameTolerance) {
                restoreState.rememberOriginalFrame(for:identity,frame:before)
            }
            return report("창 배치",change)

        case .toggleMaximize:
            guard let area=screenArea(for:before) else { return "화면 정보를 읽지 못했습니다." }
            guard canSetFrame(identity.window),!isFullscreen(identity.window) else {
                return "이 창은 위치 또는 크기를 변경할 수 없거나 전체 화면 상태입니다."
            }
            let targetFrame=area.visible
            switch restoreState.toggleMaximize(for:identity,current:before,target:targetFrame) {
            case .unchanged:
                return report("이미 최대화된 창",FrameChange(before:before,target:targetFrame,after:before,placementVerified:true,exact:true))
            case let .maximize(maximizeFrame):
                let change=await applyFrame(maximizeFrame,to:identity,visible:area.visible,before:before)
                if let after=change.after,!WindowGeometry.approximatelyEqual(after,before,tolerance:frameTolerance) {
                    let original=restoreState.originalFrame(for:identity) ?? before
                    if WindowGeometry.shouldRecordMaximizedFrame(placementVerified:change.placementVerified,cancelled:change.cancelled) {
                        restoreState.recordMaximizedFrame(for:identity,originalFrame:original,frame:after)
                    } else {
                        restoreState.rememberOriginalFrame(for:identity,frame:original)
                    }
                }
                return report("창 최대화",change)
            case let .restore(originalFrame):
                let change=await applyFrame(originalFrame,to:identity,visible:area.visible,before:before)
                if restoreCompleted(change) { restoreState.remove(for:identity) }
                return report("이전 크기로 복원",change)
            }

        case .restore:
            guard let original=restoreState.originalFrame(for:identity) else { return "복원할 창 크기가 없습니다." }
            guard canSetFrame(identity.window),!isFullscreen(identity.window) else {
                return "이 창은 위치 또는 크기를 변경할 수 없거나 전체 화면 상태입니다."
            }
            guard let area=screenArea(for:before) else { return "화면 정보를 읽지 못했습니다." }
            let change=await applyFrame(original,to:identity,visible:area.visible,before:before)
            if restoreCompleted(change) { restoreState.remove(for:identity) }
            return report("배치 전 크기로 복원",change)

        case .minimize:
            guard !isFullscreen(identity.window) else { return "전체 화면 창은 최소화하지 않았습니다." }
            var settable=DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(identity.window,kAXMinimizedAttribute as CFString,&settable) == .success,settable.boolValue else {
                return "이 창은 최소화를 허용하지 않습니다."
            }
            guard !Task.isCancelled,isCurrentTarget(identity) else { return "대상 창이 바뀌었거나 동작이 취소되어 최소화하지 않았습니다." }
            let write=AXUIElementSetAttributeValue(identity.window,kAXMinimizedAttribute as CFString,kCFBooleanTrue)
            let sleepCompleted=await pause(nanoseconds:50_000_000)
            var value:CFTypeRef?
            let read=AXUIElementCopyAttributeValue(identity.window,kAXMinimizedAttribute as CFString,&value)
            let minimized=read == .success && (value as? Bool) == true
            let status:String
            if !sleepCompleted { status=minimized ? "창을 최소화했지만 대기 중 동작이 취소됐습니다.":"최소화 요청 후 동작이 취소됐습니다." }
            else { status=minimized ? "창을 최소화했습니다.":(write == .success ? "최소화 요청을 확인하지 못했습니다.":"앱이 창 최소화를 허용하지 않았습니다.") }
            let result="\(status) · 전 \(format(before)) → 요청 최소화 → 후 \(frame(identity.window).map(format) ?? "읽기 불가") · AX minimize \(write), read \(read)"
            return result
        }
    }

    // Keep the existing convenience entry point for callers that do not capture a shortcut target.
    static func tile(_ direction:TileDirection) async -> String {
        await performCurrent(action:.tile(direction))
    }

    private static func focusedWindow(in application:AXUIElement) -> AXUIElement? {
        var value:CFTypeRef?
        guard AXUIElementCopyAttributeValue(application,kAXFocusedWindowAttribute as CFString,&value) == .success,
              let value,CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value,to:AXUIElement.self)
    }

    private static func frame(_ window:AXUIElement) -> CGRect? {
        var pointValue:CFTypeRef?,sizeValue:CFTypeRef?,point=CGPoint.zero,size=CGSize.zero
        guard AXUIElementCopyAttributeValue(window,kAXPositionAttribute as CFString,&pointValue) == .success,
              AXUIElementCopyAttributeValue(window,kAXSizeAttribute as CFString,&sizeValue) == .success,
              let pointValue,let sizeValue,
              CFGetTypeID(pointValue) == AXValueGetTypeID(),CFGetTypeID(sizeValue) == AXValueGetTypeID(),
              AXValueGetValue(unsafeBitCast(pointValue,to:AXValue.self),.cgPoint,&point),
              AXValueGetValue(unsafeBitCast(sizeValue,to:AXValue.self),.cgSize,&size) else { return nil }
        return CGRect(origin:point,size:size)
    }

    private static func canSetFrame(_ window:AXUIElement) -> Bool {
        var movable=DarwinBoolean(false),resizable=DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(window,kAXPositionAttribute as CFString,&movable) == .success && movable.boolValue &&
            AXUIElementIsAttributeSettable(window,kAXSizeAttribute as CFString,&resizable) == .success && resizable.boolValue
    }

    private static func isCurrentTarget(_ identity:WindowIdentity) -> Bool {
        guard let frontmost=NSWorkspace.shared.frontmostApplication,!frontmost.isTerminated,
              frontmost.processIdentifier == identity.processIdentifier,
              let focused=focusedWindow(in:identity.application) else { return false }
        return CFEqual(focused,identity.window)
    }

    private static func pause(nanoseconds:UInt64) async -> Bool {
        do { try await Task.sleep(nanoseconds:nanoseconds);return true }
        catch { return false }
    }

    private static func isFullscreen(_ window:AXUIElement) -> Bool {
        var value:CFTypeRef?
        _=AXUIElementCopyAttributeValue(window,"AXFullScreen" as CFString,&value)
        return (value as? Bool) == true
    }

    private static func screenArea(for windowFrame:CGRect) -> ScreenArea? {
        let screens=NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let primary=screens.first(where:{$0.frame.origin == .zero}) ?? NSScreen.main ?? screens[0]
        func axRect(_ rect:CGRect) -> CGRect {
            CGRect(x:rect.minX,y:primary.frame.maxY-rect.maxY,width:rect.width,height:rect.height)
        }
        let selected=screens.max { left,right in
            let leftIntersection=axRect(left.frame).intersection(windowFrame)
            let rightIntersection=axRect(right.frame).intersection(windowFrame)
            let leftArea=leftIntersection.isNull ? 0:leftIntersection.width*leftIntersection.height
            let rightArea=rightIntersection.isNull ? 0:rightIntersection.width*rightIntersection.height
            return leftArea < rightArea
        } ?? primary
        return ScreenArea(visible:axRect(selected.visibleFrame))
    }

    private static func applyFrame(_ target:CGRect,to identity:WindowIdentity,visible:CGRect,before:CGRect) async -> FrameChange {
        var latest:CGRect?
        var sizeError:AXError?,positionError:AXError?
        for _ in 0..<retryCount {
            guard !Task.isCancelled,isCurrentTarget(identity) else {
                return FrameChange(before:before,target:target,after:frame(identity.window) ?? latest,
                                   placementVerified:false,exact:false,sizeError:sizeError,
                                   positionError:positionError,cancelled:true)
            }
            var size=target.size
            if let value=AXValueCreate(.cgSize,&size) {
                sizeError=AXUIElementSetAttributeValue(identity.window,kAXSizeAttribute as CFString,value)
            } else {
                sizeError = .illegalArgument
            }
            guard await pause(nanoseconds:45_000_000) else {
                return FrameChange(before:before,target:target,after:frame(identity.window) ?? latest,
                                   placementVerified:false,exact:false,sizeError:sizeError,
                                   positionError:positionError,cancelled:true)
            }
            guard let sized=frame(identity.window) else { continue }
            latest=sized
            guard !Task.isCancelled,isCurrentTarget(identity) else {
                return FrameChange(before:before,target:target,after:sized,placementVerified:false,exact:false,
                                   sizeError:sizeError,positionError:positionError,cancelled:true)
            }
            let placement=WindowGeometry.visiblePlacement(size:sized.size,alignedTo:target,within:visible)
            var point=placement.origin
            if let value=AXValueCreate(.cgPoint,&point) {
                positionError=AXUIElementSetAttributeValue(identity.window,kAXPositionAttribute as CFString,value)
            } else {
                positionError = .illegalArgument
            }
            guard await pause(nanoseconds:45_000_000) else {
                return FrameChange(before:before,target:target,after:frame(identity.window) ?? latest,
                                   placementVerified:false,exact:false,sizeError:sizeError,
                                   positionError:positionError,cancelled:true)
            }
            guard let after=frame(identity.window) else { continue }
            latest=after
            let expected=WindowGeometry.visiblePlacement(size:after.size,alignedTo:target,within:visible)
            let placementVerified=abs(after.minX-expected.minX)<=frameTolerance && abs(after.minY-expected.minY)<=frameTolerance
            let exact=WindowGeometry.approximatelyEqual(after,target,tolerance:frameTolerance)
            if exact { return FrameChange(before:before,target:target,after:after,placementVerified:true,exact:true,
                                          sizeError:sizeError,positionError:positionError) }
            if placementVerified && WindowGeometry.approximatelyEqual(after.size,target.size,tolerance:frameTolerance) {
                return FrameChange(before:before,target:target,after:after,placementVerified:true,exact:false,
                                   sizeError:sizeError,positionError:positionError)
            }
        }
        guard let after=latest else { return FrameChange(before:before,target:target,after:nil,placementVerified:false,exact:false,
                                                         sizeError:sizeError,positionError:positionError) }
        let expected=WindowGeometry.visiblePlacement(size:after.size,alignedTo:target,within:visible)
        let placementVerified=abs(after.minX-expected.minX)<=frameTolerance && abs(after.minY-expected.minY)<=frameTolerance
        return FrameChange(before:before,target:target,after:after,placementVerified:placementVerified,exact:false,
                           sizeError:sizeError,positionError:positionError)
    }

    private static func report(_ action:String,_ change:FrameChange) -> String {
        let after=change.after.map(format) ?? "읽기 불가"
        let status:String
        if change.cancelled { status="대상 앱이나 창이 바뀌어 추가 변경을 취소했습니다." }
        else if change.exact { status="요청한 창 크기와 위치를 확인했습니다." }
        else if change.placementVerified,let frame=change.after {
            status=WindowGeometry.approximatelyEqual(frame.size,change.target.size,tolerance:frameTolerance)
                ? "화면 밖으로 나가지 않도록 창 위치를 조정했습니다."
                : "창 위치는 확인했지만 앱이 요청한 크기를 적용하지 않았습니다."
        }
        else if let frame=change.after,!WindowGeometry.approximatelyEqual(frame,change.before,tolerance:frameTolerance) {
            status="창이 일부 변경됐지만 요청한 위치를 확인하지 못했습니다."
        } else { status="앱이 창 변경 요청을 적용하지 않았습니다." }
        return "\(action): \(status) · 전 \(format(change.before)) → 요청 \(format(change.target)) → 후 \(after) · AX size \(code(change.sizeError)) / position \(code(change.positionError))"
    }

    private static func restoreCompleted(_ change:FrameChange) -> Bool {
        guard !change.cancelled,change.placementVerified,let after=change.after else { return false }
        return WindowGeometry.approximatelyEqual(after.size,change.target.size,tolerance:frameTolerance)
    }

    private static func code(_ error:AXError?) -> String {
        error.map { String(describing:$0) } ?? "not attempted"
    }

    private static func format(_ rect:CGRect) -> String {
        String(format:"[x %.0f y %.0f w %.0f h %.0f]",locale:Locale(identifier:"en_US_POSIX"),
               Double(rect.minX),Double(rect.minY),Double(rect.width),Double(rect.height))
    }

    private static func pruneStaleRestoreState() {
        restoreState.retain { identity in
            guard let app=NSRunningApplication(processIdentifier:identity.processIdentifier),!app.isTerminated else { return false }
            var value:CFTypeRef?
            guard AXUIElementCopyAttributeValue(identity.application,kAXWindowsAttribute as CFString,&value) == .success,
                  let windows=value as? [AXUIElement] else { return true }
            return windows.contains { CFEqual($0,identity.window) }
        }
    }
}
