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
      atr_sector4_ok_o        : out std_logic;
      
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

signal atr_boot_dma_active : std_logic := '0';
signal atr_boot_dma_addr   : unsigned(15 downto 0) := (others => '0');
signal atr_boot_dma_req    : std_logic := '0';
signal atr_boot_reset      : std_logic := '0';
signal atr_data_bytes      : unsigned(27 downto 0) := (others => '0');
signal atr_boot_option_force : std_logic := '0';
signal atari_option_force_in : std_logic;


signal atari_dma_addr_mux  : std_logic_vector(25 downto 0);
signal atari_dma_req_mux   : std_logic;
signal atari_dma_read_mux  : std_logic;
signal atari_dma_data_mux  : std_logic_vector(7 downto 0);

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
signal sio_uart_addr       : std_logic_vector(4 downto 0) := (others => '0');
signal sio_uart_enable     : std_logic := '0';
signal sio_uart_wr         : std_logic := '0';
signal sio_uart_data_write : std_logic_vector(7 downto 0) := (others => '0');

type t_sio_cmd is array (0 to 4) of std_logic_vector(7 downto 0);
signal sio_cmd_bytes       : t_sio_cmd := (others => (others => '0'));

type t_sio_command_kind is (
   SIO_COMMAND_NONE,
   SIO_COMMAND_STATUS,
   SIO_COMMAND_READ,
   SIO_COMMAND_NAK
);

type t_sio_state is (
   SIO_IDLE,

   SIO_RXSTAT_WAIT,
   SIO_RXSTAT_CAPTURE,

   SIO_RX_READ,
   SIO_RX_WAIT,
   SIO_RX_CAPTURE,

   SIO_VALIDATE,

   -- COMMAND-line release handling.
   -- Command bytes 1..5 are validated first, then the
   -- separate release FIFO entry is consumed.
   SIO_CMDREL_STAT_READ,
   SIO_CMDREL_STAT_WAIT,
   SIO_CMDREL_STAT_CAPTURE,
   SIO_CMDREL_FETCH,
   SIO_CMDREL_FETCH_WAIT,
   SIO_CMDREL_CAPTURE,
  
   SIO_DIV_READ,
   SIO_DIV_WAIT,
   SIO_DIV_CAPTURE,
   SIO_DIV_WRITE,

   SIO_DELAY_ACK,
   SIO_AFTER_ACK,

   SIO_ATR_WAIT,
   SIO_ATR_SETTLE,

   SIO_DELAY_COMPLETE,
   SIO_AFTER_COMPLETE,

   SIO_DELAY_DATA,

   SIO_STATUS_SEND,
   SIO_STATUS_SENT,

   SIO_READ_SEND,
   SIO_READ_SENT,
   SIO_READ_CHECKSUM_SENT,

   SIO_TXSTAT_READ,
   SIO_TXSTAT_WAIT,
   SIO_TXSTAT_CAPTURE,
   SIO_TX_WRITE
);

signal sio_state              : t_sio_state := SIO_IDLE;
signal sio_tx_return_state    : t_sio_state := SIO_IDLE;

signal sio_command_kind       : t_sio_command_kind := SIO_COMMAND_NONE;

signal sio_rx_index           : integer range 0 to 5 := 0;
signal sio_cmd_pos_ok         : std_logic := '1';
signal sio_collecting         : std_logic := '0';

signal sio_rx_divisor         : std_logic_vector(7 downto 0) := (others => '0');

signal sio_delay_count        : integer range 0 to 40000 := 0;
signal sio_settle_count       : integer range 0 to 15 := 0;

signal sio_tx_byte            : std_logic_vector(7 downto 0) := (others => '0');

signal sio_status_byte0       : std_logic_vector(7 downto 0) := (others => '0');
signal sio_status_index       : integer range 0 to 4 := 0;

signal sio_read_index         : unsigned(9 downto 0) := (others => '0');
signal sio_read_length        : unsigned(9 downto 0) := (others => '0');
signal sio_read_checksum      : std_logic_vector(7 downto 0) := (others => '0');
signal sio_read_failed        : std_logic := '0';

signal sio_status_seen        : std_logic := '0';
signal sio_read_seen          : std_logic := '0';
signal sio_drive_activity     : std_logic := '0';
signal sio_state_debug        : std_logic_vector(4 downto 0);

----------------------------------------------------------------------------
-- Main-clock -> QNICE ATR sector request
----------------------------------------------------------------------------

signal sio_atr_req_toggle_main  : std_logic_vector(0 downto 0) :=
                                  (others => '0');
signal sio_atr_req_toggle_qnice : std_logic_vector(0 downto 0);

signal sio_atr_req_sector_main  : std_logic_vector(23 downto 0) :=
                                  (others => '0');
signal sio_atr_req_sector_qnice : std_logic_vector(23 downto 0);

----------------------------------------------------------------------------
-- QNICE -> main completion
----------------------------------------------------------------------------

signal atr_done_toggle_qnice    : std_logic_vector(0 downto 0) :=
                                  (others => '0');
signal atr_done_toggle_main     : std_logic_vector(0 downto 0);

signal sio_atr_done_seen        : std_logic := '0';

signal atr_result_meta_qnice    : std_logic_vector(10 downto 0);
signal atr_result_meta_main     : std_logic_vector(10 downto 0);

----------------------------------------------------------------------------
-- ATR geometry QNICE -> main
--
-- [40:17] sector count
-- [16:1]  sector size
-- [0]     valid
----------------------------------------------------------------------------

signal atr_meta_qnice           : std_logic_vector(40 downto 0);
signal atr_meta_main            : std_logic_vector(40 downto 0);

signal atr_valid_main           : std_logic;
signal atr_sector_size_main     : unsigned(15 downto 0);
signal atr_sector_count_main    : unsigned(23 downto 0);

signal atr_req_seen_qnice       : std_logic := '0';

signal atr_sector_service_active : std_logic := '0';
signal atr_sector_service_ok     : std_logic := '0';

  

signal vdrives_mounted     : std_logic_vector(G_VDNUM - 1 downto 0);
signal vdrive_mounted_d    : std_logic := '0';
signal disk_change         : std_logic_vector(G_VDNUM - 1 downto 0);
signal cache_dirty         : std_logic_vector(G_VDNUM - 1 downto 0);
signal prevent_reset       : std_logic;

signal reset_core_n        : std_logic := '1';
signal reset_core_int      : std_logic := '0';
signal atr_boot_reset_count: natural range 0 to 65535 := 0;

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

signal pokeymax_config     : std_logic_vector(38 downto 0);

  
type t_atr_test_state is (
    ATR_IDLE,
    ATR_READ_START,
    ATR_WAIT_ACK_HIGH,
    ATR_WAIT_ACK_LOW,
    ATR_CHECK_HEADER,
    ATR_CALC_GEOMETRY,
    ATR_CALC_GEOMETRY_2,

    ATR_SECTOR_CALC,
    ATR_SECTOR_PREP,
    
    ATR_SECTOR_READ1_START,
    ATR_SECTOR_READ1_WAIT_ACK_HIGH,
    ATR_SECTOR_READ1_WAIT_ACK_LOW,
    ATR_SECTOR_COPY1,
    
    ATR_SECTOR_READ2_START,
    ATR_SECTOR_READ2_WAIT_ACK_HIGH,
    ATR_SECTOR_READ2_WAIT_ACK_LOW,
    ATR_SECTOR_COPY2,
    
    ATR_SECTOR_CHECK,
    ATR_SERVICE_COMPLETE,

    ATR_DONE
);

type t_atr_test_buffer is array (0 to 511) of std_logic_vector(7 downto 0);
type t_atr_sector_buffer is array (0 to 511) of std_logic_vector(7 downto 0);
signal atr_sector_buffer    : t_atr_sector_buffer;
signal atr_sector4_ok       : std_logic := '0';

signal atr_sector_number    : unsigned(23 downto 0) := to_unsigned(4, 24);
signal atr_sector_length    : unsigned(9 downto 0)  := (others => '0');

signal atr_byte_offset      : unsigned(31 downto 0) := (others => '0');
signal atr_current_lba      : unsigned(31 downto 0) := (others => '0');
signal atr_lba_offset       : unsigned(8 downto 0)  := (others => '0');

signal atr_first_chunk      : unsigned(9 downto 0)  := (others => '0');
signal atr_remaining        : unsigned(9 downto 0)  := (others => '0');
signal atr_copy_index       : unsigned(9 downto 0)  := (others => '0');

signal atr_sector_ready     : std_logic := '0';

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
   
type t_atr_boot_state is (
    ATR_BOOT_IDLE,
    ATR_BOOT_WRITE_START,
    ATR_BOOT_WRITE_WAIT,
    ATR_BOOT_RESET_ASSERT,
    ATR_BOOT_RESET_RELEASE,
    ATR_BOOT_OPTION_ASSERT,
    ATR_BOOT_OPTION_RELEASE
);

signal atr_boot_state : t_atr_boot_state := ATR_BOOT_IDLE;

signal atari_reset_in       : std_logic;

-- ATR ready event: QNICE -> main clock domain
signal atr_ready_toggle_qnice : std_logic := '0';
signal atr_ready_toggle_main  : std_logic := '0';
signal atr_ready_toggle_d     : std_logic := '0';

signal atr_boot_fill_complete : std_logic := '0';
   

-- kb constants
constant m65_f1            : integer := 4;  -- OPTION
constant m65_f3            : integer := 5;  -- SELECT
constant m65_f5            : integer := 6;  -- START
constant m65_f7            : integer := 3;  -- RESET
constant m65_f9            : integer := 68; -- HELP
constant m65_restore       : integer := 75; -- Pause

function sio_checksum4(
    b0 : std_logic_vector(7 downto 0);
    b1 : std_logic_vector(7 downto 0);
    b2 : std_logic_vector(7 downto 0);
    b3 : std_logic_vector(7 downto 0)
) return std_logic_vector is
    variable sum : unsigned(8 downto 0);
    variable r   : unsigned(7 downto 0);
begin
    r := (others => '0');

    sum := ('0' & r) + unsigned(b0);
    r := sum(7 downto 0);
    if sum(8) = '1' then
        r := r + 1;
    end if;

    sum := ('0' & r) + unsigned(b1);
    r := sum(7 downto 0);
    if sum(8) = '1' then
        r := r + 1;
    end if;

    sum := ('0' & r) + unsigned(b2);
    r := sum(7 downto 0);
    if sum(8) = '1' then
        r := r + 1;
    end if;

    sum := ('0' & r) + unsigned(b3);
    r := sum(7 downto 0);
    if sum(8) = '1' then
        r := r + 1;
    end if;

    return std_logic_vector(r);
end function;

function sio_checksum_add(
   old_sum : std_logic_vector(7 downto 0);
   new_byte : std_logic_vector(7 downto 0)
) return std_logic_vector is

   variable tmp : unsigned(8 downto 0);
   variable res : unsigned(7 downto 0);

begin

   tmp :=
      ('0' & unsigned(old_sum)) +
      ('0' & unsigned(new_byte));

   res := tmp(7 downto 0);

   if tmp(8) = '1' then
      res := res + 1;
   end if;

   return std_logic_vector(res);

end function;

function sio_make_status0(
    readonly     : std_logic;
    sector_count : unsigned(23 downto 0);
    sector_size  : unsigned(15 downto 0)
) return std_logic_vector is
    variable r : unsigned(7 downto 0);
begin

    -- MiSTer normal mounted-drive STATUS:
    -- bit 4 = motor on
    r := x"10";

    -- bit 3 = write protected
    if readonly = '1' then
        r := r or x"08";
    end if;

    if sector_count = 1040 and sector_size = 128 then
        r := r or x"80";
    end if;

    if sector_size = 256 then
        r := r or x"A0";
    end if;

    return std_logic_vector(r);

end function;

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

    video_vs_o       <= atari_vs;
    video_hs_o       <= atari_hs;
    video_red_o      <= atari_r;
    video_green_o    <= atari_g;
    video_blue_o     <= atari_b;
    video_ce_o       <= atari_pixce;
    
    video_hblank_o   <= atari_hblank;
    video_vblank_o   <= atari_vblank;
    
    -- RED: main SIO side is waiting for ATR completion
    atr_sector4_ok_o <= sio_drive_activity;

    atr_header_ok_o        <= atr_valid;
    atr_sector_count_ok_o  <= '1' when
       atr_sector_count /= 0
    else '0';

    
    atr_geometry_o <=
   "01" when atr_sector_size = to_unsigned(128, 16) else
   "10" when atr_sector_size = to_unsigned(256, 16) else
   "11" when atr_sector_size = to_unsigned(512, 16) else
   "00";
   
   
   atr_sector_count_1040_o <=
   '1' when atr_sector_count = to_unsigned(1040, atr_sector_count'length)
   else '0';
   
   atr_sector_count_512_o <=
   '1' when atr_sector_count = to_unsigned(512, atr_sector_count'length)
   else '0';
   
   sio_status_byte0 <=
    sio_make_status0(
        img_readonly,
        atr_sector_count,
        atr_sector_size
    );
    
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
   
   atari_dma_addr_mux <=
    std_logic_vector(resize(atr_boot_dma_addr, 26))
    when atr_boot_dma_active = '1'
    else dma_addr_i;

   atari_dma_req_mux <=
        atr_boot_dma_req
        when atr_boot_dma_active = '1'
        else dma_req_i;
    
   -- cold boot is always writing RAM
   atari_dma_read_mux <=
        '0'
        when atr_boot_dma_active = '1'
        else dma_read_enable_i;
    
   -- MiSTer pattern:
   -- $0000 = FF
   -- $0001 = 00
   -- $0002 = FF
   -- $0003 = 00 ...
   atari_dma_data_mux <=
        x"FF" when atr_boot_dma_active = '1' and atr_boot_dma_addr(0) = '0' else
        x"00" when atr_boot_dma_active = '1' else
        dma_data_i;
   
   atari_reset_in <=
    (not keyboard_n(m65_f7)) or
    xex_reset_i or
    atr_boot_reset;
    
    atari_option_force_in <=
    (not keyboard_n(m65_f1)) or
    atr_boot_option_force;
   
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

      SET_RESET_IN            => atari_reset_in, 
      SET_PAUSE_IN            => not keyboard_n(m65_restore),
      SET_FREEZER_IN          => '0', -- to do
      SET_RESET_RNMI_IN       => '0',
      SET_OPTION_FORCE_IN     => atari_option_force_in,
      SET_SELECT_FORCE_IN     => not keyboard_n(m65_f3),
      SET_START_FORCE_IN      => not keyboard_n(m65_f5),
      SET_HELP_FORCE_IN       => not keyboard_n(m65_f9),
      SET_SPACE_FORCE_IN      => '0', -- not required

      CART1_SELECT_IN         => (others => '0'),
      CART2_SELECT_IN         => (others => '0'),

      EMU_FLASH_REQUEST       => open,
      EMU_FLASH_SLAVE         => open,

      HOT_KEYS                => open,

      UART_ADDR               => sio_uart_addr,
      UART_ENABLE             => sio_uart_enable,
      UART_WR                 => sio_uart_wr,
      UART_DATA_WRITE         => sio_uart_data_write,
      UART_DATA_READ          => uart_data_read,

      TAPE_DATA               => (others => '0'),
      TAPE_DATA_WR            => '0',
      TAPE_FIFO_FULL          => tape_fifo_full,
      TAPE_FIFO_EMPTY         => tape_fifo_empty,
      TAPE_PWM_CONFIG         => "000",
      TAPE_PWM_INVERT         => '0',
      TAPE_RESET              => '0',
      TAPE_ACTIVE             => tape_active,

      HPS_DMA_ADDR            => atari_dma_addr_mux,
      HPS_DMA_REQ             => atari_dma_req_mux,
      HPS_DMA_READ_ENABLE     => atari_dma_read_mux,
      HPS_DMA_DATA_OUT        => atari_dma_data_mux,
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
   
    atr_boot_proc : process(clk_main_i)
    begin
        if rising_edge(clk_main_i) then

            -- defaults
                atr_boot_dma_req      <= '0';
                atr_boot_reset        <= '0';
                atr_boot_option_force <= '0';

            if reset_core_n = '0' then

                atr_boot_state       <= ATR_BOOT_IDLE;
                atr_boot_dma_active  <= '0';
                atr_boot_dma_addr    <= (others => '0');
                atr_boot_reset_count <= 0;
                atr_boot_fill_complete <= '0';
            
                atr_ready_toggle_d <= atr_ready_toggle_main;

            else

                case atr_boot_state is

                    ----------------------------------------------------------
                    -- Wait until ATR parsing/geometry has completed.
                    ----------------------------------------------------------
                    when ATR_BOOT_IDLE =>

                        atr_boot_dma_active <= '0';

                        if atr_ready_toggle_main /= atr_ready_toggle_d and
                           dma_req_i = '0' then

                            atr_ready_toggle_d    <= atr_ready_toggle_main;
                            atr_boot_dma_addr     <= (others => '0');
                            atr_boot_dma_active   <= '1';

                            atr_boot_state <= ATR_BOOT_WRITE_START;

                        end if;


                    ----------------------------------------------------------
                    -- Issue one Atari RAM write.
                    --
                    -- Data comes from atari_dma_data_mux:
                    -- even address = FF
                    -- odd  address = 00
                    ----------------------------------------------------------
                    when ATR_BOOT_WRITE_START =>

                        atr_boot_dma_active <= '1';
                        atr_boot_dma_req    <= '1';
                    
                        atr_boot_state <= ATR_BOOT_WRITE_WAIT;
                    
                    
                    ----------------------------------------------------------
                    -- KEEP request asserted until Atari DMA acknowledges it.
                    ----------------------------------------------------------
                    when ATR_BOOT_WRITE_WAIT =>
                    
                        atr_boot_dma_active <= '1';
                        atr_boot_dma_req    <= '1';
                    
                        if dma_ready = '1' then
                    
                            if atr_boot_dma_addr = x"FFFF" then
                            
                                atr_boot_fill_complete <= '1';
                    
                                -- All 64K has now been initialized.
                                atr_boot_dma_active  <= '0';
                                atr_boot_reset_count <= 0;
                    
                                atr_boot_state <= ATR_BOOT_RESET_ASSERT;
                    
                            else

                                atr_boot_dma_addr <= atr_boot_dma_addr + 1;
                                atr_boot_state <= ATR_BOOT_WRITE_START;
                            
                            end if;

                        end if;

                    ----------------------------------------------------------
                    -- Hold ordinary Atari reset for ~1 ms.
                    ----------------------------------------------------------
                    when ATR_BOOT_RESET_ASSERT =>
                    
                        atr_boot_reset <= '1';
                    
                        if atr_boot_reset_count >= (clk_main_speed_i / 1000) - 1 then
                    
                            atr_boot_reset_count <= 0;
                            atr_boot_state       <= ATR_BOOT_RESET_RELEASE;
                    
                        else
                    
                            atr_boot_reset_count <= atr_boot_reset_count + 1;
                    
                        end if;


                    ----------------------------------------------------------
                    -- Release reset.
                    ----------------------------------------------------------
                    when ATR_BOOT_RESET_RELEASE =>
                    
                        atr_boot_reset <= '0';
                    
                        atr_boot_state <= ATR_BOOT_OPTION_ASSERT;
                    ----------------------------------------------------------
                    -- Match MiSTer's post-cold-reset OPTION force pulse.
                    ----------------------------------------------------------
                    when ATR_BOOT_OPTION_ASSERT =>
                    
                        atr_boot_option_force <= '1';
                    
                        atr_boot_state <= ATR_BOOT_OPTION_RELEASE;
                        
                    when ATR_BOOT_OPTION_RELEASE =>

                        atr_boot_option_force <= '0';
                    
                        atr_boot_state <= ATR_BOOT_IDLE;   

                  end case;

            end if;

        end if;
    end process;
   
    sio_controller_proc : process(clk_main_i)
       variable status_tmp : unsigned(7 downto 0);
       variable sector_tmp : unsigned(23 downto 0);
    begin
    
       if rising_edge(clk_main_i) then
    
          ---------------------------------------------------------------
          -- UART controls are strobes.
          ---------------------------------------------------------------
    
          sio_uart_enable <= '0';
          sio_uart_wr     <= '0';
    
    
          if reset_core_n = '0' then
             sio_state            <= SIO_IDLE;
             sio_tx_return_state  <= SIO_IDLE;
    
             sio_uart_addr        <= (others => '0');
             sio_uart_data_write  <= (others => '0');
    
             sio_rx_index         <= 0;
             sio_cmd_pos_ok       <= '1';
             sio_collecting       <= '0';
    
             sio_rx_divisor       <= (others => '0');
    
             sio_command_kind     <= SIO_COMMAND_NONE;
    
             sio_delay_count      <= 0;
             sio_settle_count     <= 0;
    
             sio_tx_byte          <= (others => '0');
    
             sio_status_index     <= 0;  
             sio_read_index       <= (others => '0');
             sio_read_length      <= (others => '0');
             sio_read_checksum    <= (others => '0');
             sio_read_failed      <= '0';
    
             sio_status_seen      <= '0';
             sio_read_seen        <= '0';
             sio_drive_activity   <= '0';
    
             sio_cmd_bytes        <= (others => (others => '0'));
    
             sio_atr_req_toggle_main <= (others => '0');
             sio_atr_req_sector_main <= (others => '0');
    
             sio_atr_done_seen    <= '0';
    
    
          else
             case sio_state is
    
                ----------------------------------------------------------
                -- Poll receive FIFO.
                ----------------------------------------------------------
    
                when SIO_IDLE =>
                   sio_drive_activity <= '0';
                
                   sio_uart_addr   <= "00011";
                   sio_uart_enable <= '1';
                
                   sio_state <= SIO_RXSTAT_WAIT;
                    
    
                when SIO_RXSTAT_WAIT =>
                   sio_state <= SIO_RXSTAT_CAPTURE;
    
    
                when SIO_RXSTAT_CAPTURE =>  
                   -- RX empty bit = 0 means at least one entry exists.
                   if uart_data_read(8) = '0' then
                      if sio_collecting = '0' then
    
                         sio_rx_index   <= 0;
                         sio_cmd_pos_ok <= '1';
                         sio_collecting <= '1';
    
                      end if;
    
                      sio_state <= SIO_RX_READ;
    
                   else  
                      sio_state <= SIO_IDLE;
    
                   end if;
    
    
                ----------------------------------------------------------
                -- Consume one RX FIFO entry.
                ----------------------------------------------------------
    
                when SIO_RX_READ =>  
                   sio_uart_addr   <= "00010";
                   sio_uart_enable <= '1';
    
                   sio_state <= SIO_RX_WAIT;
    
    
                when SIO_RX_WAIT =>   
                   sio_state <= SIO_RX_CAPTURE;
    
    
                when SIO_RX_CAPTURE =>    
                   if sio_rx_index <= 4 then
    
                      -- MiSTer expects command numbers 1..5.
                      if unsigned(uart_data_read(14 downto 8)) /=
                         to_unsigned(sio_rx_index + 1, 7) then
    
                         sio_cmd_pos_ok <= '0';
    
                      end if;
    
                      sio_cmd_bytes(sio_rx_index) <=
                         uart_data_read(7 downto 0);
    
                   end if;
    
    
                   if sio_rx_index = 4 then
                      -- We now have the five actual command entries:
                      --
                      --   1 device
                      --   2 command
                      --   3 AUX1
                      --   4 AUX2
                      --   5 checksum
                      --
                      -- Do NOT consume the sixth FIFO entry here.
                      -- That entry is COMMAND-line release and is
                      -- handled explicitly after validation.
                      sio_collecting <= '0';
                      sio_state      <= SIO_VALIDATE;

                   else
                      sio_rx_index <= sio_rx_index + 1;

                      -- Wait until the next command byte exists.
                      sio_state <= SIO_IDLE;

                   end if;
    
    
                ----------------------------------------------------------
                -- Decode one complete SIO command.
                ----------------------------------------------------------
    
                when SIO_VALIDATE =>
                   sio_command_kind <= SIO_COMMAND_NONE;
                   sio_read_failed  <= '0';
                
                   if sio_cmd_pos_ok = '1' and
                
                      sio_checksum4(
                         sio_cmd_bytes(0),
                         sio_cmd_bytes(1),
                         sio_cmd_bytes(2),
                         sio_cmd_bytes(3)
                      ) = sio_cmd_bytes(4) then
                
                
                      ----------------------------------------------------
                      -- We currently emulate D1 only.
                      ----------------------------------------------------
                
                      if sio_cmd_bytes(0) = x"31" then
                
                
                         -------------------------------------------------
                         -- $53 STATUS
                         -------------------------------------------------
                
                         if sio_cmd_bytes(1) = x"53" then

                           if vdrives_mounted(0) = '1' and
                              atr_valid_main = '1' then
                        
                              sio_command_kind <= SIO_COMMAND_STATUS;
                        
                           else
                        
                              sio_command_kind <= SIO_COMMAND_NONE;
                        
                           end if;
                        
                           sio_state <= SIO_CMDREL_STAT_READ;
                
                
                         -------------------------------------------------
                         -- $52 READ
                         --
                         -- AUX1 = low sector byte
                         -- AUX2 = high sector byte
                         -------------------------------------------------
                
                         elsif sio_cmd_bytes(1) = x"52" then

                       ------------------------------------------------
                       -- TEMP DEBUG:
                       -- proves the Atari issued a valid D1 $52,
                       -- regardless of ATR/mount readiness.
                       ------------------------------------------------
                       sio_read_seen <= '1';
                    
                       if vdrives_mounted(0) = '1' and
                          atr_valid_main = '1' then
                    
                          sector_tmp := (others => '0');
                    
                          sector_tmp(7 downto 0) :=
                             unsigned(sio_cmd_bytes(2));
                    
                          sector_tmp(15 downto 8) :=
                             unsigned(sio_cmd_bytes(3));
                    
                          if sector_tmp >= to_unsigned(1, 24) and
                             sector_tmp <= atr_sector_count_main then
                    
                             sio_atr_req_sector_main <=
                                std_logic_vector(sector_tmp);
                    
                             sio_command_kind <= SIO_COMMAND_READ;
                             sio_drive_activity <= '1';
                    
                          else
                    
                             sio_command_kind <= SIO_COMMAND_NAK;
                    
                          end if;
                    
                       else
                    
                          -- We DID receive $52, but the ATR service
                          -- is not ready for it.
                          sio_command_kind <= SIO_COMMAND_NAK;
                    
                       end if;
                    
                        sio_state <= SIO_CMDREL_STAT_READ;         
                         -------------------------------------------------
                         -- Other D1 commands are not implemented.
                         -------------------------------------------------
                
                         else
                            sio_command_kind <= SIO_COMMAND_NAK;
                            sio_state        <= SIO_CMDREL_STAT_READ;
                         end if;
                
                
                      else
                
                         -------------------------------------------------
                         -- Not D1: ignore.
                         -------------------------------------------------               
                         sio_state <= SIO_IDLE;                
                      end if;
                
                
                   else               
                      ----------------------------------------------------
                      -- Bad command framing/checksum: ignore.
                      ----------------------------------------------------
                
                      sio_state <= SIO_IDLE;                
                   end if;
    
                ----------------------------------------------------------
                -- Wait for command-release marker
                ----------------------------------------------------------
             
    
                ----------------------------------------------------------
                -- Wait for COMMAND-line release entry.
                --
                -- sio_handler places one additional RX FIFO entry into
                -- the FIFO when COMMAND rises. The five command entries
                -- have already been consumed and validated above.
                ----------------------------------------------------------

                when SIO_CMDREL_STAT_READ =>
                   sio_uart_addr   <= "00011";
                   sio_uart_enable <= '1';

                   sio_state <= SIO_CMDREL_STAT_WAIT;


                when SIO_CMDREL_STAT_WAIT =>
                   -- Allow registered DATA_OUT to update.
                   sio_state <= SIO_CMDREL_STAT_CAPTURE;


                when SIO_CMDREL_STAT_CAPTURE =>
                   -- RX empty = 0 means the release entry is available.
                   if uart_data_read(8) = '0' then
                      sio_state <= SIO_CMDREL_FETCH;
                   else
                      sio_state <= SIO_CMDREL_STAT_READ;
                   end if;


                when SIO_CMDREL_FETCH =>
                   -- Consume the COMMAND-release FIFO entry.
                   sio_uart_addr   <= "00010";
                   sio_uart_enable <= '1';

                   sio_state <= SIO_CMDREL_FETCH_WAIT;


                when SIO_CMDREL_FETCH_WAIT =>
                   -- Allow registered DATA_OUT to update.
                   sio_state <= SIO_CMDREL_CAPTURE;


                when SIO_CMDREL_CAPTURE =>
                   -- Release entry has now been consumed.
                
                   if sio_command_kind = SIO_COMMAND_NONE then
                      -- No disk mounted: ignore the command completely.
                      sio_state <= SIO_IDLE;
                   else
                      sio_state <= SIO_DIV_READ;
                   end if;


                ----------------------------------------------------------
                -- Read measured RX divisor.
                ----------------------------------------------------------

                when SIO_DIV_READ =>   
                   sio_uart_addr   <= "00100";
                   sio_uart_enable <= '1';   
                   sio_state <= SIO_DIV_WAIT;
    
    
                when SIO_DIV_WAIT =>  
                   sio_state <= SIO_DIV_CAPTURE;
    
    
                when SIO_DIV_CAPTURE =>   
                   sio_rx_divisor <= uart_data_read(7 downto 0);   
                   sio_state <= SIO_DIV_WRITE;
    
    
                ----------------------------------------------------------
                -- MiSTer uart_switch():
                --
                -- TX divisor = measured RX divisor - 1
                ----------------------------------------------------------
    
                when SIO_DIV_WRITE => 
                   sio_uart_addr <= "00100";
                   if sio_rx_divisor = x"00" then   
                      sio_uart_data_write <= x"FF";   
                   else    
                      sio_uart_data_write <=
                         std_logic_vector(
                            unsigned(sio_rx_divisor) - 1
                         );
    
                   end if;
    
                   sio_uart_wr <= '1';   
                   sio_delay_count <= 0;
                   sio_state       <= SIO_DELAY_ACK;
    
    
                ----------------------------------------------------------
                -- 100us before ACK / NAK.
                ----------------------------------------------------------
    
                when SIO_DELAY_ACK =>

                   if sio_delay_count = 5399 then
                
                      sio_delay_count <= 0;
                
                      if sio_command_kind = SIO_COMMAND_NAK then
                
                         sio_tx_byte         <= x"4E"; -- 'N'
                         sio_tx_return_state <= SIO_IDLE;
                
                      else
                
                         sio_tx_byte         <= x"41"; -- 'A'
                         sio_tx_return_state <= SIO_AFTER_ACK;
                
                      end if;
                
                      sio_state <= SIO_TXSTAT_READ;
                
                   else
                
                      sio_delay_count <= sio_delay_count + 1;
                
                   end if;
    
    
                ----------------------------------------------------------
                -- ACK has entered the TX FIFO.
                ----------------------------------------------------------
    
                when SIO_AFTER_ACK =>
                   if sio_command_kind = SIO_COMMAND_STATUS then
    
                      sio_delay_count <= 0;
                      sio_state       <= SIO_DELAY_COMPLETE;
    
    
                   elsif sio_command_kind = SIO_COMMAND_READ then
					   -- Establish completion baseline before launching this request.
					   sio_atr_done_seen <= atr_done_toggle_main(0);

					   sio_atr_req_toggle_main(0) <=
						  not sio_atr_req_toggle_main(0);
					   sio_state <= SIO_ATR_WAIT;
                   else
                      sio_state <= SIO_IDLE;
                   end if;
    
    
                ----------------------------------------------------------
                -- Wait for QNICE sector reader completion.
                ----------------------------------------------------------
    
                when SIO_ATR_WAIT =>
                   if atr_done_toggle_main(0) /=
                      sio_atr_done_seen then
    
                      sio_atr_done_seen <=
                         atr_done_toggle_main(0);
    
                      -- Give result metadata several main clocks to
                      -- settle after the completion-toggle CDC.
                      sio_settle_count <= 0;
                      sio_state        <= SIO_ATR_SETTLE;
    
                   end if;
    
    
                when SIO_ATR_SETTLE =>
                   if sio_settle_count = 7 then
                      sio_settle_count <= 0;
                      if atr_result_meta_main(10) = '1' then
                         sio_read_length <=
                            unsigned(atr_result_meta_main(9 downto 0));
                         sio_read_failed <= '0';
                      else
                         sio_read_length <= (others => '0');
                         sio_read_failed <= '1';
                      end if;
                      sio_delay_count <= 0;
                      sio_state       <= SIO_DELAY_COMPLETE;
                   else
                      sio_settle_count <= sio_settle_count + 1;
                   end if;
    
    
                ----------------------------------------------------------
                -- 600us before COMPLETE / ERROR.
                ----------------------------------------------------------
    
                when SIO_DELAY_COMPLETE =>

                   if sio_delay_count = 32399 then
                
                      sio_delay_count <= 0;
                
                      if sio_read_failed = '1' then
                         sio_tx_byte <= x"45"; -- 'E'
                      else
                         sio_tx_byte <= x"43"; -- 'C'
                      end if;
                
                      sio_tx_return_state <= SIO_AFTER_COMPLETE;
                      sio_state           <= SIO_TXSTAT_READ;
                
                   else
                
                      sio_delay_count <= sio_delay_count + 1;
                
                   end if;
    
    
                ----------------------------------------------------------
                -- COMPLETE has entered TX FIFO.
                ----------------------------------------------------------
    
                when SIO_AFTER_COMPLETE =>

                   if sio_read_failed = '1' then
                      sio_drive_activity <= '0';
                      sio_state <= SIO_IDLE;
                
                   else
                
                      sio_delay_count <= 0;
                      sio_state       <= SIO_DELAY_DATA;
                
                   end if;
    
    
                ----------------------------------------------------------
                -- 150us before response payload.
                ----------------------------------------------------------
    
                when SIO_DELAY_DATA =>

                   if sio_delay_count = 8099 then
                
                      sio_delay_count <= 0;
                
                      if sio_command_kind = SIO_COMMAND_STATUS then
                
                         sio_status_index <= 0;
                         sio_state        <= SIO_STATUS_SEND;
                
                      else
                
                         sio_read_index    <= (others => '0');
                         sio_read_checksum <= x"00";
                         sio_state         <= SIO_READ_SEND;
                
                      end if;
                
                   else
                
                      sio_delay_count <= sio_delay_count + 1;
                
                   end if;
                    
    
                ----------------------------------------------------------
                -- Send four STATUS bytes + checksum.
                ----------------------------------------------------------
    
                when SIO_STATUS_SEND =>

                   case sio_status_index is
                
                      when 0 =>
                         sio_tx_byte <= sio_status_byte0;
                
                      when 1 =>
                          sio_tx_byte <= x"FF";
                
                      when 2 =>
                         sio_tx_byte <= x"E0";
                
                      when 3 =>
                         sio_tx_byte <= x"00";
                
                      when others =>
                         sio_tx_byte <=
                             sio_checksum4(
                                 sio_status_byte0,
                                 x"FF",
                                 x"E0",
                                 x"00"
                             );
                
                   end case;
                
                   sio_tx_return_state <= SIO_STATUS_SENT;
                   sio_state           <= SIO_TXSTAT_READ;
                
                
                when SIO_STATUS_SENT =>
                
                   if sio_status_index = 4 then
                
                      sio_status_index <= 0;
                      sio_status_seen  <= '1';
                      sio_state        <= SIO_IDLE;
                
                   else
                
                      sio_status_index <= sio_status_index + 1;
                      sio_state        <= SIO_STATUS_SEND;
                
                   end if;
                   
                ----------------------------------------------------------
                -- Send logical ATR sector bytes.
                ----------------------------------------------------------
                
                when SIO_READ_SEND =>
                
                   if sio_read_index < sio_read_length then
                
                      sio_tx_byte <=
                         atr_sector_buffer(
                            to_integer(sio_read_index)
                         );
                
                      sio_tx_return_state <= SIO_READ_SENT;
                      sio_state           <= SIO_TXSTAT_READ;
                
                   else
                
                      -- All payload bytes queued; append Atari checksum.
                      sio_tx_byte <= sio_read_checksum;
                
                      sio_tx_return_state <=
                         SIO_READ_CHECKSUM_SENT;
                
                      sio_state <= SIO_TXSTAT_READ;
                
                   end if;

                when SIO_READ_SENT =>
                   sio_read_checksum <=
                      sio_checksum_add(
                         sio_read_checksum,
                         sio_tx_byte
                      );
    
                   sio_read_index <= sio_read_index + 1;
                   sio_state <= SIO_READ_SEND;
    
    
                when SIO_READ_CHECKSUM_SENT =>    
                   -- This proves a real ATR logical sector has gone:
                   --
                   -- vdrive -> ATR reader -> SIO TX FIFO.
                   sio_read_seen        <= '1';
                   sio_drive_activity   <= '0';
                   sio_state            <= SIO_IDLE;
    
    
                ----------------------------------------------------------
                -- Common UART TX helper.
                --
                -- ADDR1 bit9 = TX FIFO full.
                --
                -- This is mandatory for sector transfers; we cannot just
                -- blast 128/256 bytes into the small sio_handler FIFO.
                ----------------------------------------------------------
    
                when SIO_TXSTAT_READ =>
                   sio_uart_addr   <= "00001";
                   sio_uart_enable <= '1';
                   sio_state <= SIO_TXSTAT_WAIT;
    
                when SIO_TXSTAT_WAIT =>
                   sio_state <= SIO_TXSTAT_CAPTURE;
    
                when SIO_TXSTAT_CAPTURE =>
                   if uart_data_read(9) = '0' then
                      sio_state <= SIO_TX_WRITE;
                   else
                      -- FIFO still full; poll again.
                      sio_state <= SIO_TXSTAT_READ;
                   end if;
        
                when SIO_TX_WRITE =>
                   sio_uart_addr       <= "00000";
                   sio_uart_data_write <= sio_tx_byte;
                   sio_uart_wr         <= '1';
                   sio_state <= sio_tx_return_state;
    
                when others =>
                   sio_state <= SIO_IDLE;
             end case;
          end if;
       end if;
    end process;   
   
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
   
----------------------------------------------------------------------------
-- ATR geometry -> main clock
----------------------------------------------------------------------------

    atr_meta_qnice <=
       std_logic_vector(atr_sector_count) &
       std_logic_vector(atr_sector_size) &
       atr_valid;
    
    i_atr_meta_cdc : xpm_cdc_array_single
    generic map (
       WIDTH => 41
    )
    port map (
       src_clk  => atari_qnice_clk_i,
       src_in   => atr_meta_qnice,
    
       dest_clk => clk_main_i,
       dest_out => atr_meta_main
    );
    
    atr_valid_main        <= atr_meta_main(0);
    atr_sector_size_main  <= unsigned(atr_meta_main(16 downto 1));
    atr_sector_count_main <= unsigned(atr_meta_main(40 downto 17));
    
    
    ----------------------------------------------------------------------------
    -- Requested logical sector -> QNICE
    ----------------------------------------------------------------------------
    
    i_atr_req_sector_cdc : xpm_cdc_array_single
    generic map (
       WIDTH => 24
    )
    port map (
       src_clk  => clk_main_i,
       src_in   => sio_atr_req_sector_main,
    
       dest_clk => atari_qnice_clk_i,
       dest_out => sio_atr_req_sector_qnice
    );
    
    
    i_atr_req_toggle_cdc : xpm_cdc_array_single
    generic map (
       WIDTH => 1
    )
    port map (
       src_clk  => clk_main_i,
       src_in   => sio_atr_req_toggle_main,
    
       dest_clk => atari_qnice_clk_i,
       dest_out => sio_atr_req_toggle_qnice
    );
    
    
    ----------------------------------------------------------------------------
    -- Sector result -> main
    ----------------------------------------------------------------------------
    
    atr_result_meta_qnice <=
       atr_sector_service_ok &
       std_logic_vector(atr_sector_length);
    
    
    i_atr_result_meta_cdc : xpm_cdc_array_single
    generic map (
       WIDTH => 11
    )
    port map (
       src_clk  => atari_qnice_clk_i,
       src_in   => atr_result_meta_qnice,
    
       dest_clk => clk_main_i,
       dest_out => atr_result_meta_main
    );
    
    
    i_atr_done_toggle_cdc : xpm_cdc_array_single
    generic map (
       WIDTH => 1
    )
    port map (
       src_clk  => atari_qnice_clk_i,
       src_in   => atr_done_toggle_qnice,
    
       dest_clk => clk_main_i,
       dest_out => atr_done_toggle_main
    );
   

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
       
    i_atr_ready_cdc : xpm_cdc_single
       port map (
           src_clk  => atari_qnice_clk_i,
           src_in   => atr_ready_toggle_qnice,
           dest_clk => clk_main_i,
           dest_out => atr_ready_toggle_main
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
               atr_sector4_ok  <= '0';
               atr_sector_ready <= '0';
            
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
                  atr_test_buffer(1) = x"02" then atr_valid <= '1';
            
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
               -- Geometry calculations complete.  Delay one QNICE clock
               -- before announcing ATR ready so geometry is committed.
               atr_test_state <= ATR_CALC_GEOMETRY_2;

             when ATR_CALC_GEOMETRY_2 =>
               -- Exactly one ATR-ready event for the cold-boot FSM.
               if atr_valid = '1' then
                  atr_ready_toggle_qnice <= not atr_ready_toggle_qnice;
               end if;
               atr_test_state <= ATR_DONE;
            -------------------------------------------------------
            -- Test logical ATR sector 4.
            --
            -- 128-byte ATR:
            --
            -- sector 4 starts at file byte 400.
            --
            -- LBA 0 supplies bytes 400..511 = 112 bytes.
            -------------------------------------------------------
            -------------------------------------------------------
            -- Calculate ATR file byte offset and logical length.
            -------------------------------------------------------
            when ATR_SECTOR_CALC =>
               atr_sector_ready <= '0';
               atr_copy_index   <= (others => '0');
            
               -- Reject sector zero or anything past the image geometry.
               if atr_sector_number = 0 or
                   atr_sector_number > atr_sector_count then
                
                   atr_sector_service_ok <= '0';
                   atr_test_state        <= ATR_SERVICE_COMPLETE;
            
               elsif atr_sector_size = to_unsigned(512, 16) then
            
                  -------------------------------------------------
                  -- 512-byte ATR sectors:
                  --
                  -- offset = 16 + (sector - 1) * 512
                  -------------------------------------------------
                  atr_sector_length <= to_unsigned(512, atr_sector_length'length);
            
                  atr_byte_offset <=
                     to_unsigned(16, atr_byte_offset'length) +
                     shift_left(
                        resize(
                           atr_sector_number - 1,
                           atr_byte_offset'length
                        ),
                        9
                     );
            
                  atr_test_state <= ATR_SECTOR_PREP;
            
               elsif atr_sector_number <= 3 then
            
                  -------------------------------------------------
                  -- For ordinary ATRs, sectors 1..3 are always
                  -- stored as 128 bytes.
                  --
                  -- offset = 16 + (sector - 1) * 128
                  -------------------------------------------------
                  atr_sector_length <= to_unsigned(128, atr_sector_length'length);
            
                  atr_byte_offset <=
                     to_unsigned(16, atr_byte_offset'length) +
                     shift_left(
                        resize(
                           atr_sector_number - 1,
                           atr_byte_offset'length
                        ),
                        7
                     );
            
                  atr_test_state <= ATR_SECTOR_PREP;
            
               elsif atr_sector_size = to_unsigned(256, 16) then
            
                  -------------------------------------------------
                  -- Sectors 4+ in a 256-byte ATR:
                  --
                  -- offset = 16 + 384 + (sector - 4) * 256
                  --        = 400 + (sector - 4) * 256
                  -------------------------------------------------
                  atr_sector_length <= to_unsigned(256, atr_sector_length'length);
            
                  atr_byte_offset <=
                     to_unsigned(400, atr_byte_offset'length) +
                     shift_left(
                        resize(
                           atr_sector_number - 4,
                           atr_byte_offset'length
                        ),
                        8
                     );
            
                  atr_test_state <= ATR_SECTOR_PREP;
            
               elsif atr_sector_size = to_unsigned(128, 16) then
            
                  -------------------------------------------------
                  -- Sectors 4+ in a 128-byte ATR:
                  --
                  -- offset = 400 + (sector - 4) * 128
                  -------------------------------------------------
                  atr_sector_length <= to_unsigned(128, atr_sector_length'length);
            
                  atr_byte_offset <=
                     to_unsigned(400, atr_byte_offset'length) +
                     shift_left(
                        resize(
                           atr_sector_number - 4,
                           atr_byte_offset'length
                        ),
                        7
                     );
            
                  atr_test_state <= ATR_SECTOR_PREP;
            
               else
            
                  atr_sector_service_ok <= '0';
                  atr_test_state <= ATR_SERVICE_COMPLETE;
            
               end if;
            
            
            -------------------------------------------------------
            -- Convert byte offset into:
            --
            --   LBA
            --   offset within 512-byte block
            --   first chunk size
            --   remaining bytes
            -------------------------------------------------------
            when ATR_SECTOR_PREP =>
               atr_current_lba <= shift_right(atr_byte_offset, 9);
               atr_lba_offset  <= atr_byte_offset(8 downto 0);
            
               if atr_sector_length <=
                  to_unsigned(512, atr_sector_length'length) -
                  resize(unsigned(atr_byte_offset(8 downto 0)),
                         atr_sector_length'length) then
            
                  atr_first_chunk <= atr_sector_length;
                  atr_remaining   <= (others => '0');
            
               else
            
                  atr_first_chunk <=
                     to_unsigned(512, atr_first_chunk'length) -
                     resize(unsigned(atr_byte_offset(8 downto 0)),
                            atr_first_chunk'length);
            
                  atr_remaining <=
                     atr_sector_length -
                     (
                        to_unsigned(512, atr_sector_length'length) -
                        resize(unsigned(atr_byte_offset(8 downto 0)),
                               atr_sector_length'length)
                     );
            
               end if;
            
               atr_copy_index <= (others => '0');
               atr_test_state <= ATR_SECTOR_READ1_START;

            -------------------------------------------------------
            -- Read first 512-byte LBA.
            -------------------------------------------------------
            when ATR_SECTOR_READ1_START =>
            
               sd_lba(0)     <= std_logic_vector(atr_current_lba);
               sd_blk_cnt(0) <= "000000";
               sd_rd(0)      <= '1';
            
               atr_test_state <= ATR_SECTOR_READ1_WAIT_ACK_HIGH;
            
            
            when ATR_SECTOR_READ1_WAIT_ACK_HIGH =>
               if sd_ack(0) = '1' then
                  sd_rd(0) <= '0';
                  atr_test_state <= ATR_SECTOR_READ1_WAIT_ACK_LOW;
               end if;

            when ATR_SECTOR_READ1_WAIT_ACK_LOW =>
               if sd_ack(0) = '0' then
                  atr_copy_index <= (others => '0');
                  atr_test_state <= ATR_SECTOR_COPY1;
               end if;

            -------------------------------------------------------
            -- Copy first piece, one byte per QNICE clock.
            -------------------------------------------------------
            when ATR_SECTOR_COPY1 =>
               if atr_copy_index < atr_first_chunk then
            
                  atr_sector_buffer(to_integer(atr_copy_index)) <=
                     atr_test_buffer(
                        to_integer(unsigned(atr_lba_offset)) +
                        to_integer(atr_copy_index)
                     );
            
                  atr_copy_index <= atr_copy_index + 1;
               else
            
                  atr_copy_index <= (others => '0');
            
                  if atr_remaining = 0 then
                     atr_sector_ready <= '1';
                     atr_test_state   <= ATR_SECTOR_CHECK;
                  else
                     atr_current_lba <= atr_current_lba + 1;
                     atr_test_state  <= ATR_SECTOR_READ2_START;
                  end if;
               end if;

            -------------------------------------------------------
            -- Read second LBA when the logical sector crosses
            -- a 512-byte vdrive boundary.
            -------------------------------------------------------
            when ATR_SECTOR_READ2_START =>
               sd_lba(0)     <= std_logic_vector(atr_current_lba);
               sd_blk_cnt(0) <= "000000";
               sd_rd(0)      <= '1';
               atr_test_state <= ATR_SECTOR_READ2_WAIT_ACK_HIGH;
            
            
            when ATR_SECTOR_READ2_WAIT_ACK_HIGH =>
               if sd_ack(0) = '1' then
                  sd_rd(0) <= '0';
                  atr_test_state <= ATR_SECTOR_READ2_WAIT_ACK_LOW;
               end if;
            
            
            when ATR_SECTOR_READ2_WAIT_ACK_LOW =>
               if sd_ack(0) = '0' then
                  atr_copy_index <= (others => '0');
                  atr_test_state <= ATR_SECTOR_COPY2;
               end if;
            
            
            -------------------------------------------------------
            -- Copy remaining bytes from start of second LBA.
            -------------------------------------------------------
            when ATR_SECTOR_COPY2 =>
               if atr_copy_index < atr_remaining then
            
                  atr_sector_buffer(
                     to_integer(atr_first_chunk + atr_copy_index)
                  ) <= atr_test_buffer(to_integer(atr_copy_index));
            
                  atr_copy_index <= atr_copy_index + 1;
            
               else
            
                  atr_sector_ready <= '1';
                  atr_test_state   <= ATR_SECTOR_CHECK;
            
               end if;
            
            
            -------------------------------------------------------
            -- Temporary hardware validation only.
            --
            -- Reader itself is now generic; this comparator is
            -- still checking Terminator sector 4.
            -------------------------------------------------------
            when ATR_SECTOR_CHECK =>
               -------------------------------------------------------
               -- Sector has been completely reconstructed in
               -- atr_sector_buffer.
               -------------------------------------------------------
            
               if atr_sector_service_active = '1' then
                  atr_sector_service_ok <= '1';
                  atr_test_state        <= ATR_SERVICE_COMPLETE;
               else
                  atr_test_state <= ATR_DONE;
               end if;
            
            
            when ATR_SERVICE_COMPLETE =>
               -------------------------------------------------------
               -- Result metadata and the sector buffer were made
               -- stable in the previous QNICE state.
               --
               -- Toggle completion only now, one QNICE clock later.
               -------------------------------------------------------
            
               atr_done_toggle_qnice(0)  <= not atr_done_toggle_qnice(0);
               atr_sector_service_active <= '0';
               atr_test_state <= ATR_DONE;
                         -------------------------------------------------------
                         -- Stay here until another disk-change event
                         -------------------------------------------------------
             when ATR_DONE =>
               sd_rd(0) <= '0';
            
               -------------------------------------------------------
               -- Disk change always wins.
               --
               -- IMPORTANT: still use the safe IDLE path here.
               -- Do not jump directly back to ATR_READ_START.
               -------------------------------------------------------
            
               if disk_change_pending = '1' then atr_test_state <= ATR_IDLE;
            
            
               -------------------------------------------------------
               -- New logical-sector request from the SIO controller.
               -------------------------------------------------------
            
               elsif sio_atr_req_toggle_qnice(0) /=
                     atr_req_seen_qnice then
            
                  atr_req_seen_qnice <=
                     sio_atr_req_toggle_qnice(0);
            
                  if atr_valid = '1' then
            
                     atr_sector_number <=
                        unsigned(sio_atr_req_sector_qnice);
            
                     atr_sector_ready          <= '0';
                     atr_sector_service_ok     <= '0';
                     atr_sector_service_active <= '1';
            
                     atr_test_state <= ATR_SECTOR_CALC;
            
                  else
            
                     atr_sector_service_ok     <= '0';
                     atr_sector_service_active <= '1';
            
                     atr_test_state <= ATR_SERVICE_COMPLETE;
            
                  end if;
                end if;
            end case;
         end if;
      end process atr_vdrive_test;
   
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

