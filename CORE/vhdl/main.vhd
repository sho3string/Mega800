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
use work.globals.all;
use work.vdrives_pkg.all;

library xpm;
use xpm.vcomponents.xpm_cdc_single;
use xpm.vcomponents.xpm_cdc_array_single;

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
      
      atari_basicrom_addr_o   : out std_logic_vector(12 downto 0);
      atari_basicrom_data_i   : in  std_logic_vector(7 downto 0);
      
      
      -----------------------------------------------------------------------
      -- Atari HPS/DMA bridge
      -----------------------------------------------------------------------
      dma_addr_i              : in  std_logic_vector(25 downto 0);
      dma_req_i               : in  std_logic;
      dma_read_enable_i       : in  std_logic;
      dma_data_i              : in  std_logic_vector(7 downto 0);
      dma_data_o              : out std_logic_vector(7 downto 0);
      dma_ready_o             : out std_logic;

      -----------------------------------------------------------------------
      -- XEX control
      -----------------------------------------------------------------------
      xex_loader_mode_i       : in  std_logic;
      xex_reset_i             : in  std_logic;

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
      pot2_y_i                : in  std_logic_vector(7 downto 0);
      
      atari_qnice_clk_i       : in  std_logic;
      atari_qnice_addr_i      : in  std_logic_vector(27 downto 0);
      atari_qnice_data_i      : in  std_logic_vector(15 downto 0);
      atari_qnice_data_o      : out std_logic_vector(15 downto 0);
      atari_qnice_ce_i        : in  std_logic;
      atari_qnice_we_i        : in  std_logic;
      
      atr_header_ok_o         : out std_logic;
      atr_geometry_o          : out std_logic_vector(1 downto 0);
      atr_sector_count_ok_o   : out std_logic;
      atr_sector_count_512_o  : out std_logic;
      atr_sector_count_1040_o : out std_logic;
      
      osm_control_i           : in  std_logic_vector(255 downto 0);
      rtc_i                   : in  std_logic_vector(64 downto 0)
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
--signal sio_proc            : std_logic;
signal sio_motor           : std_logic;
--signal sio_irq             : std_logic;

signal uart_data_read      : std_logic_vector(15 downto 0);

signal vdrives_mounted     : std_logic_vector(G_VDNUM - 1 downto 0);
signal disk_change         : std_logic_vector(G_VDNUM - 1 downto 0);
signal cache_dirty         : std_logic_vector(G_VDNUM - 1 downto 0);
signal prevent_reset       : std_logic;

signal reset_core_n        : std_logic := '1';
signal reset_core_int      : std_logic := '0';

signal ps2_key             : std_logic_vector(10 downto 0);

signal os_mode_800         : std_logic;
signal os_800_16k          : std_logic;

signal mega65_kblayout     : std_logic;

signal sd_buff_addr        : std_logic_vector(8 downto 0);
signal sd_buff_dout        : std_logic_vector(7 downto 0);
signal img_mounted         : std_logic_vector(G_VDNUM - 1 downto 0);
signal img_readonly        : std_logic;
signal img_size            : std_logic_vector(31 downto 0);
signal img_type            : std_logic_vector(1 downto 0);

signal sd_buff_din         : vd_vec_array(G_VDNUM - 1 downto 0)(7 downto 0);
signal sd_buff_wr          : std_logic;

signal sd_lba              : vd_vec_array(G_VDNUM - 1 downto 0)(31 downto 0);
signal sd_ack              : vd_std_array(G_VDNUM - 1 downto 0);
signal sd_rd               : vd_std_array(G_VDNUM - 1 downto 0);
signal sd_wr               : vd_std_array(G_VDNUM - 1 downto 0);
signal sd_blk_cnt          : vd_vec_array(G_VDNUM - 1 downto 0)(5 downto 0);

signal atr_data_bytes      : unsigned(27 downto 0) := (others => '0');

signal pokeymax_config     : std_logic_vector(38 downto 0);

  
type t_atr_test_state is (
    ATR_IDLE,
    ATR_READ_START,
    ATR_WAIT_ACK_HIGH,
    ATR_WAIT_ACK_LOW,
    ATR_CHECK_HEADER,
    ATR_CALC_GEOMETRY,
    ATR_CALC_GEOMETRY_2,
    ATR_DONE
);

type t_atr_test_buffer is array (0 to 511) of std_logic_vector(7 downto 0);
signal atr_test_state       : t_atr_test_state := ATR_IDLE;
signal atr_test_buffer      : t_atr_test_buffer;
signal atr_header_ok        : std_logic := '0';

-- disk-change/mounted state synchronized back into QNICE domain
signal vdrive_event_main    : std_logic_vector(1 downto 0);
signal vdrive_event_qnice   : std_logic_vector(1 downto 0);
signal disk_change_qnice_d  : std_logic := '0';
signal disk_change_pending  : std_logic := '0';

signal atr_valid            : std_logic := '0';
signal atr_sector_size      : unsigned(15 downto 0) := (others => '0');
signal atr_paragraphs       : unsigned(23 downto 0) := (others => '0');
signal atr_sector_count     : unsigned(23 downto 0) := (others => '0');
   

-- kb constants
constant m65_f1            : integer := 4;  -- OPTION
constant m65_f3            : integer := 5;  -- SELECT
constant m65_f5            : integer := 6;  -- START
constant m65_f7            : integer := 3;  -- RESET
constant m65_f9            : integer := 68; -- HELP
constant m65_restore       : integer := 75; -- Pause



begin

   -- prevent data corruption by not allowing a soft reset to happen while the cache is still dirty
   -- since we can have more than one cache that might be dirty, we convert the std_logic_vector of length G_VDNUM
   -- into an unsigned and check for zero
   --prevent_reset <= '0' when unsigned(cache_dirty) = 0 else
   --                 '1';
    prevent_reset <= '0'; -- force the reset for now until vdrives are connected properly
    
    
    -- default MiSTer config
    pokeymax_config(38 downto 36) <= "001"; -- mix_sel2
    pokeymax_config(35 downto 33) <= "000"; -- mix_sel1
    pokeymax_config(32 downto 31) <= "01";  -- PSG stereo
    pokeymax_config(30)           <= '0';   -- PSG envelope
    pokeymax_config(29 downto 28) <= "00";  -- PSG volume
    pokeymax_config(27 downto 26) <= "00";  -- PSG freq
    pokeymax_config(25 downto 23) <= "010"; -- SID2 filter
    pokeymax_config(22 downto 20) <= "010"; -- SID1 filter
    pokeymax_config(19)           <= '1';   -- Covox restricted
    pokeymax_config(18)           <= '1';   -- PSG restricted
    pokeymax_config(17)           <= '1';   -- SID restricted
    pokeymax_config(16 downto 15) <= "11";  -- Pokey restriction
    pokeymax_config(14)           <= '0';   -- IRQ mode
    pokeymax_config(13)           <= '1';   -- volume/saturate
    pokeymax_config(12)           <= '0';   -- channel mode
    pokeymax_config(11 downto 10) <= "10";  -- ADC volume
    pokeymax_config(9 downto 8)   <= "11";  -- GTIA speaker L+R
    pokeymax_config(7 downto 4)   <= "1010";-- post divide
    pokeymax_config(3 downto 2)   <= "11";  -- L/R channels enabled
    pokeymax_config(1)            <= '1';   -- mono detect
    pokeymax_config(0)            <= '0';   -- PokeyMax fancy enable
    
    audio_left_o     <= signed(atari_audio_l);
    audio_right_o    <= signed(atari_audio_r);
    
    dma_data_o       <= dma_data_in;
    dma_ready_o      <= dma_ready;

    video_vs_o     <= atari_vs;
    video_hs_o     <= atari_hs;
    video_red_o    <= atari_r;
    video_green_o  <= atari_g;
    video_blue_o   <= atari_b;
    video_ce_o     <= atari_pixce;
    
    video_hblank_o <= atari_hblank;
    video_vblank_o <= atari_vblank;
    
    atr_header_ok_o<= atr_valid;
    
    atr_geometry_o <=
   "01" when atr_sector_size = to_unsigned(128, 16) else
   "10" when atr_sector_size = to_unsigned(256, 16) else
   "11" when atr_sector_size = to_unsigned(512, 16) else
   "00";
   
   atr_sector_count_ok_o <=
   '1' when atr_sector_count = to_unsigned(720, atr_sector_count'length)
   else '0';
   
   atr_sector_count_1040_o <=
   '1' when atr_sector_count = to_unsigned(1040, atr_sector_count'length)
   else '0';
   
   atr_sector_count_512_o <=
   '1' when atr_sector_count = to_unsigned(512, atr_sector_count'length)
   else '0';
    
    -- Keyboard mapping mode '0' = Atari positional, '1' = MEGA65 semantic.
    mega65_kblayout <= osm_control_i(C_MENU_KBD_MEGA65);
    
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
      
      BASICROM_ADDR          => atari_basicrom_addr_o,
      BASICROM_DATA          => atari_basicrom_data_i,

      -- SDRAM physical interface:
      -- temporary signals initially,
      -- replaced later by HyperRAM bridge

      TURBOFREEZER_ROM_LOADED => '0',
      SDRAM_READY             => sdram_ready,

      OSD_PAUSE               => pause_i,

      SET_RESET_IN            => (not keyboard_n(m65_f7)) or xex_reset_i,
      SET_PAUSE_IN            => not keyboard_n(m65_restore),
      SET_FREEZER_IN          => '0', -- to do
      SET_RESET_RNMI_IN       => '0',
      SET_OPTION_FORCE_IN     => not keyboard_n(m65_f1),
      SET_SELECT_FORCE_IN     => not keyboard_n(m65_f3),
      SET_START_FORCE_IN      => not keyboard_n(m65_f5),
      SET_HELP_FORCE_IN       => not keyboard_n(m65_f9),
      SET_SPACE_FORCE_IN      => '0', -- not required

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

      HPS_DMA_ADDR            => dma_addr_i,
      HPS_DMA_REQ             => dma_req_i,
      HPS_DMA_READ_ENABLE     => dma_read_enable_i,
      HPS_DMA_DATA_OUT        => dma_data_i,
      HPS_DMA_DATA_IN         => dma_data_in,
      HPS_DMA_READY           => dma_ready,

      PAL                     => osm_control_i(C_MENU_PAL),
      CLIP_SIDES              => osm_control_i(C_MENU_CLIP_SIDES),
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

      OS_MODE_800             => atari_os_i(0),
      OS_800_16K              => atari_os_i(1),
      PBI_MODE                => '0',
      XEX_LOADER_MODE         => xex_loader_mode_i,

      WARM_RESET_MENU         => '0',
      COLD_RESET_MENU         => '0',

      RTC                     => rtc_i,

      -- CLK_CONF              => fixed NTSC configuration,

      VBXE_MODE               => (others => '0'),
      VBXE_PALETTE_RGB        => (others => '0'),
      VBXE_PALETTE_INDEX      => (others => '0'),
      VBXE_PALETTE_COLOR      => (others => '0'),

      POKEYMAX_CONFIG         => pokeymax_config,

      AUDIO_L                 => atari_audio_l,
      AUDIO_R                 => atari_audio_r,

      SIO_MODE                => '0',
      SIO_IN                  => '1',
      SIO_OUT                 => sio_out,
      SIO_CLKIN               => '1',
      SIO_CMD                 => sio_cmd,
      SIO_PROC                => '1',
      SIO_MOTOR               => sio_motor,
      SIO_IRQ                 => '1',

      CPU_HALT                => cpu_halt,

      PS2_KEY                 => ps2_key,

      -- analog joysticks - TO DO
      JOY1X                   => (others => '0'),
      JOY1Y                   => (others => '0'),
      JOY2X                   => (others => '0'),
      JOY2Y                   => (others => '0'),
      JOY3X                   => (others => '0'),
      JOY3Y                   => (others => '0'),
      JOY4X                   => (others => '0'),
      JOY4Y                   => (others => '0'),

      JOY1                    => (0=>not joy_1_right_n_i,1=> not joy_1_left_n_i,
                                  2=>not joy_1_down_n_i, 3=> not joy_1_up_n_i,
                                  4=>not joy_1_fire_n_i,others=> '0'),
      JOY2                    => (0=>not joy_2_right_n_i,1=>not joy_2_left_n_i,
                                  2=>not joy_2_down_n_i, 3=>not joy_2_up_n_i,
                                  4 => not joy_2_fire_n_i,others=> '0'),
      -- to be connected via joystick expansion board
      JOY3                    => (others => '0'),
      JOY4                    => (others => '0')
   );
   
   i_vdrives : entity work.vdrives
      generic map (
         VDNUM       => G_VDNUM,
         BLKSZ       => 2                    -- 1 = 256 bytes block size, 2 = 512 bytes blocksize
      )
      port map
      (
         clk_qnice_i              => atari_qnice_clk_i,
         clk_core_i               => clk_main_i,
         reset_core_i             => not reset_core_n,

         -- Core clock domain
         img_mounted_o            => img_mounted,
         img_readonly_o           => img_readonly,
         img_size_o               => img_size,
         img_type_o               => img_type,
         drive_mounted_o          => vdrives_mounted,
         img_mounted_toggle_o     => disk_change,
         -- Cache output signals: The dirty flags can be used to enforce data consistency
         -- (for example by ignoring/delaying a reset or delaying a drive unmount/mount, etc.)
         -- The flushing flags can be used to signal the fact that the caches are currently
         -- flushing to the user, for example using a special color/signal for example
         -- at the drive led
         cache_dirty_o     => cache_dirty,
         cache_flushing_o  => open,

         -- QNICE clock domain
         sd_lba_i          => sd_lba,
         sd_blk_cnt_i      => sd_blk_cnt,
         sd_rd_i           => sd_rd,
         sd_wr_i           => sd_wr,
         sd_ack_o          => sd_ack,

         sd_buff_addr_o    => sd_buff_addr,
         sd_buff_dout_o    => sd_buff_dout,
         sd_buff_din_i     => sd_buff_din,
         sd_buff_wr_o      => sd_buff_wr,

         -- QNICE interface (MMIO, 4k-segmented)
         -- qnice_addr is 28-bit because we have a 16-bit window selector and a 4k window: 65536*4096 = 268.435.456 = 2^28
         qnice_addr_i      => atari_qnice_addr_i,
         qnice_data_i      => atari_qnice_data_i,
         qnice_data_o      => atari_qnice_data_o,
         qnice_ce_i        => atari_qnice_ce_i,
         qnice_we_i        => atari_qnice_we_i
   ); -- i_vdrives
   
   vdrive_event_main(0) <= disk_change(0);
   vdrive_event_main(1) <= vdrives_mounted(0);

   i_vdrive_event_cdc : xpm_cdc_array_single
       generic map (
          WIDTH => 2
       )
       port map (
          src_clk  => clk_main_i,
          src_in   => vdrive_event_main,
          dest_clk => atari_qnice_clk_i,
          dest_out => vdrive_event_qnice
       );
       
   atr_test_buffer_write : process(atari_qnice_clk_i)
    begin
       if rising_edge(atari_qnice_clk_i) then
    
          if sd_buff_wr = '1' then
             atr_test_buffer(to_integer(unsigned(sd_buff_addr))) <= sd_buff_dout;
          end if;
    
       end if;
    end process;
    
    atr_vdrive_test : process(atari_qnice_clk_i)
    begin
       if rising_edge(atari_qnice_clk_i) then
          -- defaults
          sd_wr(0)      <= '0';
          sd_buff_din(0) <= (others => '0');
          
          -- Latch a disk-change event until the FSM has consumed it.
          if vdrive_event_qnice(0) /= disk_change_qnice_d then
            disk_change_pending <= '1';
          end if;
    
          -- remember the previous mount-toggle state
          disk_change_qnice_d <= vdrive_event_qnice(0);
          case atr_test_state is
             -------------------------------------------------------
             -- Wait for a new disk image to be mounted
             -------------------------------------------------------
             when ATR_IDLE =>
               sd_rd(0)      <= '0';
               sd_lba(0)     <= (others => '0');
               sd_blk_cnt(0) <= (others => '0');
               atr_header_ok <= '0';
            
               -- disk_change is a toggle, not a pulse
               if disk_change_pending = '1' then
                   -- This event has now been consumed.
                   disk_change_pending <= '0';
                   -- Ignore unmount events; start a new header read on mount.
                   if vdrive_event_qnice(1) = '1' then
                      atr_test_state <= ATR_READ_START;
                   end if;
                
                end if;
             -------------------------------------------------------
             -- Request one 512-byte block, LBA 0
             -------------------------------------------------------
             when ATR_READ_START =>
                sd_lba(0)     <= x"00000000";
                sd_blk_cnt(0) <= "000000";    -- blocks - 1 = 0 => one block
                sd_rd(0)      <= '1';
                atr_test_state <= ATR_WAIT_ACK_HIGH;
    
    
             -------------------------------------------------------
             -- Wait for QNICE to accept the request
             -------------------------------------------------------
             when ATR_WAIT_ACK_HIGH =>
               if sd_ack(0) = '1' then
                  -- Request has been accepted.
                  -- Drop RD now so it cannot be interpreted as another request
                  -- when ACK returns low.
                  sd_rd(0) <= '0';
            
                  atr_test_state <= ATR_WAIT_ACK_LOW;
               end if;
   
             -------------------------------------------------------
             -- Keep request asserted for whole transfer
             -------------------------------------------------------
             when ATR_WAIT_ACK_LOW =>
               if sd_ack(0) = '0' then
                  atr_test_state <= ATR_CHECK_HEADER;
               end if;
 
             -------------------------------------------------------
             -- ATR magic is little-endian $0296:
             --
             -- file byte 0 = $96
             -- file byte 1 = $02
             -------------------------------------------------------
             when ATR_CHECK_HEADER =>

               if atr_test_buffer(0) = x"96" and
                  atr_test_buffer(1) = x"02" then
            
                  atr_valid <= '1';
            
                  -- bytes 4/5: sector size, little endian
                atr_sector_size <=
                   unsigned(atr_test_buffer(5)) & unsigned(atr_test_buffer(4));
                
                -- bytes 2/3 plus byte 6: paragraph count, little endian
                atr_paragraphs <=
                   unsigned(atr_test_buffer(6)) &
                   unsigned(atr_test_buffer(3)) &
                   unsigned(atr_test_buffer(2));
                else
                  atr_valid       <= '0';
                  atr_sector_size <= (others => '0');
                  atr_paragraphs  <= (others => '0');
            
               end if;
            
               atr_test_state <= ATR_CALC_GEOMETRY;
             
             when ATR_CALC_GEOMETRY =>

               if atr_valid = '1' then
                  if atr_sector_size = to_unsigned(512, 16) then
                     -- MiSTer:
                     -- sector_count = paragraphs / 32
                     atr_sector_count <=
                        resize(
                           shift_right(atr_paragraphs, 5),
                           atr_sector_count'length
                        );
                  elsif atr_sector_size = to_unsigned(256, 16) then
            
                     -- First three sectors occupy 384 bytes = 24 paragraphs.
                     --
                     -- 3 + ((paragraphs * 16 - 384) / 256)
                     -- =
                     -- 3 + ((paragraphs - 24) / 16)
                     atr_sector_count <=
                        resize(
                           shift_right(
                              atr_paragraphs - to_unsigned(24, atr_paragraphs'length),
                              4
                           ) + 3,
                           atr_sector_count'length
                        );
                  elsif atr_sector_size = to_unsigned(128, 16) then
                     -- 3 + ((paragraphs * 16 - 384) / 128)
                     -- =
                     -- 3 + ((paragraphs - 24) / 8)
                     atr_sector_count <=
                        resize(
                           shift_right(
                              atr_paragraphs - to_unsigned(24, atr_paragraphs'length),
                              3
                           ) + 3,
                           atr_sector_count'length
                        );
                  else
                     atr_valid        <= '0';
                     atr_sector_count <= (others => '0');
                  end if;
               else
                  atr_sector_count <= (others => '0');
               end if;
               atr_test_state <= ATR_DONE;
             when ATR_CALC_GEOMETRY_2 =>
                atr_test_state <= ATR_DONE;
             -------------------------------------------------------
             -- Stay here until another disk-change event
             -------------------------------------------------------
             when ATR_DONE =>
               sd_rd(0) <= '0';
               -- A disk-change event is waiting.
               -- Return to IDLE, which will consume it.
               if disk_change_pending = '1' then
                  atr_test_state <= ATR_IDLE;
               end if;
              end case;
           end if;
           end process;
    
   
   i_keyboard : entity work.keyboard
   port map (
      clk_main_i        => clk_main_i,
      key_num_i         => kb_key_num_i,
      key_pressed_n_i   => kb_key_pressed_n_i,
      mega65_layout_i   => mega65_kblayout,
      ps2_key_o         => ps2_key,
      keyboard_n_o      => keyboard_n
   );

end architecture synthesis;

