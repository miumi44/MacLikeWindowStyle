import AppKit
import WindowBridgeCore

private final class HoverOverlay: NSView {
    override func hitTest(_ point:NSPoint) -> NSView? { nil }
}

final class SwitcherView: NSView {
    var hoverEnabled=true
    private var tracking:NSTrackingArea?
    private var hoveredID:UInt32?
    private let hoverOverlay=HoverOverlay(frame:.zero)
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if hoverOverlay.superview == nil {
            hoverOverlay.wantsLayer=true
            hoverOverlay.layer?.cornerRadius=15
            hoverOverlay.layer?.backgroundColor=NSColor.white.withAlphaComponent(0.045).cgColor
            hoverOverlay.layer?.borderColor=NSColor.white.withAlphaComponent(0.45).cgColor
            hoverOverlay.layer?.borderWidth=1
            hoverOverlay.layer?.opacity=0
            addSubview(hoverOverlay)
        }
        window?.acceptsMouseMovedEvents=true
        clearHover()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area=NSTrackingArea(rect:.zero,options:[.activeAlways,.mouseMoved,.mouseEnteredAndExited,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(area);tracking=area
    }
    private func fadeHover(to opacity:Float) {
        guard let layer=hoverOverlay.layer else { return }
        let from=layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin();CATransaction.setDisableActions(true);layer.opacity=opacity;CATransaction.commit()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let animation=CABasicAnimation(keyPath:"opacity")
            animation.fromValue=from;animation.toValue=opacity;animation.duration=0.12
            animation.timingFunction=CAMediaTimingFunction(name:.easeOut)
            layer.add(animation,forKey:"hoverFade")
        } else { layer.removeAnimation(forKey:"hoverFade") }
    }
    func clearHover() { hoveredID=nil;fadeHover(to:0) }
    override func mouseMoved(with event:NSEvent) {
        guard hoverEnabled else { clearHover();return }
        let point=convert(event.locationInWindow,from:nil)
        let hit=rects.first { $0.1.contains(point) }
        guard hit?.0 != hoveredID else { return }
        hoveredID=hit?.0
        if let hit {
            hoverOverlay.frame=hit.1.insetBy(dx:-2,dy:-2)
            fadeHover(to:1)
        } else { fadeHover(to:0) }
    }
    override func mouseEntered(with event:NSEvent) { mouseMoved(with:event) }
    override func mouseExited(with event:NSEvent) { clearHover() }

    var items: [WindowItem] = []
    var selection = WindowSelection()
    var demo = false
    var onPick: ((UInt32)->Void)?
    var onCancel: (()->Void)?
    var onStep: ((Int)->Void)?
    var onRow: ((Int)->Void)?
    var rects: [(UInt32,NSRect)] = []
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    private let ink = NSColor(calibratedWhite:0.95,alpha:1)
    private func text(_ string:String,_ rect:NSRect,_ size:CGFloat,_ color:NSColor,_ weight:NSFont.Weight = .regular) {
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        (string as NSString).draw(in:rect,withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:weight),.foregroundColor:color,.paragraphStyle:style])
    }
    override func draw(_ dirtyRect:NSRect) {
        NSColor(calibratedRed:0.075,green:0.09,blue:0.12,alpha:0.97).setFill()
        NSBezierPath(roundedRect:bounds,xRadius:24,yRadius:24).fill()
        text("WindowBridge",NSRect(x:28,y:21,width:250,height:24),18,ink,.semibold)
        text(demo ? "디자인 미리보기 · 예시 창" : "열린 창 \(items.count)개",NSRect(x:bounds.width-265,y:25,width:235,height:20),12,.secondaryLabelColor)
        rects = []
        let page = selection.index / 9
        let visible = Array(items.dropFirst(page*9).prefix(9))
        let columns = min(3,max(1,visible.count)); let gap:CGFloat = 14
        let width = (bounds.width-56-CGFloat(columns-1)*gap)/CGFloat(columns)
        for (i,item) in visible.enumerated() {
            let r = NSRect(x:28+CGFloat(i%columns)*(width+gap),y:65+CGFloat(i/columns)*210,width:width,height:196)
            rects.append((item.id,r))
            let selected = item.id == selection.selected
            (selected ? NSColor(calibratedRed:0.16,green:0.23,blue:0.32,alpha:1) : NSColor(calibratedWhite:0.14,alpha:1)).setFill()
            let card = NSBezierPath(roundedRect:r,xRadius:13,yRadius:13); card.fill()
            if selected { NSColor(calibratedRed:0.42,green:0.73,blue:1,alpha:1).setStroke(); card.lineWidth=2.5;card.stroke() }
            let preview = NSRect(x:r.minX+8,y:r.minY+8,width:r.width-16,height:140)
            NSColor(calibratedWhite:0.08,alpha:1).setFill();NSBezierPath(roundedRect:preview,xRadius:8,yRadius:8).fill()
            if let image = item.thumbnail {
                let scale = min(preview.width/image.size.width,preview.height/image.size.height)
                let size = NSSize(width:image.size.width*scale,height:image.size.height*scale)
                image.draw(in:NSRect(x:preview.midX-size.width/2,y:preview.midY-size.height/2,width:size.width,height:size.height),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
            } else if demo { drawDemo(preview,index:i) }
            else {
                item.icon?.draw(in:NSRect(x:preview.midX-24,y:preview.midY-24,width:48,height:48),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
                text("미리보기 불러오는 중",NSRect(x:preview.minX+12,y:preview.maxY-24,width:preview.width-24,height:16),10,.gray)
            }
            item.icon?.draw(in:NSRect(x:r.minX+12,y:r.maxY-35,width:22,height:22),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
            let tx = item.icon == nil ? r.minX+12 : r.minX+42
            text(item.app,NSRect(x:tx,y:r.maxY-39,width:r.maxX-tx-10,height:16),11,.lightGray,.medium)
            text(item.title,NSRect(x:tx,y:r.maxY-23,width:r.maxX-tx-10,height:17),12,ink)
        }
        if items.isEmpty { text("표시할 창이 없습니다",NSRect(x:28,y:100,width:400,height:30),17,ink) }
        text("Alt+Tab  다음    방향키  이동    클릭/Enter  선택    Esc  취소",NSRect(x:28,y:bounds.height-34,width:bounds.width-180,height:20),11,.lightGray)
        text("\(items.isEmpty ? 0 : selection.index+1) / \(items.count)",NSRect(x:bounds.width-100,y:bounds.height-34,width:75,height:20),11,.lightGray)
    }
    private func drawDemo(_ r:NSRect,index:Int) {
        let palette:[NSColor] = [.systemBlue,.systemTeal,.systemPurple,.systemOrange]
        palette[index%4].withAlphaComponent(0.16).setFill();NSBezierPath(roundedRect:r,xRadius:8,yRadius:8).fill()
        NSColor(calibratedWhite:0.24,alpha:1).setFill(); NSBezierPath(roundedRect:NSRect(x:r.minX+10,y:r.minY+10,width:r.width-20,height:14),xRadius:4,yRadius:4).fill()
        for row in 0..<5 {
            palette[index%4].withAlphaComponent(row == 0 ? 0.6 : 0.2).setFill()
            NSBezierPath(roundedRect:NSRect(x:r.minX+15,y:r.minY+38+CGFloat(row)*16,width:(r.width-45)*CGFloat([0.8,1,0.6,0.9,0.7][row]),height:7),xRadius:3,yRadius:3).fill()
        }
    }
    override func mouseDown(with event:NSEvent) {
        let point = convert(event.locationInWindow,from:nil)
        if let item = rects.first(where:{$0.1.contains(point)}) { onPick?(item.0) }
    }
    override func keyDown(with event:NSEvent) {
        switch event.keyCode {
        case 53:onCancel?()
        case 48:onStep?(event.modifierFlags.contains(.shift) ? -1 : 1)
        case 123:onStep?(-1)
        case 124:onStep?(1)
        case 125:onRow?(1)
        case 126:onRow?(-1)
        case 36:if let id=selection.selected { onPick?(id) }
        default:break
        }
    }
}
