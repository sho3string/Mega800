# Atari 800/XL/XE Core for MEGA65 — Alpha V3 Release

This is an **Alpha release** of the Atari 8-bit computer core for the MEGA65.  
The core is based on the MiSTer Atari800 implementation and has been adapted to run within the MiSTer2MEGA65 framework.  
This release is intended for testing. Although a substantial amount of software is already working, compatibility is not yet expected to be complete.  

Alpha V3 is available for both **MEGA65 R3** and **MEGA65 R6** boards. Both builds use the same HyperRAM-based memory design.


## Overview

This project adapts the MiST/MiSTer Atari 800 core for the MEGA65 architecture using the M2M hardware abstraction layer.  

## Credits:  

MiSTer2MEGA65 Framework - sy2002 & MJoergen  
 * https://github.com/sy2002/MiSTer2MEGA65/

MiSTer Atari 800 Core - woj76,sorgelig,claude & carlosbravoa
 * https://github.com/MiSTer-devel/Atari800_MiSTer  


## What's New in Alpha V3

- **Extended memory moved to HyperRAM**, enabling much larger memory configurations:
  - 576K Compy, 576K Rambo and 1088K Rambo
  - **4MB Axlon**
- **Cartridge support**
  - `.car` images (78 cartridge types, including OSS super cartridges such as Action!)
  - raw `.rom` / `.bin` dumps, with the cartridge type chosen from the file size
  - cartridges up to **1 MB** (for example 1 MB menu/multi-game cartridges)
  - the drive LED blinks while a cartridge loads
- **Separate file filters**: Drive A shows only `.atr` files, Cassette shows only `.cas` files, Load XEX shows only `.xex` files and Load Cart shows `.car`, `.rom` and `.bin` files.
- **Load errors are shown properly.** Previously a failed load could leave the menu looking frozen.
- **Loading an XEX unplugs any cartridge**, so the XEX starts on a clean machine.
- **File browser fix** from MiSTer2MEGA65 issue #84: folders whose directory exactly fills its clusters on the SD card no longer stop browsing with "Error code: 2704".

**Important: delete your old `a8cfg` file** in `/Atari800/` before using Alpha V3 (or replace it with the one supplied with this release). The menu layout has changed, so an old configuration file no longer matches.


## Current Features

Alpha V3 currently supports:

- Atari **XL/XE** machine mode
- Atari **400/800** machine mode
- PAL and NTSC
- ATR disk images
- CAS cassette images
- XEX executable loading
- **Cartridge images (`.car`, `.rom`, `.bin`) up to 1 MB**
- MEGA65 joystick support
- Atari / MEGA65 keyboard mapping modes
- Configurable Atari RAM, from 8K up to **1088K Rambo** and **4MB Axlon**
- Clip sides
- 15Khz or 31Khz analog video out support
- RTC support
- VBXE options
- Cold and warm reset controls
- OPTION-assisted cold boot for software requiring BASIC to be disabled
- Drive/cassette/cartridge activity LED indication

**PBI is not supported in this version.**  

---

# The OSD Menu

The OSD provides access to disk, cassette, executable and cartridge loading, video output, Atari machine configuration, memory expansion, VBXE, keyboard mapping and other core settings.

## Main Menu

- **Drive A**  
  Mounts an `.atr` disk image as Atari drive **D1:**. Only `.atr` files are shown.

- **Cassette**  
  Mounts a `.cas` cassette image for playback through the emulated Atari cassette interface. Only `.cas` files are shown.

- **Load XEX**  
  Loads an Atari `.xex` executable directly into the emulated Atari.  
  XEX loading is currently supported in **XL/XE mode only**.  
  Loading an XEX unplugs any cartridge that is currently loaded.

- **Load Cart**  
  Loads a cartridge image (`.car`, `.rom` or `.bin`) and restarts the Atari with the cartridge inserted. See **Cartridges** below.

- **HDMI**  
  Opens the HDMI video-output submenu.

- **System Settings**  
  Opens the Atari machine and hardware configuration submenu.

- **RAM**  
  Opens the Atari memory configuration submenu.

- **VGA**  
  Opens the analogue/VGA video-output submenu.

- **Keyboard: Atari / MEGA65**  
  Selects the keyboard mapping.  
  **Atari** uses Atari-oriented key mappings, while **MEGA65** provides mappings more appropriate to the MEGA65 keyboard.

- **PAL**  
  Selects the Atari video standard between **PAL and NTSC**.

- **Clip sides**  
  Clips the left and right edges of the Atari display, hiding the normally unused/overscan areas at the sides of the screen.

- **Close Menu**  
  Closes the OSD and returns control to the Atari.

---

## HDMI Settings

The HDMI submenu selects the digital video output mode.

Available resolutions are:

- **720p 50 Hz 16:9**
- **720p 60 Hz 16:9**
- **576p 50 Hz 4:3**
- **576p 50 Hz 5:4**
- **640×480 60 Hz**
- **720×480 59.94 Hz**
- **800×600 60 Hz**

Additional HDMI options include:

- **HDMI: CRT emulation**  
  Enables the MiSTer2MEGA65 CRT-style video processing options.

- **HDMI: Zoom-in**  
  Controls HDMI image zoom/cropping.

- **Audio improvements**  
  Provides the MiSTer2MEGA65 HDMI/audio enhancement options.

---

## Atari System Settings

### Machine

- **Machine: XL/XE**  
  Selects Atari XL/XE operation. This is the default mode and is required for the current XEX loader.

- **Machine: 400/800**  
  Selects compatibility with the original Atari 400/800 architecture.

### VBXE

- **VBXE: Disabled**  
  Disables VBXE.

- **VBXE: $D640**  
  Enables VBXE with its registers mapped at `$D640`.

- **VBXE: $D740**  
  Enables VBXE with its registers mapped at `$D740`.

- **Fix VBXE NTSC bug**  
  Enables the NTSC compatibility workaround provided by the VBXE implementation.

- **Load VBXE Palette**  
  Loads a 768-byte `.act` colour palette for VBXE.

  `pal.act` and `ntsc.act` provide PAL and NTSC VBXE palettes respectively. These palette files are only relevant when **VBXE is enabled**.

### Atari 400/800 OS

- **400/800 OS: 10K**  
  Selects the standard 10 KB Atari 400/800 OS layout.

- **400/800 OS: 16K**  
  Selects the alternative 16 KB OS configuration supported by the core.

### ROM Loading

- **Load OS 16K**  
  Manually loads the 16 KB Atari XL/XE operating-system ROM.

- **Load OS 10K**  
  Manually loads the 10 KB Atari 400/800 operating-system ROM.

- **Load BASIC**  
  Manually loads the 8 KB Atari BASIC ROM.

The normal boot ROM files are `boot0.rom`, `boot1.rom` and `boot2.rom`; these menu entries allow the corresponding ROM images to be replaced manually while the core is running.

---

## RAM Settings

The RAM submenu selects both the memory available in 400/800 mode and the corresponding XL/XE memory configuration:

| Menu entry               | 400/800 mode | XL/XE mode  |
| ------------------------ | ------------ | ----------- |
| **8K / 64K**             | 8K           | 64K         |
| **16K / 128K**           | 16K          | 128K (130XE)|
| **32K / 320K Compy**     | 32K          | 320K Compy  |
| **48K / 320K Rambo**     | 48K          | 320K Rambo  |
| **52K / 576K Compy**     | 52K          | 576K Compy  |
| **4M Axl / 576K Rambo**  | 4MB Axlon    | 576K Rambo  |
| **- / 1088K Rambo**      | —            | 1088K Rambo |
| **- / 4MB Axlon**        | —            | 4MB Axlon   |

The first value applies to **400/800 mode** and the second to **XL/XE mode**.

The default configuration is:

**48K / 320K Rambo**

See **RAM Configuration** below for compatibility advice.

---

## VGA Settings

The VGA submenu controls analogue video output.

- **Standard**  
  Uses the normal VGA output mode.

- **Retro 15 kHz mode**  
  Enables 15 kHz output for compatible retro displays and equipment.

- **15 kHz with HS/VS**  
  Outputs 15 kHz video using separate horizontal and vertical sync signals.

- **15 kHz with CSYNC**  
  Outputs 15 kHz video using composite sync.

Use the 15 kHz modes only with displays or video equipment capable of accepting the selected signal.

Please treat this as a test build and report software that behaves differently from the MiSTer Atari800 core.

---

# RAM Configuration

The default RAM configuration is **320 KB Rambo**.

This configuration is used by default because it provides expanded memory for XL/XE software while also supporting the **48 KB memory configuration required for Atari 400/800 mode**.

Some Atari software is not compatible with expanded memory configurations and may only work correctly when configured for a standard **64 KB Atari XL/XE**.  

For example:

A version of `BountyBob.xex` that I tested requires the **64 KB** configuration and does not work correctly with more than 64Kb of ram.  

If a game or XEX fails to load, crashes, hangs, or behaves unexpectedly in XL/XE mode, try changing the RAM configuration to:

**8K / 64K**

before assuming the software is incompatible with the core.

Software that needs more than 320K (for example demos or utilities written for 576K or 1088K expansions) should use one of the larger configurations.

## 4MB Axlon

Axlon memory is banked through the register at `$CFFF`, not through PORTB like Rambo, Compy and 130XE expansions.

Software written for PORTB-based expansions will therefore see **no extended RAM** in 4MB Axlon mode. This is the same behaviour as real hardware. Use a Rambo or Compy configuration for such software, and the Axlon configuration only for software that supports Axlon.

## How extended memory works on the MEGA65

The MiSTer core keeps extended RAM in SDRAM. The MEGA65 has only a limited amount of fast on-chip block RAM, plus 8 MB of HyperRAM, which is much slower than SDRAM.

From Alpha V3, everything above the base 64K is stored in HyperRAM:

- The base **64K** stays in fast on-chip RAM.
- A **128 KB cache** in on-chip RAM sits in front of HyperRAM. Most extended-memory accesses are served from the cache at full speed.
- The core's address decoder was modified so that ANTIC's video fetches can go ahead of a CPU access that is waiting on HyperRAM. This keeps the display glitch-free while software uses extended memory.

The same HyperRAM also holds the HDMI frame buffer, cartridge images and the disk and cassette buffers.

---

# System / Boot ROMs

The Atari system ROMs are **not compiled into the core**.

They must be supplied as external ROM files in the MEGA65 Atari core directory:

`/Atari800/`

The core uses the following boot ROM filenames.

| File            | Purpose                            |           Required size |
| --------------- | ---------------------------------- | ----------------------: |
| `boot0.rom`     | Atari XL/XE Operating System ROM   | **16 KB / 16384 bytes** |
| `boot1.rom`     | Atari BASIC ROM                    |   **8 KB / 8192 bytes** |
| `boot2.rom`     | Atari 400/800 Operating System ROM | **10 KB / 10240 bytes** |
| `boot3.rom`     | PBI BIOS                           |   **8 KB / 8192 bytes** |
| `ntsc.act`      | VBXE NTSC colour palette           |           **768 bytes** |
| `pal.act`       | VBXE PAL colour palette            |           **768 bytes** |
| `a8diag1-6.rom` | Atari diagnostic ROM               | **16 KB / 16384 bytes** |

This version of the core requires boot0.rom,boot1.rom,boot2.rom and pal.act to work. 

## `a8diag1-6.rom` — Atari Diagnostic ROM

**Size: 16384 bytes (16 KB)**

`a8diag1-6.rom` is a diagnostic ROM I developed specifically for testing Atari computers and is **included with this release**.

It can be loaded in place of the normal 16 KB XL/XE operating-system ROM using:

**System Settings → Load OS 16K**

The diagnostic ROM is useful for checking the operation of the emulated Atari hardware and for troubleshooting problems independently of normal Atari software.

Unlike the original Atari OS and BASIC ROM images, this diagnostic ROM is distributed.

The filenames are significant. The core expects the ROM images using the `boot0.rom`, `boot1.rom`, etc. naming convention.

## `boot0.rom` — XL/XE Operating System

**Size: 16384 bytes (16 KB)**

This contains the Atari XL/XE operating system.

It provides the normal Atari operating environment, including system initialisation, device handling, SIO, keyboard handling and disk boot support.

This ROM is used when the core is operating in **XL/XE mode**.

## `boot1.rom` — Atari BASIC

**Size: 8192 bytes (8 KB)**

This contains Atari BASIC for XL/XE mode.

On an XL/XE machine, BASIC occupies the `$A000-$BFFF` area when enabled.

Some Atari software, particularly commercial disk games, expects this memory to be RAM rather than BASIC ROM. Such software must therefore be cold-booted with **OPTION held**.

On this core:

**F11** = normal cold boot

**F1 + F11** = cold boot with OPTION held

The second combination disables BASIC during the boot in the same way as holding OPTION while switching on/resetting a real XL/XE.

BASIC programs should normally be booted without OPTION so that BASIC remains available.

## `boot2.rom` — Atari 400/800 Operating System

**Size: 10240 bytes (10 KB)**

This contains the original Atari 400/800 operating system and is used when the core is switched into **400/800 mode**.

The original Atari 400/800 does not have BASIC built into the computer in the same way as the XL/XE machines. BASIC was supplied separately as a cartridge.

Without BASIC present, the 400/800 provides its Memo Pad environment.

This difference is important when booting disk software.

A disk that requires BASIC to be disabled on an XL/XE may boot simply by pressing **F11** in 400/800 mode because there is no built-in BASIC ROM that needs to be disabled.

## `boot3.rom` — PBI BIOS

**Size: 8192 bytes (8 KB)**

This contains the BIOS used by the core's PBI functionality.

It is separate from the normal XL/XE and 400/800 operating-system ROMs. PBI is not yet supported in this release.

## `ntsc.act` — VBXE NTSC Colour Palette

**Size: 768 bytes**

This contains the 256-colour RGB palette used by **VBXE when the core is operating in NTSC mode**.

Each of the 256 colour entries contains three bytes representing the red, green and blue components, giving a total size of 768 bytes.

This file is only relevant when **VBXE mode is enabled** and is not required for normal Atari video output.

## `pal.act` — VBXE PAL Colour Palette

**Size: 768 bytes**

This contains the 256-colour RGB palette used by **VBXE when the core is operating in PAL mode**.

Each of the 256 colour entries contains three bytes representing the red, green and blue components, giving a total size of 768 bytes.

This file is only relevant when **VBXE mode is enabled** and is not required for normal Atari video output.

---

# Machine Modes

## Atari XL/XE

This is the normal/default mode for most software and is the mode required for the current XEX loader.

Use XL/XE mode for:

- XEX executables
- XL/XE software
- most later Atari 8-bit software
- ATR images intended for XL/XE systems

The XL/XE environment includes Atari BASIC through `boot1.rom`.

Consequently, some disk software must be booted with OPTION held to disable basic.

## Atari 400/800

400/800 mode provides the earlier Atari machine environment using `boot2.rom`.

It is useful for software specifically intended for the original Atari 400/800 and for compatibility testing.

**XEX loading is not supported in 400/800 mode in this Alpha.**

ATR disk images can be used in this mode.

Because the 400/800 does not have built-in BASIC, software that requires BASIC to be disabled on an XL/XE may boot without needing OPTION in this mode.

---

# ATR Disk Images

ATR disk-image support is available in this Alpha.

Mount the required `.atr` image using the core's file browser and boot the Atari.

The virtual-drive implementation supports normal disk booting as well as subsequent disk accesses made by software after it has started.

This has been tested with software that performs additional in-game disk loading.

## Normal ATR boot

For a normal XL/XE disk boot:

**F11** — Cold boot

This resets the Atari and boots the mounted D1: disk.

## Booting with BASIC disabled

Some XL/XE disk software requires BASIC to be disabled.

Use:

**F1 + F11** — Cold boot with OPTION held

F1 corresponds to the Atari **OPTION** key.

Hold F1 while performing the F11 cold boot. It can be useful to keep F1 held briefly during the beginning of the boot sequence rather than releasing it immediately.

## Why some disks behave differently in 400/800 mode

A disk may:

- require **F1 + F11** in XL/XE mode
- but boot with **F11 alone** in 400/800 mode

This is expected for software that requires BASIC to be absent.

The XL/XE has built-in BASIC which must be disabled with OPTION. The 400/800 does not have built-in BASIC, so there is nothing equivalent that needs to be disabled.

---

# CAS Cassette Images

Atari cassette images are supported using `.cas` files.

The CAS reader parses the cassette image and supplies timed tape data to the emulated cassette interface. Playback is controlled by the Atari's cassette motor signal rather than simply advancing continuously after a file is mounted.

## Loading a cassette

1. Mount a `.cas` image using **Cassette** in the OSD. Only `.cas` files are shown.
2. Select the appropriate Atari machine mode and RAM configuration for the software.
3. Start the software's normal cassette-loading procedure. Some programs require a cold boot with START or OPTION held, depending on the title and Atari model.
4. Allow the cassette to load; the activity LED provides an indication of tape activity.

## Cassette transport behaviour

The virtual cassette transport pauses while the selected cassette motor is off. Tape playback resumes when the motor is enabled, preserving the position rather than consuming tape data while stopped. This addresses a transport issue observed during Gauntlet testing.

Cassette loading has been tested with Gauntlet, including playing through several levels. This is not a guarantee of compatibility with every CAS image, especially non-standard or turbo loaders.

In Alpha V3 the cassette and disk buffers live in HyperRAM, so cassette playback and disk access no longer compete for the same buffer.

---

# Cartridges (New in Alpha V3)

Cartridge images are loaded with **Load Cart** in the main menu. The core copies the image into HyperRAM, inserts the cartridge and cold-boots the Atari. The activity LED blinks while a cartridge is loading; large cartridges can take a few seconds.

## Supported formats

- **`.car`** — cartridge images with a 16-byte header that identifies the cartridge type. This is the recommended format. 78 cartridge types are supported, including standard 8K/16K, XEGS, Williams, Express, Diamond, SpartaDOS X, Atarimax, MegaCart and similar bank-switched types up to 1 MB, and the **OSS** super cartridges (types 3 and 45, for example Action!, BASIC XL and MAC/65).
- **`.rom` / `.bin`** — raw cartridge dumps without a header. The cartridge type is chosen from the file size:

| Raw file size                        | Cartridge type used |
| ------------------------------------ | ------------------- |
| 2K, 4K, 8K, 16K                      | Standard            |
| 40K                                  | Bounty Bob          |
| 32K, 64K, 128K, 256K, 512K, 1 MB     | XEGS                |

A file whose contents begin with a `.car` header is always loaded as a `.car`, whatever its extension.

## Notes on raw dumps

A raw dump does not record its cartridge type, so the size-based choice above is a best guess. A dump that needs a different type for its size (for example an 8K right-slot cartridge, or a 64K Williams or SpartaDOS X cartridge) will not start correctly and should be converted to `.car`.

**Raw OSS dumps must be converted to `.car`.** OSS cartridge dumps store their 4K blocks in different orders, and a raw dump does not say which OSS type it is. Loaded as a raw 16K file, an OSS cartridge will typically drop to the Self Test screen.

## Loading a cartridge

1. Select **Load Cart** and choose the image.
2. The Atari restarts with the cartridge inserted. Loading another cartridge replaces the current one.
3. Loading an XEX removes the cartridge.

If a cartridge cannot be loaded, the OSD shows an error such as **Not a .CAR file**, **Unsupported type**, **Cart too large** or **Unknown ROM size**, and you can press Space to return to the menu.

---

# XEX Executable Files

XEX executable loading is supported in **Atari XL/XE mode**.

It is not currently supported in Atari 400/800 mode.

An Atari XEX can loosely be thought of as the Atari equivalent of a C64 PRG: executable data is loaded directly into the machine rather than being accessed as a disk filesystem.

However, Atari XEX files have an important characteristic that makes loading more complicated than simply copying the entire file into memory and starting it.

Loading an XEX removes any cartridge that is currently inserted, so the XEX starts on a machine without a cartridge.

## INITAD execution during loading

An XEX can contain multiple segments.

Some XEX files set an Atari `INITAD` vector that must be executed **before the remainder of the XEX has finished loading**.

These INIT routines can perform tasks such as:

- initialisation
- memory setup
- decompression
- decrunching
- displaying an intro
- running a cracktro
- waiting for keyboard input
- waiting for joystick or console-key input

After the INIT routine returns, loading continues with subsequent XEX segments.

This means the Atari can be actively executing software while the MEGA65/QNICE side is still synchronously processing the same XEX file.

## Interactive XEX loading workaround

This created a particular problem with the MiSTer2MEGA65 loading system.

`LOAD_IMAGE` operates synchronously and normally leaves the file-browser/progress OSD active until loading has completed.

That is normally fine for a ROM or conventional image load.

It is not sufficient for an XEX whose INIT routine starts an interactive intro before the remainder of the file can be loaded.

For example, **Head Over Heels** contains an intro which requires Atari START to advance.

Without special handling, the situation becomes:

`LOAD_IMAGE` is still active\
→ XEX INIT routine starts\
→ intro waits for START\
→ OSD still owns the input\
→ Atari cannot receive START\
→ INIT routine never returns\
→ QNICE cannot continue loading the XEX

This creates a deadlock.

The current Alpha contains a workaround for this situation.

For the CRT/ROM/XEX loading path, the loader can hide the browser/progress overlay while the synchronous load continues and reconnect physical keyboard/joystick input to the running Atari.

Both operations are necessary.

Simply hiding the OSD was tested and was **not sufficient**: Atari START still did not reach the running software.

With physical input reconnected as well, interactive INIT routines can receive input, return normally, and allow QNICE to continue streaming the remainder of the XEX.

If an XEX or cartridge load fails, the OSD is now shown again together with the error message. In Alpha V2 the error could remain hidden, making the menu appear frozen.

This currently involves modifications around the MiSTer2MEGA65 loader behaviour and may be revisited in a later release.

---


# Clip Sides

The core provides a **Clip Sides** option for controlling the visible width of the Atari display.

When enabled, the left and right edges of the Atari display are clipped, hiding the normally unused/overscan areas at the sides of the screen.

When disabled, the full horizontal output from the Atari core is displayed.

This is primarily a display preference which came directly from the MiSTer core and can be changed through the OSD.

---

# Keyboard and Controls

The core supports Atari keyboard input and provides a keyboard mapping option for selecting between Atari-oriented and MEGA65-oriented mappings.

Known console/reset mappings include:

| MEGA65 key   | Atari function             |
| ------------ | -------------------------- |
| **F1**       | OPTION                     |
| **F5**       | START                      |
| **F11**      | Cold boot/reset            |
| **F1 + F11** | Cold boot with OPTION held |
| **F7**       | WARM reset                 |
| **F9**       | HELP                       |

The keyboard mapping mode can be changed from the core menu.

Some software uses Atari console keys during startup, intros or gameplay, so these mappings are also relevant when testing XEX files.

---

# Joystick Support

The MEGA65 joystick ports are connected to the Atari joystick inputs.

Standard digital Atari joystick operation is supported, including:

- Up
- Down
- Left
- Right
- Fire

Joystick input is routed through the Atari PIA/GTIA-side input handling as appropriate.

Some Atari software also uses paddle/POT inputs or additional buttons. Support for software relying on unusual analogue or additional-button configurations is not supported yet.

---

# PAL / NTSC

Both **PAL and NTSC** operation are available.

Select the appropriate video standard for the software being tested.

Software written around PAL or NTSC timing can behave differently when run using the other standard, so please include the selected video mode when reporting compatibility problems.

---

# RTC

The MEGA65 RTC is connected to the Atari core through the MiSTer2MEGA65 RTC interface.

Software capable of using the corresponding Atari RTC functionality can therefore obtain date/time information from the MEGA65 RTC.

---

# VBXE

The core includes the VBXE functionality inherited from the Atari800 implementation, with configuration options exposed through the core.

**VBXE (Video Board XE)** is an enhanced graphics expansion originally designed for Atari XL/XE computers.

It extends the Atari's original ANTIC/GTIA graphics system with significantly more capable video hardware, while retaining compatibility with normal Atari graphics.

VBXE provides features including:

- An expanded **21-bit RGB colour palette**
- Up to **1024 simultaneous colours**
- Additional high-resolution graphics modes
- **80-column text** support
- Hardware-assisted graphics operations through a **blitter**
- Dedicated video memory
- Additional graphics capabilities used by software specifically written or enhanced for VBXE

Most normal Atari software does **not** require VBXE. It should only need to be enabled for software that specifically supports or requires the VBXE expansion.

The VBXE video memory is kept in the FPGA's fast on-chip RAM, because the VBXE overlay and blitter need faster access than HyperRAM can provide.

The core emulates VBXE and provides the following configuration options:

- **VBXE: Disabled**  
  Disables the VBXE expansion. Use this for normal Atari software that does not require VBXE.

- **VBXE: $D640**  
  Enables VBXE with its control registers mapped at `$D640`.

- **VBXE: $D740**  
  Enables VBXE with its control registers mapped at `$D740`.

  The two addresses correspond to alternative VBXE register locations. Use the address expected by the software being run.

- **Fix VBXE NTSC bug**  
  Enables the NTSC compatibility workaround provided by the VBXE implementation. This option is only relevant when using VBXE with NTSC operation.

- **Load VBXE Palette**  
  Loads a 768-byte Adobe Color Table (`.act`) file containing the RGB colour palette used by VBXE.

  The supplied palette files are:

  - `pal.act` — VBXE palette for PAL operation
  - `ntsc.act` — VBXE palette for NTSC operation

  Each `.act` file contains 256 RGB entries, with three bytes per entry, for a total size of **768 bytes**.

  These palette files are only relevant when **VBXE is enabled** and are not required for the Atari's normal ANTIC/GTIA video output.

---

# Reset Behaviour

Two types of Atari reset are relevant.

## Cold boot

**F11**

Performs a cold boot of the Atari.

Use this when booting a newly mounted ATR or when software needs a complete restart.

## Cold boot with OPTION

**F1 + F11**

Performs the cold boot while Atari OPTION is held.

In XL/XE mode this is particularly useful for disabling the built-in BASIC ROM when booting commercial disk software.

If a disk refuses to boot correctly in XL/XE mode, trying **F1 + F11** is worthwhile.

---

# Current Limitations

No PBI or paddle support.  

### Cartridges

- Cartridges larger than **1 MB** (for example MegaCart 2/4 MB and MegaMax 2 MB) are not supported yet.
- Raw OSS dumps (`.bin` / `.rom`) must be converted to `.car`.
- Corina cartridges are not supported.
- There is no cartridge eject option yet. Loading an XEX removes the cartridge.
- Raw dumps whose cartridge type is not the common type for their size need converting to `.car`.

### 4MB Axlon

4MB Axlon mode only provides extended memory to software that uses Axlon banking (`$CFFF`). PORTB-based software sees no extended RAM in this mode.

### XEX and 400/800 mode

XEX loading currently targets **XL/XE mode**.

Do not expect XEX loading to operate correctly in Atari 400/800 mode.

### XEX loader / OSD interaction

XEX files can begin executing INIT routines before loading has completed.

Special handling is currently required to allow interactive INIT routines to receive keyboard/joystick input while QNICE is still synchronously loading the XEX.

There may consequently still be unusual OSD/input interactions with some XEX files.

### OSD behaviour in running software

Some software may interfere with or prevent activation of the OSD once the program is running.

This has been observed with some titles and remains an area for further work.

### Compatibility

The Atari software library is enormous and this Alpha has not been exhaustively tested. CAS compatibility, particularly with unusual tape formats and turbo loaders, remains an area for further testing.

Working on MiSTer does not automatically guarantee identical behaviour on the MEGA65 port, so compatibility reports are useful.

---

# What to Test

Testing is particularly useful in the following areas:

- XL/XE ATR booting
- 400/800 ATR booting
- normal F11 cold boot
- F1 + F11 OPTION cold boot
- BASIC programs
- disk games requiring BASIC to be disabled
- software performing additional disk accesses after boot
- CAS cassette loading and motor start/stop behaviour
- XEX files
- compressed XEX files
- XEX files containing INIT routines
- cracktros/intros requiring START or other input
- joystick-controlled games
- keyboard-controlled software
- PAL software
- NTSC software
- different RAM configurations, especially **576K, 1088K and 4MB Axlon**
- software using extended memory (watch for display glitches)
- **cartridges**: standard, bank-switched (XEGS, Williams, Atarimax, MegaCart), OSS, and 1 MB multi-game cartridges
- loading a cartridge, then an XEX, then another cartridge
- VBXE software
- R3 and R6 boards

---

# Reporting Problems

When reporting a compatibility issue, please include as much of the following as possible:

- **Title/software name**
- **File type:** ATR, CAS, XEX, CAR, ROM or BIN
- **For cartridges:** file size, and the cartridge type if known
- **Machine mode:** XL/XE or 400/800
- **Video mode:** PAL or NTSC
- **RAM configuration**
- **MEGA65 board:** R3 or R6
- Whether BASIC was enabled or disabled
- Whether you used **F11** or **F1 + F11**
- What happens during boot/loading
- Any error message shown in the OSD
- Whether the software reaches its title screen
- Whether keyboard/joystick input works
- Whether additional disk loading works
- Whether the same image works on the MiSTer Atari800 core

For XEX problems, also mention whether the file contains an intro/cracktro or appears to wait for user input during loading.

---

# Alpha Release Notes

The main focus of the Alpha releases is getting the fundamental Atari 8-bit experience working reliably on the MEGA65:

**XL/XE and 400/800 machine operation, ATR disk access, CAS cassette loading, XEX loading, cartridges, keyboard and joystick input, PAL/NTSC operation, and the associated boot/reset behaviour.**

Alpha V3 moves the Atari's extended memory into HyperRAM. This frees on-chip RAM and makes the large memory configurations possible (up to 1088K Rambo and 4MB Axlon), while a cache and a modified address decoder keep the display glitch-free.

Alpha V3 also adds cartridge support, with cartridge images stored in HyperRAM.

ATR support includes continued disk access after the initial boot rather than merely loading the initial disk contents.

XEX support includes handling Atari's unusual ability to execute INIT routines part-way through a file load. Interactive INIT routines are allowed to receive physical input so that intros, decrunchers and similar routines can complete and allow loading to continue.
