#!/bin/bash
# Stand-in for MPLAB IPE's ipecmd, for tests and UI demos without hardware.
# The "device" is a hex file at $FAKE_IPECMD_DEVICE (programming copies into it, reading copies out).
# FAKE_IPECMD_FAIL=target simulates an unpowered/disconnected target; =verify simulates a verify failure.
DEVICE="${FAKE_IPECMD_DEVICE:-${TMPDIR:-/tmp}/fake-ipecmd-device.hex}"
part="" hex="" out="" ops=()
for arg in "$@"; do
    case "$arg" in
        -TP*|-TS*|-W*|-OL) ;;
        -P*) part="${arg#-P}" ;;
        -F*) hex="${arg#-F}" ;;
        -GF*) out="${arg#-GF}"; ops+=(read) ;;
        -M*) ops+=(program) ;;
        -Y*) ops+=(verify) ;;
        -I) ops+=(id) ;;
        -E) ops+=(erase) ;;
    esac
done
pause() { sleep "${FAKE_IPECMD_DELAY:-0.4}"; }

echo "*****************************************************"
echo ""
echo "DFP Version Used : PIC16F1xxxx_DFP,1.25.389,Microchip"
echo ""
echo "Connecting to MPLAB PICkit 3..."
pause
echo "Currently loaded firmware on PICkit 3"
echo "Firmware Suite Version.....01.56.09"
echo "Firmware type..............Enhanced Midrange"
echo ""
for arg in "$@"; do
    [[ "$arg" == -W* ]] && printf 'Programmer to target power is enabled - VDD = %f volts.\n' "${arg#-W}"
done
if [[ "${FAKE_IPECMD_FAIL:-}" == "connection" ]]; then
    echo "Connection Failed."
    exit 0  # ipecmd has been seen to exit 0 here
fi
if [[ "${FAKE_IPECMD_FAIL:-}" == "target" ]]; then
    echo "Target device was not found (could not detect target voltage VDD). You must connect to a target device to use PICkit 3."
    echo "Operation Failed"
    exit 7
fi
echo "Target device PIC${part} found."
echo "Device Revision ID = 1006"
echo ""
for op in "${ops[@]}"; do
    case "$op" in
        erase)
            echo "Erasing..."; pause; echo "Erase successful" ;;
        program)
            echo "Erasing..."; pause
            echo "Device Erased..."
            echo ""
            echo "Programming..."; pause; pause
            echo "The following memory area(s) will be programmed:"
            echo "program memory: start address = 0x0, end address = 0x1f7f"
            echo "configuration memory"
            cp "$hex" "$DEVICE"
            echo "Programming/Verify complete"
            echo "PICKIT3 Program Report"
            date "+%Y-%m-%d, %H:%M:%S"
            echo "Device Type:PIC${part}"
            echo "Program Succeeded." ;;
        verify)
            pause
            echo "PK3 Verify Report"
            date "+%Y-%m-%d, %H:%M:%S"
            echo "Device Type:PIC${part}"
            if [[ "${FAKE_IPECMD_FAIL:-}" == "verify" ]] || ! cmp -s "$hex" "$DEVICE"; then
                echo "Verify failed at program memory address 0x10: expected 0x3180, read 0x3FFF"
                echo "Operation Failed"
                exit 5
            fi
            echo "Verification successful."
            echo "Verify Succeeded." ;;
        read)
            echo "Reading..."; pause
            cp "$DEVICE" "$out"
            echo "Read complete" ;;
        id)
            echo "Device ID = 0x3023" ;;
    esac
done
echo "Operation Succeeded"
exit 0
