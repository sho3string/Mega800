-------------------------------------------------------------------------------------------------------------
-- MiSTer2MEGA65 Framework
--
-- Clock Generator using the Xilinx specific MMCME2_ADV
--
-- Atari 800 clocks:
--
--   Input:     100.000000 MHz
--
--   VCO:      1260.000000 MHz
--
--   Main:       28.636364 MHz   (VCO / 44)
--   Memory:    114.545455 MHz   (VCO / 11)
--   Video:      57.272727 MHz   (VCO / 22)
--
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
-------------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

library unisim;
use unisim.vcomponents.all;

library xpm;
use xpm.vcomponents.all;

entity clk is
   port (
      sys_clk_i       : in  std_logic;   -- 100 MHz

      main_clk_o      : out std_logic;   -- 28.636364 MHz
      main_rst_o      : out std_logic;   -- reset synchronized to main clock
      
      mem_clk_o       : out std_logic;   -- 114.545455 MHz
      mem_rst_o       : out std_logic;
      
      video_clk_o     : out std_logic;   -- 57.272727 MHz
      video_rst_o     : out std_logic

   );
end entity clk;

architecture rtl of clk is

signal clkfb_mmcm          : std_logic;
signal clkfb               : std_logic;

signal main_clk_mmcm       : std_logic;
signal mem_clk_mmcm        : std_logic;
signal video_clk_mmcm      : std_logic;

signal main_locked         : std_logic;

begin

   -------------------------------------------------------------------------------------
   -- Atari 800 clocks
   --
   -- Input        = 100 MHz
   -- DIVCLK       = 5
   -- MULT         = 63
   --
   -- VCO          = (100 / 5) * 63
   --              = 1260 MHz
   --
   -- CLKOUT0      = 1260 / 44 = 28.6363636 MHz
   -- CLKOUT1      = 1260 / 11 = 114.5454545 MHz
   -- CLKOUT2      = 1260 / 22 = 57.2727273 MHz
   
   -- BOARD_CLK_SPEED  = 100,000,000 Hz
   -- CORE_CLK_SPEED   =  28,636,364 Hz

   -- MMCM VCO         = 1,260 MHz

   -- main_clk_o       =  28.6363636 MHz
   -- video_clk_o      =  57.2727273 MHz
   -- mem_clk_o        = 114.5454545 MHz
   -------------------------------------------------------------------------------------

   i_clk_main : MMCME2_ADV
      generic map (
         BANDWIDTH            => "OPTIMIZED",
         CLKOUT4_CASCADE      => FALSE,
         COMPENSATION         => "ZHOLD",
         STARTUP_WAIT         => FALSE,

         CLKIN1_PERIOD        => 10.000,       -- 100 MHz
         REF_JITTER1          => 0.010,

         DIVCLK_DIVIDE        => 5,
         CLKFBOUT_MULT_F      => 63.000,       -- 1260 MHz VCO
         CLKFBOUT_PHASE       => 0.000,
         CLKFBOUT_USE_FINE_PS => FALSE,

         -- 28.6363636 MHz
         CLKOUT0_DIVIDE_F     => 44.000,
         CLKOUT0_PHASE        => 0.000,
         CLKOUT0_DUTY_CYCLE   => 0.500,
         CLKOUT0_USE_FINE_PS  => FALSE,

         -- 114.5454545 MHz
         CLKOUT1_DIVIDE       => 11,
         CLKOUT1_PHASE        => 0.000,
         CLKOUT1_DUTY_CYCLE   => 0.500,
         CLKOUT1_USE_FINE_PS  => FALSE,

         -- 57.2727273 MHz
         CLKOUT2_DIVIDE       => 22,
         CLKOUT2_PHASE        => 0.000,
         CLKOUT2_DUTY_CYCLE   => 0.500,
         CLKOUT2_USE_FINE_PS  => FALSE
      )
      port map (
         -- Output clocks
         CLKFBOUT            => clkfb_mmcm,

         CLKOUT0             => main_clk_mmcm,
         CLKOUT1             => mem_clk_mmcm,
         CLKOUT2             => video_clk_mmcm,

         CLKOUT0B            => open,
         CLKOUT1B            => open,
         CLKOUT2B            => open,
         CLKOUT3             => open,
         CLKOUT3B            => open,
         CLKOUT4             => open,
         CLKOUT5             => open,
         CLKOUT6             => open,

         -- Input clock control
         CLKFBIN             => clkfb,
         CLKIN1              => sys_clk_i,
         CLKIN2              => '0',
         CLKINSEL            => '1',

         -- Dynamic reconfiguration
         DADDR               => (others => '0'),
         DCLK                => '0',
         DEN                 => '0',
         DI                  => (others => '0'),
         DO                  => open,
         DRDY                => open,
         DWE                 => '0',

         -- Dynamic phase shift
         PSCLK               => '0',
         PSEN                => '0',
         PSINCDEC            => '0',
         PSDONE              => open,

         -- Status/control
         LOCKED              => main_locked,
         CLKINSTOPPED        => open,
         CLKFBSTOPPED        => open,
         PWRDWN              => '0',
         RST                 => '0'
      );

   -------------------------------------------------------------------------------------
   -- Output buffering
   -------------------------------------------------------------------------------------

   clkfb_bufg : BUFG
      port map (
         I => clkfb_mmcm,
         O => clkfb
      );

   main_clk_bufg : BUFG
      port map (
         I => main_clk_mmcm,
         O => main_clk_o
      );

   mem_clk_bufg : BUFG
      port map (
         I => mem_clk_mmcm,
         O => mem_clk_o
      );

   video_clk_bufg : BUFG
      port map (
         I => video_clk_mmcm,
         O => video_clk_o
      );

   -------------------------------------------------------------------------------------
   -- Reset generation
   -------------------------------------------------------------------------------------

   i_xpm_cdc_async_rst_main : xpm_cdc_async_rst
      generic map (
         RST_ACTIVE_HIGH => 1,
         DEST_SYNC_FF    => 6
      )
      port map (
         src_arst  => not main_locked,
         dest_clk  => main_clk_o,
         dest_arst => main_rst_o
      );
      
    i_xpm_cdc_async_rst_mem : xpm_cdc_async_rst
       generic map (
          RST_ACTIVE_HIGH => 1,
          DEST_SYNC_FF    => 6
       )
       port map (
          src_arst  => not main_locked,
          dest_clk  => mem_clk_o,
          dest_arst => mem_rst_o
       );
      
    i_xpm_cdc_async_rst_video : xpm_cdc_async_rst
       generic map (
          RST_ACTIVE_HIGH => 1,
          DEST_SYNC_FF    => 6
       )
       port map (
          src_arst  => not main_locked,
          dest_clk  => video_clk_o,
          dest_arst => video_rst_o
       );

end architecture rtl;