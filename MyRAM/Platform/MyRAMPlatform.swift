enum MyRAMPlatform {
    static var isRealIOSOrIPadOS: Bool {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }

    static var isNativeMacOS: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    static var isMacCatalyst: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }
}
