# RFGEN44 Firmware Updater

A macOS app that programs the RFGEN44's PIC16F1459 using a Microchip **PICkit 3**:

1. **Firmware.** Browse to a `.hex` file, drop one on the window, or use Finder's Open With. The app checks every record and shows how much program memory it uses, the configuration words, whether code protection is on, and a SHA-256 of the file.
2. **Programmer.** Detects the PICkit 3 over USB as soon as it is plugged in. PICkit 4/5, MPLAB Snap and ICD 3/4/5 are detected too.
3. **Target.** Choose the device (PIC16F1459 by default), and optionally power the board from the PICkit.
4. **Upload.** Program & Verify erases the chip, writes the firmware, and runs Microchip's verify. It then reads the whole chip back and compares all 8,192 program words plus the user ID and configuration words against the file. **Verify** does the check without programming. **More** has *Test Connection* and *Save Device Memory to File…*, which backs up what is currently on the board.

## Automatic fixes

The app fixes the problems it can safely fix by itself, then carries on. It reports each fix in the log and in the result. You can turn this off in Settings.

- **PICkit 3 left in scripting firmware.** A PICkit 3 last used with Microchip's standalone "PICkit 3 Programmer App" runs firmware MPLAB can't use, and ipecmd only says *Connection Failed*. When a PICkit 3 is plugged in, the app asks which firmware it runs, using the read-only query MPLAB itself sends. If it's the scripting firmware, the app switches it to MPLAB mode, as that app's *Revert to MPLAB mode* does. On the next connection MPLAB loads its firmware onto the PICkit (once, about a minute). A *Connection Failed* during an operation triggers the same check, and the operation is retried.
- **F/LF version of the chip.** If the chip reports the device ID of the other voltage version of the selected part, the app switches to that part and retries. Example: a PIC16LF1459 (0x3027) when PIC16F1459 is selected. They take the same firmware. A completely different chip still stops with a "Use …" button rather than being programmed.

No firmware files are included here. Open your RFGEN44 `.hex` from wherever you keep it.

## Requirements

- macOS 14 or later.
- **MPLAB X IDE v6.20**, free from Microchip; IPE is included. The app runs Microchip's `ipecmd` command-line tool to talk to the PICkit 3.
  - Microchip removed PICkit 3 support in **v6.25 and later**, so you need v6.20 from the archive on the [MPLAB X page](https://www.microchip.com/en-us/tools-resources/develop/mplab-x-ide). It can be installed alongside newer versions. The app finds every version under `/Applications/microchip/mplabx/` and picks the newest one that still supports your programmer.
  - Some MPLAB X releases bundle an Intel-only Java; v6.15 did, while v6.35 ships a native Apple silicon one. If ipecmd won't start on an Apple silicon Mac, install Rosetta 2 with `softwareupdate --install-rosetta`.
  - MPLAB X needs the **PIC16F1xxxx_DFP** device pack. If ipecmd says *Could not find device*, install the pack from *Tools ▸ Packs* in MPLAB X IPE.
- The PICkit 3 needs MPLAB firmware. The app switches it out of the Programmer App's scripting firmware by itself; see above.

## Build

```sh
scripts/build-app.sh                  # → dist/RFGEN44 Firmware Updater.app (universal, ad-hoc signed)
scripts/build-app.sh --install        # …and copy it to /Applications
```

## Release

The app is signed and notarized with RFGEN44-App's Developer ID certificate and notary setup; see [docs/SIGNING.md](docs/SIGNING.md).

```sh
REQUIRE_NOTARIZATION=1 VERSION=1.0.0 scripts/package-signed.sh
# → dist/RFGEN44-FirmwareUpdater-1.0.0.dmg (+ .sha256): Developer ID-signed, notarized and stapled
```

## Wiring

PICkit 3 header pin 1 (▶) → 1 MCLR/VPP, 2 VDD, 3 GND, 4 ICSPDAT, 5 ICSPCLK, 6 not connected. This firmware disables low-voltage programming, so pin 6 is unused. The app shows the full diagram under *Help ▸ PICkit 3 Wiring Guide*.

Power the board from its usual supply, **or** turn on *Power the target from the programmer*. Never do both. The PICkit 3 can only supply about 30 mA.

## Troubleshooting

When `ipecmd` fails, the app shows Microchip's message with a hint underneath. The full `ipecmd` output is in the log pane, which you can copy or save.

| Message | Usually means |
|---|---|
| *Target device was not found (could not detect target voltage VDD)* | The board isn't powered, or the ICSP cable is off or reversed. |
| *Target Device ID (0x0) is an Invalid Device ID* | A wiring problem on MCLR/PGD/PGC/GND, or the board isn't powered. A non-zero ID means a different chip is fitted; the app names it. |
| *Connection Failed* | Usually the PICkit 3 is running the Programmer App's scripting firmware, which the app fixes automatically. If that isn't the cause, plug the PICkit straight into the Mac, not through a hub. |
| PICkit 3 status LED blinking red, PICkit not detected | It was plugged in with its button held. Unplug it and plug it back in without holding the button. |
| *no longer supports the PICkit 3* | Only MPLAB X v6.25+ is installed. Install v6.20. |
| *Could not find device:PIC16F1459* | The device pack is missing. Install PIC16F1xxxx_DFP from *Tools ▸ Packs*. |

## Development

```sh
swift test   # Intel HEX parser, memory map, read-back compare, ipecmd arguments/output, process runner
swift run    # debug build of the app
```

`FirmwareCore` holds the logic that doesn't depend on hardware. `RFGEN44Updater` holds the SwiftUI app and IOKit USB detection.

To try the whole flow without hardware, use a debug build:
- Set `RFGEN44_SIMULATE_PICKIT=1` to add a fake PICkit 3.
- In Settings, choose `Tests/FirmwareCoreTests/Fixtures/fake-ipecmd.sh` as the ipecmd.
- The fake writes its pretend chip to `$FAKE_IPECMD_DEVICE`.
- Set `FAKE_IPECMD_FAIL=target|connection|verify` to simulate failures.
