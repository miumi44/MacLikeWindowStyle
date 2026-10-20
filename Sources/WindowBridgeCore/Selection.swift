import CoreGraphics
public struct WindowSelection {
    public private(set) var ids: [UInt32] = []
    public private(set) var index = 0
    public var selected: UInt32? { ids.isEmpty ? nil : ids[index] }
    public init() {}
    public mutating func begin(ids: [UInt32], reverse: Bool) {
        self.ids = ids
        index = ids.isEmpty ? 0 : (reverse ? ids.count - 1 : min(1, ids.count - 1))
    }
    public mutating func step(_ delta: Int) {
        guard !ids.isEmpty else { return }
        index = ((index + delta) % ids.count + ids.count) % ids.count
    }
    public mutating func moveRow(_ delta:Int,columns:Int) {
        guard !ids.isEmpty,columns > 0 else { return }
        let lastRow=(ids.count-1)/columns
        let row=min(lastRow,max(0,index/columns+delta))
        index=min(ids.count-1,row*columns+index%columns)
    }
    public mutating func select(_ id: UInt32) {
        if let i = ids.firstIndex(of: id) { index = i }
    }
}
public func orderedWindows(available: [UInt32], recent: [UInt32]) -> [UInt32] {
    var seen = Set<UInt32>(); let current = Set(available)
    return (recent + available).filter { current.contains($0) && seen.insert($0).inserted }
}

// Read the flags carried by this event, not a potentially stale system key-state query.
public func shouldCommitOnModifierChange(active: Bool, keyCode: Int64, optionHeld: Bool) -> Bool {
    active && keyCode == 58 && !optionHeld
}

public struct HotKeyState {
    public private(set) var session: Int?
    private var nextSession = 0
    private var leftOption = false
    public init() {}
    @discardableResult public mutating func modifier(keyCode:Int64, optionHeld:Bool) -> Int? {
        guard keyCode == 58 else { return nil }
        leftOption = optionHeld
        guard !optionHeld else { return nil }
        let previous=session;session=nil;return previous
    }
    public mutating func tab(optionHeld:Bool) -> Int? {
        guard leftOption && optionHeld else { return nil }
        if session == nil { nextSession += 1;session=nextSession }
        return session
    }
    public mutating func cancel(session:Int) { if self.session == session { self.session=nil } }
    public mutating func reset() { session=nil;leftOption=false }
}

public func windowActivationSucceeded(raised:Bool,targetPID:Int32,frontPID:Int32?,focused:Bool) -> Bool {
    raised && targetPID == frontPID && focused
}

public func thumbnailCaptureOrder(ids:[UInt32],selected:UInt32?) -> [UInt32] {
    var seen=Set<UInt32>()
    let preferred=selected.flatMap { ids.contains($0) ? $0 : nil }
    return ((preferred.map { [$0] } ?? []) + ids).filter { seen.insert($0).inserted }
}
public struct ThumbnailFreshness {
    private var captured:[UInt32:Double]=[:]
    public init() {}
    public func needsCapture(_ id:UInt32,now:Double) -> Bool {
        guard let last=captured[id] else { return true }
        return now-last >= 2 || now < last
    }
    public mutating func record(_ id:UInt32,now:Double) { captured[id]=now }
    public mutating func retain(ids:Set<UInt32>) { captured=captured.filter { ids.contains($0.key) } }
}

public enum TileDirection: Equatable { case left, right, up, down }
public func tileDirection(keyCode:Int64,command:Bool,leftAlt:Bool,control:Bool,shift:Bool) -> TileDirection? {
    guard command && leftAlt && !control && !shift else { return nil }
    switch keyCode { case 123:return .left;case 124:return .right;case 125:return .down;case 126:return .up;default:return nil }
}
// Input and output use AX coordinates: origin at the top left of the primary display.
public func tileFrame(_ direction:TileDirection,in area:CGRect) -> CGRect {
    switch direction {
    case .left:return CGRect(x:area.minX,y:area.minY,width:area.width/2,height:area.height)
    case .right:return CGRect(x:area.midX,y:area.minY,width:area.width/2,height:area.height)
    case .up:return CGRect(x:area.minX,y:area.minY,width:area.width,height:area.height/2)
    case .down:return CGRect(x:area.minX,y:area.midY,width:area.width,height:area.height/2)
    }
}
