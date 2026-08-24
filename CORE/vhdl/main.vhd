----------------------------------------------------------------------------------
-- MiSTer2MEGA65 Framework
--
-- Wrapper for the MiSTer core that runs exclusively in the core's clock domanin
--
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
----------------------------------------------------------------------------------

/*

 Atari memory system
                 ┌──────────────────────┐
                 │                      │
       CPU ─────►│                      │
     ANTIC ─────►│   mapper / arbiter   │
      VBXE ─────►│                      │
      Cart ─────►│                      │
                 └──────────┬───────────┘
                            │
                      Atari memory
                         contract
                            │
                 ┌──────────▼───────────┐
                 │ SDRAM compatibility  │
                 │ / HyperRAM adapter   │
                 │                      │
                 │ BRAM cache/buffer    │
                 │ request scheduling   │
                 │ burst reads          │
                 │ write buffering      │
                 │ CDC                  │
                 └──────────┬───────────┘
                            │
                    M2M HyperRAM API
                            │
                         8 MB

*/

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.video_modes_pkg.all;

entity main is
   generic (
      G_VDNUM                 : natural                     -- amount of virtual drives
   );
   port (
      clk_main_i              : in  std_logic;
      clk_mem_i               : in  std_logic;
      clk_video_i             : in  std_logic;
    
      reset_soft_i            : in  std_logic;
      reset_hard_i            : in  std_logic;
      pause_i                 : in  std_logic;
      
      atari_os_i              : in  std_logic_vector(1 downto 0);
      
      atari_osrom_addr_o      : out std_logic_vector(13 downto 0);
      atari_osrom_data_i      : in  std_logic_vector(7 downto 0);
    
      -- MiSTer core main clock speed:
      -- Make sure you pass very exact numbers here, because they are used for avoiding clock drift at derived clocks
      clk_main_speed_i        : in  natural;

      -- Video output
      video_ce_o              : out std_logic;
      video_ce_ovl_o          : out std_logic;
      video_red_o             : out std_logic_vector(7 downto 0);
      video_green_o           : out std_logic_vector(7 downto 0);
      video_blue_o            : out std_logic_vector(7 downto 0);
      video_vs_o              : out std_logic;
      video_hs_o              : out std_logic;
      video_hblank_o          : out std_logic;
      video_vblank_o          : out std_logic;

      -- Audio output (Signed PCM)
      audio_left_o            : out signed(15 downto 0);
      audio_right_o           : out signed(15 downto 0);

      -- M2M Keyboard interface
      kb_key_num_i            : in  integer range 0 to 79;    -- cycles through all MEGA65 keys
      kb_key_pressed_n_i      : in  std_logic;                -- low active: debounced feedback: is kb_key_num_i pressed right now?

      -- MEGA65 joysticks and paddles/mouse/potentiometers
      joy_1_up_n_i            : in  std_logic;
      joy_1_down_n_i          : in  std_logic;
      joy_1_left_n_i          : in  std_logic;
      joy_1_right_n_i         : in  std_logic;
      joy_1_fire_n_i          : in  std_logic;

      joy_2_up_n_i            : in  std_logic;
      joy_2_down_n_i          : in  std_logic;
      joy_2_left_n_i          : in  std_logic;
      joy_2_right_n_i         : in  std_logic;
      joy_2_fire_n_i          : in  std_logic;

      pot1_x_i                : in  std_logic_vector(7 downto 0);
      pot1_y_i                : in  std_logic_vector(7 downto 0);
      pot2_x_i                : in  std_logic_vector(7 downto 0);
      pot2_y_i                : in  std_logic_vector(7 downto 0)
   );
end entity main;

architecture synthesis of main is


signal keyboard_n          : std_logic_vector(79 downto 0);
signal reset               : std_logic;

-- Atari 800 side signals
signal areset              : std_logic;
signal cpu_halt            : std_logic;

signal atari_r             : std_logic_vector(7 downto 0);
signal atari_g             : std_logic_vector(7 downto 0);
signal atari_b             : std_logic_vector(7 downto 0);

signal atari_vs            : std_logic;
signal atari_hs            : std_logic;
signal atari_hblank        : std_logic;
signal atari_vblank        : std_logic;
signal atari_pixce         : std_logic;

signal atari_audio_l       : std_logic_vector(15 downto 0);
signal atari_audio_r       : std_logic_vector(15 downto 0);

signal sdram_ready         : std_logic;

signal dma_data_in         : std_logic_vector(7 downto 0);
signal dma_ready           : std_logic;

signal tape_fifo_full      : std_logic;
signal tape_fifo_empty     : std_logic;
signal tape_active         : std_logic;

signal sio_in              : std_logic;
signal sio_out             : std_logic;
signal sio_clkin           : std_logic;
signal sio_cmd             : std_logic;
signal sio_proc            : std_logic;
signal sio_motor           : std_logic;
signal sio_irq             : std_logic;

signal uart_data_read      : std_logic_vector(15 downto 0);

signal cache_dirty         : std_logic_vector(G_VDNUM - 1 downto 0);
signal prevent_reset       : std_logic;

signal reset_core_n        : std_logic := '1';
signal reset_core_int      : std_logic := '0';


begin

   -- prevent data corruption by not allowing a soft reset to happen while the cache is still dirty
   -- since we can have more than one cache that might be dirty, we convert the std_logic_vector of length G_VDNUM
   -- into an unsigned and check for zero
   --prevent_reset <= '0' when unsigned(cache_dirty) = 0 else
   --                 '1';
   prevent_reset <= '0'; -- force the reset for now until vdrives are connected properly
    
   audio_left_o     <= signed(atari_audio_l);
   audio_right_o    <= signed(atari_audio_r);
   
   
   video_vs_o     <= atari_vs;
   video_hs_o     <= atari_hs;
   video_red_o    <= atari_r;
   video_green_o  <= atari_g;
   video_blue_o   <= atari_b;
   video_ce_o     <= atari_pixce;

   video_hblank_o <= atari_hblank;
   video_vblank_o <= atari_vblank;
   

   --------------------------------------------------------------------------------------------------
   -- Hard reset
   --------------------------------------------------------------------------------------------------

   hard_reset_proc : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         if reset_soft_i = '1' or reset_hard_i = '1' or reset_core_int = '1' then
            reset_core_n <= prevent_reset and (not reset_hard_i);
        else
            reset_core_n <= '1';
        end if;
      end if;
   end process hard_reset_proc;
   
   i_atari800top : entity work.atari800top
   port map (
      CLK                    => clk_main_i,
      CLK_SDRAM              => clk_mem_i,      -- if we retain this for now
      RESET_N                => reset_core_n,
      ARESET                 => areset,
      
      OSROM_ADDR             => atari_osrom_addr_o,
      OSROM_DATA             => atari_osrom_data_i,

      -- SDRAM physical interface:
      -- temporary signals initially,
      -- replaced later by HyperRAM bridge

      TURBOFREEZER_ROM_LOADED => '0',
      SDRAM_READY             => sdram_ready,

      OSD_PAUSE               => pause_i,

      SET_RESET_IN            => '0',
      SET_PAUSE_IN            => '0',
      SET_FREEZER_IN          => '0',
      SET_RESET_RNMI_IN       => '0',
      SET_OPTION_FORCE_IN     => '0',
      SET_START_FORCE_IN      => '0',
      SET_SPACE_FORCE_IN      => '0',

      CART1_SELECT_IN         => (others => '0'),
      CART2_SELECT_IN         => (others => '0'),

      EMU_FLASH_REQUEST       => open,
      EMU_FLASH_SLAVE         => open,

      HOT_KEYS                => open,

      UART_ADDR               => (others => '0'),
      UART_ENABLE             => '0',
      UART_WR                 => '0',
      UART_DATA_WRITE         => (others => '0'),
      UART_DATA_READ          => uart_data_read,

      TAPE_DATA               => (others => '0'),
      TAPE_DATA_WR            => '0',
      TAPE_FIFO_FULL          => tape_fifo_full,
      TAPE_FIFO_EMPTY         => tape_fifo_empty,
      TAPE_PWM_CONFIG         => "000",
      TAPE_PWM_INVERT         => '0',
      TAPE_RESET              => '0',
      TAPE_ACTIVE             => tape_active,

      HPS_DMA_ADDR            => (others => '0'),
      HPS_DMA_REQ             => '0',
      HPS_DMA_READ_ENABLE     => '0',
      HPS_DMA_DATA_OUT        => (others => '0'),
      HPS_DMA_DATA_IN         => dma_data_in,
      HPS_DMA_READY           => dma_ready,

      PAL                     => '1', -- PAL for now.
      CLIP_SIDES              => '0',
      --GTIA_XCOLOR             => '0', n/a
 
      VGA_VS                  => atari_vs,
      VGA_HS                  => atari_hs,
      VGA_B                   => atari_b,
      VGA_G                   => atari_g,
      VGA_R                   => atari_r,
      VGA_PIXCE               => atari_pixce,     

      interlace_enable        => '0',
      interlace               => open,
      interlace_field         => open,

      HBLANK                  => atari_hblank,
      VBLANK                  => atari_vblank,

      -- CPU_SPEED             => 1x value,
      -- RAM_SIZE              => 64K value,
      cpu_speed               => "000001",
      RAM_SIZE                => "000",

      OS_MODE_800             => '0',
      OS_800_16K              => '0',
      PBI_MODE                => '0',
      XEX_LOADER_MODE         => '0',

      WARM_RESET_MENU         => '0',
      COLD_RESET_MENU         => '0',

      RTC                     => (others => '0'),

      -- CLK_CONF              => fixed NTSC configuration,

      VBXE_MODE               => (others => '0'),
      VBXE_PALETTE_RGB        => (others => '0'),
      VBXE_PALETTE_INDEX      => (others => '0'),
      VBXE_PALETTE_COLOR      => (others => '0'),

      POKEYMAX_CONFIG         => (others => '0'),

      AUDIO_L                 => atari_audio_l,
      AUDIO_R                 => atari_audio_r,

      SIO_MODE                => '0',
      SIO_IN                  => '1',
      SIO_OUT                 => sio_out,
      SIO_CLKIN               => '1',
      SIO_CMD                 => sio_cmd,
      SIO_PROC                => sio_proc,
      SIO_MOTOR               => sio_motor,
      SIO_IRQ                 => sio_irq,

      CPU_HALT                => cpu_halt,

      PS2_KEY                 => (others => '0'),

      -- joysticks next
      JOY1X                   => (others => '0'),
      JOY1Y                   => (others => '0'),
      JOY2X                   => (others => '0'),
      JOY2Y                   => (others => '0'),
      JOY3X                   => (others => '0'),
      JOY3Y                   => (others => '0'),
      JOY4X                   => (others => '0'),
      JOY4Y                   => (others => '0'),

      JOY1                    => (others => '0'),
      JOY2                    => (others => '0'),
      JOY3                    => (others => '0'),
      JOY4                    => (others => '0')
   );
    
   
   i_keyboard : entity work.keyboard
      port map (
         clk_main_i           => clk_main_i,

         -- Interface to the MEGA65 keyboard
         key_num_i            => kb_key_num_i,
         key_pressed_n_i      => kb_key_pressed_n_i,

         -- @TODO: Create the kind of keyboard output that your core needs
         -- "example_n_o" is a low active register and used by the demo core:
         --    bit 0: Space
         --    bit 1: Return
         --    bit 2: Run/Stop
         example_n_o          => keyboard_n
      ); -- i_keyboard

end architecture synthesis;

