import Foundation
import Carbon

enum HotkeyAction: UInt32, CaseIterable {
    case translateAndReplace = 1
    case translatePopup = 2
    case openQuickWindow = 3
    case polishEnglish = 4
}

final class HotkeyManager {
    private var hotKeyRefs: [HotkeyAction: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private let signature: OSType = 0x4F4C5452 // 'OLTR'
    private var onTrigger: ((HotkeyAction) -> Void)?

    init(onTrigger: @escaping (HotkeyAction) -> Void) {
        self.onTrigger = onTrigger
        installHandler()
    }

    deinit {
        unregisterAll()
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
        }
    }

    func registerAll(from config: AppConfig) {
        unregisterAll()
        register(action: .translateAndReplace, binding: config.replaceHotkey)
        register(action: .translatePopup, binding: config.popupHotkey)
        register(action: .openQuickWindow, binding: config.quickWindowHotkey)
        register(action: .polishEnglish, binding: config.polishHotkey)
    }

    func unregisterAll() {
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

    private func register(action: HotkeyAction, binding: HotkeyBinding) {
        let hotKeyID = EventHotKeyID(signature: signature, id: action.rawValue)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status == noErr, let ref = hotKeyRef {
            hotKeyRefs[action] = ref
        }
    }

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event = event, let userData = userData else {
                return OSStatus(eventNotHandledErr)
            }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }

            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            if let action = HotkeyAction(rawValue: hotKeyID.id) {
                DispatchQueue.main.async {
                    manager.onTrigger?(action)
                }
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )
    }
}
