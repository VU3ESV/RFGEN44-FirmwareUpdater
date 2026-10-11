# Changelog

## 1.0.1

- With no programmer plugged in, the app now chooses an MPLAB X that supports the PICkit 3 (v6.20), instead of the newest one, which showed a needless "no PICkit 3 support" warning.

## 1.0.0

First signed and notarized release.

- Programs the RFGEN44's PIC16F1459 or PIC16LF1459 with a PICkit 3, using Microchip's MPLAB IPE (`ipecmd`). PICkit 4/5, MPLAB Snap and ICD 3/4/5 work too.
- Checks the firmware `.hex` file record by record, and shows how much program memory it uses, its configuration words, and whether code protection is on.
- Program & Verify: erases, programs, runs Microchip's verify, then reads the whole chip back and compares every word against the file.
- Detects programmers when they are plugged in. Picks the newest MPLAB X that still supports the programmer: v6.20 for the PICkit 3.
- Fixes problems by itself:
  - switches a PICkit 3 out of the PICkit 3 Programmer App's scripting firmware into MPLAB mode;
  - follows the chip when it is the F or LF version of the selected part;
  - retries the operation after either fix.
- Backs up the chip's current firmware to a file. Includes a wiring guide.
