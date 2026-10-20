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
    private var tileKeys=WindowShortcutState()
    private var switchingEnabled=false
    private var tilingEnabled=false
    var onWindowActionStart: ((Int)->Void)?
    var onWindowAction: ((Int,WindowAction)->Void)?
    var onWindowActionCancel: (()->Void)?
    func cancelWindowAction() {
        lock.lock();tileKeys.cancel();lock.unlock()
        onWindowActionCancel?()
    }
    private func dispatchReadyWindowAction() {
        if let request=tileKeys.takeReady(),tilingEnabled {
            DispatchQueue.main.async { self.onWindowAction?(request.session,request.action) }
        }
    }
    func configure(switching:Bool,tiling:Bool) {
        lock.lock();switchingEnabled=switching;tilingEnabled=tiling;if !tiling { tileKeys.cancel() };lock.unlock()
    }
    func stopIfUnused() {
        lock.lock()
        let idle = !switchingEnabled && !tilingEnabled && !tileKeys.hasHeldKeys
        lock.unlock()
        if idle { stop() }
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
    func receive(_ type:CGEventType,_ event:CGEvent) -> Unmanaged<CGEvent>? {
        lock.lock();defer { lock.unlock() }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let session=state.session;state.reset();tileKeys.cancel()
            DispatchQueue.main.async { self.onWindowActionCancel?() }
            if let tap { CGEvent.tapEnable(tap:tap,enable:true) }
            if let session { DispatchQueue.main.async { self.onEscape?(session) } }
            return Unmanaged.passUnretained(event)
        }
        let code=event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp, tileKeys.keyUp(code) {
            dispatchReadyWindowAction()
            if !switchingEnabled && !tilingEnabled && !tileKeys.hasHeldKeys {
                DispatchQueue.main.async { self.stopIfUnused() }
            }
            return nil
        }
        if type == .flagsChanged {
            tileKeys.modifiers(command:event.flags.contains(.maskCommand),option:event.flags.contains(.maskAlternate))
            dispatchReadyWindowAction()
            if let session=state.modifier(keyCode:code,optionHeld:event.flags.contains(.maskAlternate) && event.flags.rawValue & 0x20 != 0) {
                DispatchQueue.main.async { self.onRelease?(session) }
            }
        } else if type == .keyDown {
            if tileKeys.contains(code) {
                if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
                // A fresh down means the old up was lost (for example across sleep).
                _=tileKeys.keyUp(code);tileKeys.cancel()
                DispatchQueue.main.async { self.onWindowActionCancel?();self.stopIfUnused() }
            }
            if code == 53 && tileKeys.active {
                tileKeys.cancel()
                DispatchQueue.main.async { self.onWindowActionCancel?() }
                // Escape itself is not intercepted, preserving its normal down/up pair.
            }
            if tilingEnabled,state.session == nil,
               let action=windowAction(keyCode:code,command:event.flags.contains(.maskCommand),
                   leftOption:event.flags.contains(.maskAlternate) && event.flags.rawValue & 0x20 != 0,
                   control:event.flags.contains(.maskControl),shift:event.flags.contains(.maskShift)) {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    if let session=tileKeys.press(code,action:action) {
                        DispatchQueue.main.async { self.onWindowActionStart?(session) }
                    }
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
        lock.lock();state.reset();tileKeys.cancel();let loop=eventLoop;eventLoop=nil;lock.unlock()
        if let tap { CGEvent.tapEnable(tap:tap,enable:false);CFMachPortInvalidate(tap) }
        if let loop { CFRunLoopStop(loop) }
        source=nil;tap=nil;worker=nil
    }
}
