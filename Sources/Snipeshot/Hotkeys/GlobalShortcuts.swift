import AppKit
import Carbon.HIToolbox

extension Notification.Name {
    static let shortcutRecordingBegan = Notification.Name("\(AppIdentity.bundleID).shortcutRecordingBegan")
    static let shortcutRecordingEnded = Notification.Name("\(AppIdentity.bundleID).shortcutRecordingEnded")
}

/// Registers system-wide shortcuts through Carbon's RegisterEventHotKey, the only public API
/// that delivers global key combos without Accessibility permission.
final class GlobalShortcuts {
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private(set) var failed: [UInt32: OSStatus] = [:]

    private static let signature: OSType = 0x534E_4450 // 'SNDP'

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard err == noErr else { return err }
            let manager = Unmanaged<GlobalShortcuts>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { manager.handlers[hotKeyID.id]?() }
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)
        if status != noErr { log("hot key handler not installed, OSStatus \(status)") }
    }

    deinit {
        unregisterAll()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Replaces all registrations. Returns the ids that could not be registered.
    @discardableResult
    func register(_ bindings: [(id: UInt32, combo: KeyCombo, handler: () -> Void)]) -> [UInt32: OSStatus] {
        unregisterAll()
        failed = [:]
        for binding in bindings {
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: Self.signature, id: binding.id)
            let status = RegisterEventHotKey(binding.combo.keyCode, binding.combo.modifiers, hkID,
                                             GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
            if status == noErr, let ref {
                refs[binding.id] = ref
                handlers[binding.id] = binding.handler
            } else {
                failed[binding.id] = status
                log("shortcut \(binding.combo.displayString) not registered, OSStatus \(status)")
            }
        }
        return failed
    }

    func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs = [:]
        handlers = [:]
    }
}
