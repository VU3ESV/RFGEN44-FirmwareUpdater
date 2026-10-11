import FirmwareCore
import Foundation
import IOKit
import IOKit.usb

/// A Microchip USB device currently attached to the Mac.
struct USBDevice: Identifiable, Hashable, Sendable {
    let id: UInt64 // IORegistry entry ID, stable while plugged in
    let vendorID: UInt16
    let productID: UInt16
    let productName: String?
    let serialNumber: String?
    let locationID: UInt32?
    /// Debug-only stand-in (RFGEN44_SIMULATE_PICKIT); never talked to directly.
    var isSimulated = false

    var programmer: ProgrammerKind? { ProgrammerKind(vendorID: vendorID, productID: productID) }

    var displayName: String {
        programmer?.displayName ?? productName ?? String(format: "USB device %04X:%04X", vendorID, productID)
    }

    var usbID: String { String(format: "%04X:%04X", vendorID, productID) }
}

/// Watches IOKit for Microchip (VID 0x04D8) USB devices being plugged in and removed.
@MainActor
@Observable
final class USBToolMonitor {
    private(set) var devices: [USBDevice] = []

    var programmers: [USBDevice] { devices.filter { $0.programmer != nil } }
    var otherMicrochipDevices: [USBDevice] { devices.filter { $0.programmer == nil } }

    /// Called on the main thread whenever the set of attached devices changes.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var notifyPort: IONotificationPortRef?
    @ObservationIgnored private var addedIterator: io_iterator_t = 0
    @ObservationIgnored private var removedIterator: io_iterator_t = 0

    func start() {
        guard notifyPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)

        let context = Unmanaged.passUnretained(self).toOpaque()
        let onAdded: IOServiceMatchingCallback = { context, iterator in
            let monitor = Unmanaged<USBToolMonitor>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.devicesAdded(iterator) }
        }
        let onRemoved: IOServiceMatchingCallback = { context, iterator in
            let monitor = Unmanaged<USBToolMonitor>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.devicesRemoved(iterator) }
        }

        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, Self.matching(), onAdded, context, &addedIterator)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, Self.matching(), onRemoved, context, &removedIterator)

        // Draining the iterators reports devices already attached and arms the notifications.
        devicesAdded(addedIterator)
        devicesRemoved(removedIterator)
        devices = (devices + Self.simulatedDevices).sorted(by: Self.ordering)
    }

    /// Re-reads every attached device from scratch.
    func refresh() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, Self.matching(), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var fresh: [USBDevice] = []
        forEachService(in: iterator) { service in
            if let device = Self.describe(service) { fresh.append(device) }
        }
        devices = (fresh + Self.simulatedDevices).sorted(by: Self.ordering)
        onChange?()
    }

    /// Debug builds can pretend a PICkit 3 is attached (RFGEN44_SIMULATE_PICKIT=1) to exercise the UI without hardware.
    private static var simulatedDevices: [USBDevice] {
        #if DEBUG
        if ProcessInfo.processInfo.environment["RFGEN44_SIMULATE_PICKIT"] == "1" {
            return [USBDevice(id: 1, vendorID: 0x04D8, productID: 0x900A, productName: "PICkit 3", serialNumber: "SIM000000001", locationID: nil, isSimulated: true)]
        }
        #endif
        return []
    }

    private static func matching() -> CFMutableDictionary {
        // USB family matching rejects idVendor on its own (it wants vendor+product and similar
        // combinations), so match the property generically instead.
        let dictionary = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        dictionary[kIOPropertyMatchKey] = ["idVendor": Int(ProgrammerKind.microchipVendorID)]
        return dictionary
    }

    private func devicesAdded(_ iterator: io_iterator_t) {
        var updated = devices
        forEachService(in: iterator) { service in
            if let device = Self.describe(service), !updated.contains(where: { $0.id == device.id }) {
                updated.append(device)
            }
        }
        devices = updated.sorted(by: Self.ordering)
        onChange?()
    }

    private func devicesRemoved(_ iterator: io_iterator_t) {
        var removed = Set<UInt64>()
        forEachService(in: iterator) { service in
            var entryID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS { removed.insert(entryID) }
        }
        if !removed.isEmpty {
            devices.removeAll { removed.contains($0.id) }
            onChange?()
        }
    }

    private func forEachService(in iterator: io_iterator_t, _ body: (io_service_t) -> Void) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            body(service)
            IOObjectRelease(service)
        }
    }

    private static func describe(_ service: io_service_t) -> USBDevice? {
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS,
              let vendor: Int = property(service, "idVendor"),
              vendor == Int(ProgrammerKind.microchipVendorID),
              let product: Int = property(service, "idProduct")
        else { return nil }
        let location: Int? = property(service, "locationID")
        return USBDevice(
            id: entryID,
            vendorID: UInt16(truncatingIfNeeded: vendor),
            productID: UInt16(truncatingIfNeeded: product),
            productName: property(service, "USB Product Name") ?? property(service, "kUSBProductString"),
            // PICkit 3 pads its serial string with NULs.
            serialNumber: (property(service, "USB Serial Number") ?? property(service, "kUSBSerialNumberString") as String?)?
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)),
            locationID: location.map { UInt32(truncatingIfNeeded: $0) }
        )
    }

    private static func property<T>(_ service: io_service_t, _ key: String) -> T? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? T
    }

    private static func ordering(_ a: USBDevice, _ b: USBDevice) -> Bool {
        (a.programmer == nil ? 1 : 0, a.displayName, a.id) < (b.programmer == nil ? 1 : 0, b.displayName, b.id)
    }
}
