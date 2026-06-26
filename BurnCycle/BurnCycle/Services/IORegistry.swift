import Foundation
import IOKit

/// Shared IOKit helpers. `property` copies a SINGLE key from an IORegistry entry
/// (cheaper than copying the whole property dictionary) and returns it as Any?,
/// nil when the key is absent.
enum IORegistry {
    static func property(_ service: io_service_t, _ key: String) -> Any? {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return value.takeRetainedValue()
    }
}
