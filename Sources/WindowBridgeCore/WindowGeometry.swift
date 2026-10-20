import CoreGraphics

public enum WindowAction: Equatable {
    case tile(TileDirection)
    case toggleMaximize
    case restore
    case minimize

}

public enum WindowMaximizeTransition: Equatable {
    case maximize(CGRect)
    case restore(CGRect)
    case unchanged
}

public enum WindowGeometry {
    public static func visiblePlacement(size:CGSize,alignedTo target:CGRect,within visible:CGRect) -> CGRect {
        let width=max(0,size.width),height=max(0,size.height)
        let xLimit=max(visible.minX,visible.maxX-width)
        let yLimit=max(visible.minY,visible.maxY-height)
        let x=min(max(target.minX,visible.minX),xLimit)
        let y=min(max(target.minY,visible.minY),yLimit)
        return CGRect(x:x,y:y,width:width,height:height)
    }

    public static func approximatelyEqual(_ lhs:CGRect,_ rhs:CGRect,tolerance:CGFloat=1) -> Bool {
        abs(lhs.minX-rhs.minX)<=tolerance && abs(lhs.minY-rhs.minY)<=tolerance &&
        abs(lhs.width-rhs.width)<=tolerance && abs(lhs.height-rhs.height)<=tolerance
    }

    public static func approximatelyEqual(_ lhs:CGSize,_ rhs:CGSize,tolerance:CGFloat=1) -> Bool {
        abs(lhs.width-rhs.width)<=tolerance && abs(lhs.height-rhs.height)<=tolerance
    }

    public static func shouldRecordMaximizedFrame(placementVerified:Bool,cancelled:Bool) -> Bool {
        placementVerified && !cancelled
    }
}

public struct WindowRestoreState<Key:Equatable> {
    private struct Entry {
        let key:Key
        let originalFrame:CGRect
        var maximizedFrame:CGRect?
    }
    private var entries:[Entry]=[]

    public init() {}

    public func toggleMaximize(for key:Key,current:CGRect,target:CGRect) -> WindowMaximizeTransition {
        if let entry=entries.first(where:{$0.key == key}) {
            if let maximizedFrame=entry.maximizedFrame,WindowGeometry.approximatelyEqual(current,maximizedFrame) {
                return .restore(entry.originalFrame)
            }
            return .maximize(target)
        }
        return WindowGeometry.approximatelyEqual(current,target) ? .unchanged:.maximize(target)
    }

    public mutating func rememberOriginalFrame(for key:Key,frame:CGRect) {
        guard !entries.contains(where:{$0.key == key}) else { return }
        entries.append(Entry(key:key,originalFrame:frame,maximizedFrame:nil))
    }

    public func originalFrame(for key:Key) -> CGRect? {
        entries.first(where:{$0.key == key})?.originalFrame
    }

    public mutating func recordMaximizedFrame(for key:Key,originalFrame:CGRect,frame:CGRect) {
        if let index=entries.firstIndex(where:{$0.key == key}) {
            entries[index].maximizedFrame=frame
        } else {
            entries.append(Entry(key:key,originalFrame:originalFrame,maximizedFrame:frame))
        }
    }

    public mutating func remove(for key:Key) {
        entries.removeAll(where:{$0.key == key})
    }

    public mutating func retain(_ isLive:(Key)->Bool) {
        entries.removeAll { !isLive($0.key) }
    }
}
