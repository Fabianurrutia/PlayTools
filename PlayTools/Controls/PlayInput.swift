import Foundation
import UIKit
import GameController

// This class is a coordinator (and module entrance), coordinating other concrete classes

class PlayInput {
    static let shared = PlayInput()

    static var touchQueue = DispatchQueue.init(label: "playcover.toucher",
                                               qos: .userInteractive,
                                               autoreleaseFrequency: .workItem)

    @objc func drainMainDispatchQueue() {
        _dispatch_main_queue_callback_4CF(nil)
    }

    func initialize() {
        // Bridge the hardware keyboard into web (WKWebView) text fields, which Catalyst does not
        // route keystrokes to. Installed unconditionally so it works even with keymapping off
        // (e.g. typing/pasting credentials into an in-app web login).
        WebTextInputBridge.setup()

        // drain the dispatch queue every frame for responding to GCController events
        let displaylink = CADisplayLink(target: self, selector: #selector(drainMainDispatchQueue))
        displaylink.add(to: .main, forMode: .common)

        if PlaySettings.shared.disableBuiltinMouse {
            simulateGCMouseDisconnect()
        }

        if !PlaySettings.shared.keymapping {
            return
        }

        let centre = NotificationCenter.default
        let main = OperationQueue.main

        centre.addObserver(forName: NSNotification.Name(rawValue: "NSWindowDidBecomeKeyNotification"), object: nil,
            queue: main) { _ in
            if mode.cursorHidden() {
                AKInterface.shared!.warpCursor()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5, qos: .utility) {
            if mode.cursorHidden() || !ActionDispatcher.cursorHideNecessary {
                return
            }
            Toast.initialize()
        }
        mode.initialize()
    }

    private func simulateGCMouseDisconnect() {
        NotificationCenter.default.addObserver(
            forName: .GCMouseDidConnect,
            object: nil,
            queue: .main
        ) { nofitication in
            guard let mouse = nofitication.object as? GCMouse else {
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1)) {
                NotificationCenter.default.post(name: .GCMouseDidDisconnect, object: mouse)
                mouse.mouseInput?.leftButton.pressedChangedHandler = nil
                mouse.mouseInput?.leftButton.valueChangedHandler = nil
                mouse.mouseInput?.rightButton?.pressedChangedHandler = nil
                mouse.mouseInput?.rightButton?.valueChangedHandler = nil
                mouse.mouseInput?.middleButton?.pressedChangedHandler = nil
                mouse.mouseInput?.middleButton?.valueChangedHandler = nil
                mouse.mouseInput?.auxiliaryButtons?.forEach { button in
                    button.pressedChangedHandler = nil
                    button.valueChangedHandler = nil
                }
                mouse.mouseInput?.scroll.valueChangedHandler = nil
                mouse.mouseInput?.mouseMovedHandler = nil
            }
        }
    }
}

// Bridges the Mac hardware keyboard into focused text inputs that Catalyst does not deliver
// keystrokes to — primarily WKWebView form fields (e.g. in-app web logins). Native UITextField/
// UITextView already receive the keyboard through the normal responder chain, so those are left
// untouched to avoid double input. The AKInterface monitor that drives this is installed
// unconditionally, so this works even when keymapping is disabled.
enum WebTextInputBridge {
    // Diagnostic logger: appends to ~/wtib.log (real home for the sandboxed app) and NSLog.
    // Never logs typed text content — only key codes and responder classes.
    static func log(_ msg: String) {
        NSLog("WTIB %@", msg)
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("wtib.log")
        guard let data = (msg + "\n").data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    static func setup() {
        guard let plugin = AKInterface.shared else {
            log("setup: AKInterface.shared is nil")
            return
        }
        log("setup: installing keyDown monitor")
        plugin.setupKeyWindowTextInput { text, keyCode, _ in
            WebTextInputBridge.handle(text: text, keyCode: keyCode)
        }
    }

    // Returns true only when the keystroke was inserted into a non-native text responder,
    // signalling AKInterface to consume the event. Returns false otherwise (pass-through).
    static func handle(text: String, keyCode: UInt16) -> Bool {
        let target = focusedKeyInput()
        log("key=\(keyCode) len=\(text.count) target=\(target?.name ?? "none")")
        guard let keyInput = target?.input else { return false }

        switch keyCode {
        case 51: // delete / backspace
            keyInput.deleteBackward()
            return true
        case 36, 76, 53: // return, enter, escape — let the web view handle these natively
            return false
        default:
            // Reject control characters and AppKit function-key code points (arrows, F-keys, …)
            let isPrintable = !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
                (scalar.value >= 0x20 && !(0xF700...0xF8FF).contains(scalar.value)) || scalar == "\t"
            }
            guard isPrintable else { return false }
            keyInput.insertText(text)
            return true
        }
    }

    // Resolves the live text-input target. A native UITextField/UITextView already gets the
    // keyboard through the responder chain, so it's intentionally skipped here. For a web login
    // the first responder is the outer WKWebView (which is not a UIKeyInput); the editable object
    // is its WKContentView descendant, which conforms to UIKeyInput — so descend to find it.
    static func focusedKeyInput() -> (input: UIKeyInput, name: String)? {
        guard let responder = UIResponder.ptCurrentFirstResponder else { return nil }
        if let keyInput = responder as? UIKeyInput,
           !(responder is UITextField), !(responder is UITextView) {
            return (keyInput, String(describing: type(of: responder)))
        }
        if let view = responder as? UIView {
            return findWebKeyInput(in: view)
        }
        return nil
    }

    private static func findWebKeyInput(in view: UIView) -> (input: UIKeyInput, name: String)? {
        let name = String(describing: type(of: view))
        if name.contains("WKContentView"), let keyInput = view as? UIKeyInput {
            return (keyInput, name)
        }
        for sub in view.subviews {
            if let found = findWebKeyInput(in: sub) { return found }
        }
        return nil
    }
}

extension UIResponder {
    private weak static var ptFirstResponder: UIResponder?

    // Resolves the app-wide first responder by dispatching an action to nil (the responder chain).
    static var ptCurrentFirstResponder: UIResponder? {
        ptFirstResponder = nil
        UIApplication.shared.sendAction(
            #selector(UIResponder.ptFindFirstResponder(_:)), to: nil, from: nil, for: nil)
        return ptFirstResponder
    }

    @objc private func ptFindFirstResponder(_ sender: Any) {
        UIResponder.ptFirstResponder = self
    }
}
