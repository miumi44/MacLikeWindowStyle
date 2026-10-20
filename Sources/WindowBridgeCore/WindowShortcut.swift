public func windowAction(keyCode:Int64,command:Bool,leftOption:Bool,control:Bool,shift:Bool) -> WindowAction? {
    guard command && leftOption && !control && !shift else { return nil }
    if let direction=tileDirection(keyCode:keyCode,command:command,leftAlt:leftOption,control:control,shift:shift) { return .tile(direction) }
    switch keyCode { case 36:return .toggleMaximize;case 46:return .minimize;default:return nil }
}

public struct WindowShortcutState {
    public struct Request {
        public let session:Int
        public let action:WindowAction
    }
    private var held=Set<Int64>()
    private var pending:Request?
    private var command=true,option=true
    private var serial=0
    public init() {}
    public var active:Bool { pending != nil }
    public var hasHeldKeys:Bool { !held.isEmpty }
    public func contains(_ code:Int64) -> Bool { held.contains(code) }
    // Return a session only for the first down, when the caller captures its target.
    @discardableResult public mutating func press(_ code:Int64,action:WindowAction) -> Int? {
        guard held.insert(code).inserted else { return nil }
        command=true;option=true
        if let previous=pending { pending=Request(session:previous.session,action:action);return nil }
        serial += 1;pending=Request(session:serial,action:action);return serial
    }
    public mutating func keyUp(_ code:Int64) -> Bool { held.remove(code) != nil }
    public mutating func modifiers(command:Bool,option:Bool) { self.command=command;self.option=option }
    public mutating func takeReady() -> Request? {
        guard held.isEmpty && !command && !option else { return nil }
        defer { pending=nil };return pending
    }
    // Preserve consumed downs until their ups arrive, even when a pending action is cancelled.
    public mutating func cancel() { pending=nil }
}
