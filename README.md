# Atari 800/XL/XE Core for MEGA65 — Alpha V1 Release

This is an **Alpha release** of the Atari 8-bit computer core for the MEGA65.  
The core is based on the MiSTer Atari800 implementation and has been adapted to run within the MiSTer2MEGA65 framework.  
This release is intended for testing. Although a substantial amount of software is already working, compatibility is not yet expected to be complete.  


## Overview

This project adapts the MiST/MiSTer Atari 800 core for the MEGA65 architecture using the M2M hardware abstraction layer.  

## Credits:  

MiSTer2MEGA65 Framework - sy2002 & MJoergen  
 * https://github.com/sy2002/MiSTer2MEGA65/

MiSTer Atari 800 Core - woj76,sorgelig,claude & carlosbravoa
 * https://github.com/MiSTer-devel/Atari800_MiSTer  


## Current Features

This Alpha currently supports:

- Atari **XL/XE** machine mode
- Atari **400/800** machine mode
- **PAL and NTSC**
- **ATR disk images**
- **XEX executable loading**
- MEGA65 joystick support
- Atari / MEGA65 keyboard mapping modes
- Configurable Atari RAM ( 8K/64K, 16K/128K, 32K/320K Compy, 48K/320K Rambo )
- Clip sides
- 15Khz or 31Khz analog video out support
- Clip sides ( see description below )
- RTC support
- VBXE options
- Cold and warm reset controls
- OPTION-assisted cold boot for software requiring BASIC to be disabled

**Cartridge images are not supported in this release.**
**PBI is also not supported in this version.**  

---

# The OSD Menu

The OSD provides access to disk and executable loading, video output, Atari machine configuration, memory expansion, VBXE, keyboard mapping and other core settings.

## Main Menu

- **Drive A**  
  Mounts an `.atr` disk image as Atari drive **D1:**.

- **Load XEX**  
  Loads an Atari `.xex` executable directly into the emulated Atari.  
  XEX loading is currently supported in **XL/XE mode only**.

- **HDMI**  
  Opens the HDMI video-output submenu.

- **System Settings**  
  Opens the Atari machine and hardware configuration submenu.

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

### RAM

The RAM menu selects both the memory available in 400/800 mode and the corresponding XL/XE memory configuration:

- **RAM: 8K / 64K**
- **RAM: 16K / 128K**
- **RAM: 32K / 320K Compy**
- **RAM: 48K / 320K Rambo**

The first value applies to **400/800 mode** and the second to **XL/XE mode**.

The default configuration is:

**48K / 320K Rambo**

This provides the full **48 KB** configuration for Atari 400/800 mode while providing **320 KB Rambo expanded memory** in XL/XE mode.

Some software is not compatible with expanded memory configurations.

For example, `BountyBox.xex` only works correctly with the **64 KB** XL/XE configuration.

If a game or XEX crashes, hangs or otherwise behaves unexpectedly with expanded memory enabled, try:

**RAM: 8K / 64K**

before assuming that the software is incompatible with the core.

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

Cartridge support is deliberately **not included in this Alpha**.

Please treat this as a test build and report software that behaves differently from the MiSTer Atari800 core.

---

# RAM Configuration

The default RAM configuration is **320 KB Rambo**.

This configuration is used by default because it provides expanded memory for XL/XE software while also supporting the **48 KB memory configuration required for Atari 400/800 mode**.

Some Atari software is not compatible with expanded memory configurations and may only work correctly when configured for a standard **64 KB Atari XL/XE**.  


For example:

A version of `BountyBob.xex` that I tested requires the **64 KB** configuration and does not work correctly with more than 64Kb of ram.  

If a game or XEX fails to load, crashes, hangs, or behaves unexpectedly in XL/XE mode, try changing the RAM configuration to:

**64 KB**

before assuming the software is incompatible with the core.

For Atari 400/800 mode, use the appropriate configuration.

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

It is separate from the normal XL/XE and 400/800 operating-system ROMs.

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

# XEX Executable Files

XEX executable loading is supported in **Atari XL/XE mode**.

It is not currently supported in Atari 400/800 mode.

An Atari XEX can loosely be thought of as the Atari equivalent of a C64 PRG: executable data is loaded directly into the machine rather than being accessed as a disk filesystem.

However, Atari XEX files have an important characteristic that makes loading more complicated than simply copying the entire file into memory and starting it.

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

# RAM Configuration

The core provides selectable Atari RAM configurations.

Some software has specific memory requirements, particularly software written for later XL/XE configurations or programs using extended memory.

When reporting a problem, please include the RAM configuration being used.

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

No cartridge, PBI, Paddle support or 4Mb Axlon  

### Cartridge images

**Cartridge loading is not supported in this release.**

The cartridge implementation is not included in this Alpha, it is currently a WIP  

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

The Atari software library is enormous and this Alpha has not been exhaustively tested.

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
- XEX files
- compressed XEX files
- XEX files containing INIT routines
- cracktros/intros requiring START or other input
- joystick-controlled games
- keyboard-controlled software
- PAL software
- NTSC software
- different RAM configurations
- VBXE software

---

# Reporting Problems

When reporting a compatibility issue, please include as much of the following as possible:

- **Title/software name**
- **File type:** ATR or XEX
- **Machine mode:** XL/XE or 400/800
- **Video mode:** PAL or NTSC
- **RAM configuration**
- Whether BASIC was enabled or disabled
- Whether you used **F11** or **F1 + F11**
- What happens during boot/loading
- Whether the software reaches its title screen
- Whether keyboard/joystick input works
- Whether additional disk loading works
- Whether the same image works on the MiSTer Atari800 core

For XEX problems, also mention whether the file contains an intro/cracktro or appears to wait for user input during loading.

---

# Alpha Release Notes

The main focus of this Alpha is getting the fundamental Atari 8-bit experience working reliably on the MEGA65:

**XL/XE and 400/800 machine operation, ATR disk access, XEX loading, keyboard and joystick input, PAL/NTSC operation, and the associated boot/reset behaviour.**

ATR support includes continued disk access after the initial boot rather than merely loading the initial disk contents.

XEX support includes handling Atari's unusual ability to execute INIT routines part-way through a file load. Interactive INIT routines are allowed to receive physical input so that intros, decrunchers and similar routines can complete and allow loading to continue.

