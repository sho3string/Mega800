Alpha V3 - November 25, 2026
============================

Atari 800/XL/XE core for MEGA65 R3 and R6. Both builds use the same
HyperRAM-based memory design.

**Delete your old `a8cfg` in `/Atari800/` before using this version: the menu
layout has changed.**

Improvements
------------

* Atari extended memory moved from FPGA block RAM to HyperRAM. This makes
  the larger memory configurations possible:
  52K / 576K Compy, 4MB Axlon (400/800) / 576K Rambo, 1088K Rambo and
  4MB Axlon (XL/XE). The RAM options moved to their own submenu.

* A 128 KB block RAM cache sits in front of HyperRAM (16-byte lines,
  write-through, critical word first, next-line prefetch), so most
  extended-memory accesses run at full speed.

* The Atari address decoder lets ANTIC's video fetches go ahead of a CPU
  access that is waiting on HyperRAM. This keeps the display glitch-free
  while software uses extended memory.

* Cartridge support ("Load Cart"):
  - `.car` images, 78 cartridge types, including the OSS super cartridges
    (types 3 and 45, for example Action!)
  - raw `.rom` / `.bin` dumps; the cartridge type is chosen from the file
    size (Standard up to 16K, Bounty Bob 40K, XEGS 32K to 1 MB)
  - cartridges up to 1 MB, stored in HyperRAM
  - the activity LED blinks while a cartridge loads

* Loading an XEX removes any inserted cartridge.

* Separate file filters: Drive A shows only `.atr`, Cassette only `.cas`,
  Load XEX only `.xex`, Load Cart `.car`, `.rom` and `.bin`.

* Disk (D1) and cassette mount buffers moved from block RAM to HyperRAM, so
  cassette playback and disk access no longer share a buffer.

Bug fixes
---------

* A failed cartridge or XEX load left the OSD hidden, so the error message and
  the "press Space" prompt were invisible and the menu appeared frozen. The
  OSD is now shown again together with the error, and the correct error code
  is displayed.

* After a load error the loaders restarted in the middle of the failed file
  and reported a misleading "Unexpected EOF". They now wait for the failed
  file to finish before accepting a new load.

* Reloading a cartridge of the same type started it in the bank (or with the
  cartridge disabled) that the previous cartridge had left selected.

* Updated QNICE to 5ccb507 (MiSTer2MEGA65 issue #84): the file browser no
  longer stops with "Error code: 2704" on folders whose directory exactly
  fills its clusters, a broken long file name no longer crashes the browser,
  and seeking to the end of a file whose size is a multiple of the cluster
  size no longer returns an error.

Known limitations
-----------------

* No PBI and no paddle support.
* Cartridges larger than 1 MB (MegaCart 2/4 MB, MegaMax) are not supported.
* Raw OSS dumps must be converted to `.car`. Corina cartridges are not
  supported. There is no cartridge eject option.
* 4MB Axlon banks through `$CFFF`; PORTB-only software sees no extended RAM
  in that mode (as on real hardware).
* XEX loading targets XL/XE mode only.


Alpha V2 - October 18, 2026
===========================

Improvements
------------

* CAS cassette image support: the CAS reader parses the image and feeds timed
  tape data to the emulated cassette interface through a second virtual
  drive, with a Cassette mount entry in the OSD.

* Playback follows the Atari's cassette motor signal: the tape pauses while
  the motor is off and keeps its position.

* The activity LED stays on during cassette playback.

* Cold boot is possible without a valid ATR image mounted previously.

Bug fixes
---------

* Fixed the cassette transport advancing while the motor was stopped
  (observed with Gauntlet).

* Fixed Atari CAS cassette playback timing.

Known limitations
-----------------

* No cartridge, PBI, paddle or 4MB Axlon support.


Alpha V1
========

First public Alpha of the Atari 800/XL/XE core for MEGA65, based on the
MiSTer Atari800 core and the MiSTer2MEGA65 framework.

* Atari XL/XE and 400/800 machine modes
* PAL and NTSC
* ATR disk images (drive D1:), including disk access after boot
* XEX loading in XL/XE mode, including XEX files whose INIT routines wait for
  input during loading
* Configurable Atari RAM up to 48K / 320K Rambo
* VBXE at `$D640` or `$D740`, NTSC fix, runtime palette loading
* MEGA65 joystick support and Atari / MEGA65 keyboard mappings
* Cold and warm reset, OPTION-assisted cold boot
* Clip sides, HDMI and 15/31 kHz analog video options, RTC
