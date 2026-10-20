import AppKit
import WindowBridgeCore

// The event tap never queries WindowServer or waits for the UI thread.
final class HotKey {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var eventLoop: CFRunLoop?
    private var worker: Thread?
    private let lock=NSLock()
    private var state=HotKeyState()
    private var tileKeys=TileKeyState()
    private var switchingEnabled=false
    private var tilingEnabled=false
    var onTile: ((TileDirection)->Void)?
    func configure(switching:Bool,tiling:Bool) {
        lock.lock();switchingEnabled=switching;tilingEnabled=tiling;if !tiling { tileKeys.cancel() };lock.unlock()
    }
    var onTab: ((Int,Bool)->Void)?
    var onRelease: ((Int)->Void)?
    var onEscape: ((Int)->Void)?
    func cancel(session:Int) { lock.lock();state.cancel(session:session);lock.unlock() }
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask=(1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyUp.rawValue)
        tap=CGEvent.tapCreate(tap:.cgSessionEventTap,place:.headInsertEventTap,options:.defaultTap,eventsOfInterest:CGEventMask(mask),callback:{ _,type,event,context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue().receive(type,event)
        },userInfo:Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return false }
        let source=CFMachPortCreateRunLoopSource(kCFAllocatorDefault,tap,0)!
        self.source=source
        let ready=DispatchSemaphore(value:0)
        let thread=Thread { [self] in
            let loop=CFRunLoopGetCurrent()!
            lock.lock();eventLoop=loop;lock.unlock()
            CFRunLoopAddSource(loop,source,.commonModes)
            CGEvent.tapEnable(tap:tap,enable:true)
            ready.signal()
            CFRunLoopRun()
            CFRunLoopRemoveSource(loop,source,.commonModes)
        }
        thread.name="WindowBridge global keyboard"
        worker=thread;thread.start();ready.wait()
        return true
    }
    private func receive(_ type:CGEventType,_ event:CGEvent) -> Unmanaged<CGEvent>? {
        lock.lock();defer { lock.unlock() }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let session=state.session;state.reset();tileKeys=TileKeyState()
            if let tap { CGEvent.tapEnable(tap:tap,enable:true) }
            if let session { DispatchQueue.main.async { self.onEscape?(session) } }
            return Unmanaged.passUnretained(event)
        }
        let code=event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp, tileKeys.keyUp(code) { return nil }
        if type == .flagsChanged {
            if let direction=tileKeys.releaseModifiers(command:event.flags.contains(.maskCommand),option:event.flags.contains(.maskAlternate)),tilingEnabled {
                DispatchQueue.main.async { self.onTile?(direction) }
            }
            if let session=state.modifier(keyCode:code,optionHeld:event.flags.contains(.maskAlternate)) {
                DispatchQueue.main.async { self.onRelease?(session) }
            }
        } else if type == .keyDown {
            if tileKeys.contains(code) { return nil }
            if tilingEnabled,state.session == nil,
               let direction=tileDirection(keyCode:code,command:event.flags.contains(.maskCommand),
                   leftAlt:event.flags.contains(.maskAlternate) && event.flags.rawValue & 0x20 != 0,
                   control:event.flags.contains(.maskControl),shift:event.flags.contains(.maskShift)) {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    tileKeys.press(code,direction:direction)
                }
                return nil
            }
            if switchingEnabled && code == 48 && !event.flags.contains(.maskCommand) && !event.flags.contains(.maskControl),
               let session=state.tab(optionHeld:event.flags.contains(.maskAlternate)) {
                let reverse=event.flags.contains(.maskShift)
                DispatchQueue.main.async { self.onTab?(session,reverse) }
                return nil
            }
            if code == 53, let session=state.session {
                state.cancel(session:session)
                DispatchQueue.main.async { self.onEscape?(session) }
                return nil
            }
        }
        return Unmanaged.passUnretained(event)
    }
    func stop() {
        lock.lock();state.reset();tileKeys=TileKeyState();let loop=eventLoop;eventLoop=nil;lock.unlock()
        if let tap { CGEvent.tapEnable(tap:tap,enable:false);CFMachPortInvalidate(tap) }
        if let loop { CFRunLoopStop(loop) }
        source=nil;tap=nil;worker=nil
    }
}
