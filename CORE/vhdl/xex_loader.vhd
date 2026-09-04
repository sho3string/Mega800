library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.qnice_csr_pkg.all;


entity xex_loader is
   port (
      -----------------------------------------------------------------------
      -- QNICE interface
      -----------------------------------------------------------------------
      qnice_clk_i       : in  std_logic;
      qnice_rst_i       : in  std_logic;
      qnice_addr_i      : in  std_logic_vector(27 downto 0);
      qnice_data_i      : in  std_logic_vector(15 downto 0);
      qnice_ce_i        : in  std_logic;
      qnice_we_i        : in  std_logic;
      qnice_data_o      : out std_logic_vector(15 downto 0);
      qnice_wait_o      : out std_logic;

      -----------------------------------------------------------------------
      -- Atari DMA interface
      -----------------------------------------------------------------------
      dma_addr_o        : out std_logic_vector(25 downto 0);
      dma_data_o        : out std_logic_vector(7 downto 0);
      dma_read_o        : out std_logic;
      dma_req_toggle_o  : out std_logic;

      dma_ack_toggle_i  : in  std_logic;
      dma_readback_i    : in  std_logic_vector(7 downto 0);

      -----------------------------------------------------------------------
      -- Atari XEX loader control
      --
      -- core_reset_o is an Atari internal reset request. Route it to
      -- atari800top.SET_RESET_IN through main.vhd, NOT to reset_soft_i.
      -----------------------------------------------------------------------
      xex_loader_mode_o : out std_logic;
      core_reset_o      : out std_logic;
      core_pause_o      : out std_logic
   );
end entity xex_loader;


architecture beh of xex_loader is

   ---------------------------------------------------------------------------
   -- Official M2M CSR
   ---------------------------------------------------------------------------

   signal qnice_req_status : std_logic_vector(3 downto 0);
   signal qnice_req_length : std_logic_vector(22 downto 0);

   signal qnice_csr_data : std_logic_vector(15 downto 0);
   signal qnice_csr_wait : std_logic;
   signal qnice_csr      : std_logic;

   -- Registered WAIT for streamed file data.  A stream transaction is only
   -- released after the clocked controller has actually consumed it (or,
   -- for payload data, after its Atari DMA write has completed).
   signal qnice_wait_reg : std_logic := '1';

   signal qnice_resp_status : std_logic_vector(3 downto 0)
                              := C_CSR_RESP_IDLE;

   signal qnice_resp_error : std_logic_vector(3 downto 0)
                             := (others => '0');

   signal qnice_resp_address : std_logic_vector(22 downto 0)
                               := (others => '0');

   constant C_ERROR_STRINGS : string_vector(0 to 15) := (
       0      => "OK                 \n",
       1      => "Framework error    \n",
       2      => "Bad XEX segment    \n",
       3      => "Unexpected EOF     \n",
       others => "Unknown error      \n"
    );


   ---------------------------------------------------------------------------
   -- Atari-side XEX loader bytes
   --
   -- MiSTer xex_loader.h:
   --
   -- D100 = magic
   -- D101 = loader entry
   -- D10E = host/Atari handshake byte
   ---------------------------------------------------------------------------

   type byte_array_t is array (natural range <>) of
      std_logic_vector(7 downto 0);

   constant C_XEX_LOADER : byte_array_t(0 to 32) := (
      x"61", x"A2", x"00", x"86", x"09", x"CA", x"9A", x"CE",
      x"00", x"D1", x"CE", x"0E", x"D1", x"A9", x"01", x"F0",
      x"FC", x"30", x"09", x"A9", x"D1", x"48", x"A9", x"09",
      x"48", x"6C", x"E2", x"02", x"CE", x"00", x"D1", x"6C",
      x"E0"
   );

   constant C_XEX_MAGIC_ADDR  : unsigned(15 downto 0) := x"D100";
   constant C_XEX_STATUS_ADDR : unsigned(15 downto 0) := x"D10E";

   constant C_INITAD_LO : unsigned(15 downto 0) := x"02E2";
   constant C_INITAD_HI : unsigned(15 downto 0) := x"02E3";

   constant C_RUNAD_LO  : unsigned(15 downto 0) := x"02E0";
   constant C_RUNAD_HI  : unsigned(15 downto 0) := x"02E1";


   ---------------------------------------------------------------------------
   -- State machine
   ---------------------------------------------------------------------------

   type state_t is (
      IDLE_ST,

      START_XEX_ST,
      RESET_HOLD_ST,
      MODE_SETTLE_ST,

      INSTALL_LOADER_ST,
      INSTALL_LOADER_NEXT_ST,

      INSTALL_FIXED_ST,
      INSTALL_FIXED_NEXT_ST,

      RELEASE_ATARI_ST,

      POLL_MAGIC_REQ_ST,
      POLL_MAGIC_CHECK_ST,
      POLL_STATUS_REQ_ST,
      POLL_STATUS_CHECK_ST,

      WORD_LO_ST,
      WORD_HI_ST,
      END_LO_ST,
      END_HI_ST,

      PREP_BLOCK_ST,
      PREP_BLOCK_NEXT_ST,

      PAYLOAD_ST,
      PAYLOAD_COMPLETE_ST,

      RELEASE_BLOCK_ST,

      WAIT_NEXT_MAGIC_REQ_ST,
      WAIT_NEXT_MAGIC_CHECK_ST,
      WAIT_NEXT_STATUS_REQ_ST,
      WAIT_NEXT_STATUS_CHECK_ST,

      EOF_ST,
      EOF_COMPLETE_ST,

      DMA_WAIT_ST,
      STREAM_RELEASE_ST,

      DONE_ST,
      ERROR_ST
   );

   signal state            : state_t := IDLE_ST;
   signal dma_return_state : state_t := IDLE_ST;
   signal stream_return_state : state_t := IDLE_ST;


   ---------------------------------------------------------------------------
   -- Parser registers
   ---------------------------------------------------------------------------

   signal word_lo : std_logic_vector(7 downto 0)
                    := (others => '0');

   signal xex_start_addr : unsigned(15 downto 0)
                           := (others => '0');

   signal xex_end_addr : unsigned(15 downto 0)
                         := (others => '0');

   signal xex_write_addr : unsigned(15 downto 0)
                           := (others => '0');

   signal first_segment : std_logic := '1';

   -- 7-bit, 1-based segment number.  Together with the 16-bit START
   -- address this exactly fills qnice_resp_address(22 downto 0).
   signal segment_index : unsigned(6 downto 0)
                          := to_unsigned(1, 7);

   signal stream_count : unsigned(22 downto 0)
                         := (others => '0');

   -- Address of the last file-stream transaction consumed.  We do not
   -- assume that the first QNICE address is zero; the framework chooses
   -- the 4K window/address.  This is only used to make sure a held QNICE
   -- transaction is consumed exactly once.
   signal last_stream_addr  : std_logic_vector(27 downto 0) := (others => '0');
   signal stream_addr_valid : std_logic := '0';


   ---------------------------------------------------------------------------
   -- Bootstrap/setup indexes
   ---------------------------------------------------------------------------

   signal reset_count      : unsigned(7 downto 0) := (others => '0');
   signal settle_count     : unsigned(4 downto 0) := (others => '0');

   signal loader_index     : integer range 0 to 32 := 0;
   signal fixed_index      : integer range 0 to 11 := 0;
   signal block_prep_index : integer range 0 to 3 := 0;


   ---------------------------------------------------------------------------
   -- DMA registers and ACK CDC
   ---------------------------------------------------------------------------

   signal dma_addr_reg : std_logic_vector(25 downto 0)
                         := (others => '0');

   signal dma_data_reg : std_logic_vector(7 downto 0)
                         := (others => '0');

   signal dma_read_reg : std_logic := '0';

   signal dma_req_toggle_reg : std_logic := '0';

   signal dma_ack_sync1 : std_logic := '0';
   signal dma_ack_sync2 : std_logic := '0';
   signal dma_ack_seen  : std_logic := '0';

   signal dma_readback_reg : std_logic_vector(7 downto 0)
                             := (others => '0');


   ---------------------------------------------------------------------------
   -- Atari controls
   ---------------------------------------------------------------------------

   signal xex_loader_mode : std_logic := '0';
   signal core_reset      : std_logic := '0';
   signal core_pause      : std_logic := '0';


   ---------------------------------------------------------------------------
   -- XL/XE OS preparation
   --
   -- Same values used by MiSTer's XEX path for a normal XL/XE OS:
   --
   -- COLDST    $0244 = $00
   -- GINTLK    $03FA = $00
   -- BASICF    $03F8 = $01
   -- BOOTFLAG  $0009 = $02
   -- CASINI    $0002 = $D101
   -- DOSVEC    $000A = $E471
   -- PUPBT     $033D = $5C,$93,$25
   -- $03ED            = $60
   ---------------------------------------------------------------------------

   function fixed_addr(index : integer) return unsigned is
   begin
      case index is
         when 0  => return to_unsigned(16#0244#, 16);
         when 1  => return to_unsigned(16#03FA#, 16);
         when 2  => return to_unsigned(16#03F8#, 16);
         when 3  => return to_unsigned(16#0009#, 16);
         when 4  => return to_unsigned(16#0002#, 16);
         when 5  => return to_unsigned(16#0003#, 16);
         when 6  => return to_unsigned(16#000A#, 16);
         when 7  => return to_unsigned(16#000B#, 16);
         when 8  => return to_unsigned(16#033D#, 16);
         when 9  => return to_unsigned(16#033E#, 16);
         when 10 => return to_unsigned(16#033F#, 16);
         when others =>
            return to_unsigned(16#03ED#, 16);
      end case;
   end function;


   function fixed_data(index : integer) return std_logic_vector is
   begin
      case index is
         when 0  => return x"00";
         when 1  => return x"00";
         when 2  => return x"01";
         when 3  => return x"02";
         when 4  => return x"01";
         when 5  => return x"D1";
         when 6  => return x"71";
         when 7  => return x"E4";
         when 8  => return x"5C";
         when 9  => return x"93";
         when 10 => return x"25";
         when others =>
            return x"60";
      end case;
   end function;


begin

   ---------------------------------------------------------------------------
   -- Official MiSTer2MEGA65 CSR
   ---------------------------------------------------------------------------

   qnice_csr_inst : entity work.qnice_csr
      generic map (
         G_ERROR_STRINGS => C_ERROR_STRINGS
      )
      port map (
         qnice_clk_i          => qnice_clk_i,
         qnice_rst_i          => qnice_rst_i,

         qnice_addr_i         => qnice_addr_i,
         qnice_data_i         => qnice_data_i,
         qnice_ce_i           => qnice_ce_i,
         qnice_we_i           => qnice_we_i,

         qnice_data_o         => qnice_csr_data,
         qnice_wait_o         => qnice_csr_wait,
         qnice_csr_o          => qnice_csr,

         qnice_req_status_o   => qnice_req_status,
         qnice_req_length_o   => qnice_req_length,

         qnice_resp_status_i  => qnice_resp_status,
         qnice_resp_error_i   => qnice_resp_error,
         qnice_resp_address_i => qnice_resp_address
      );


   ---------------------------------------------------------------------------
   -- Outputs
   ---------------------------------------------------------------------------

   dma_addr_o       <= dma_addr_reg;
   dma_data_o       <= dma_data_reg;
   dma_read_o       <= dma_read_reg;
   dma_req_toggle_o <= dma_req_toggle_reg;

   xex_loader_mode_o <= xex_loader_mode;
   core_reset_o      <= core_reset;
   core_pause_o      <= core_pause;


   ---------------------------------------------------------------------------
   -- QNICE bus response / WAIT
   --
   -- CSR accesses keep using qnice_csr's own WAIT response.
   --
   -- File-stream accesses use qnice_wait_reg.  Unlike the old state-derived
   -- combinational WAIT, qnice_wait_reg is only deasserted by qnice_proc after
   -- the pending transaction has actually been consumed.  This prevents a
   -- newly-entered parser state from acknowledging a held byte one clock
   -- before that state's clocked capture logic runs.
   ---------------------------------------------------------------------------

   qnice_bus_comb : process(all)
   begin

      qnice_data_o <= x"0000";
      qnice_wait_o <= '0';

      if qnice_ce_i = '1' then

         if qnice_csr = '1' then

            qnice_data_o <= qnice_csr_data;
            qnice_wait_o <= qnice_csr_wait;

         else

            qnice_data_o <= x"00" & dma_readback_reg;
            qnice_wait_o <= qnice_wait_reg;

         end if;

      end if;

   end process qnice_bus_comb;


   ---------------------------------------------------------------------------
   -- QNICE-domain controller
   ---------------------------------------------------------------------------

   qnice_proc : process(qnice_clk_i)

      variable word_v      : unsigned(15 downto 0);
      variable prep_addr_v : unsigned(15 downto 0);
      variable prep_data_v : std_logic_vector(7 downto 0);

   begin

      if falling_edge(qnice_clk_i) then

         --------------------------------------------------------------------
         -- Synchronize Atari DMA acknowledge
         --------------------------------------------------------------------

         dma_ack_sync1 <= dma_ack_toggle_i;
         dma_ack_sync2 <= dma_ack_sync1;


         --------------------------------------------------------------------
         -- Reset
         --------------------------------------------------------------------

         if qnice_rst_i = '1' then

            state            <= IDLE_ST;
            dma_return_state <= IDLE_ST;
            stream_return_state <= IDLE_ST;

            word_lo <= (others => '0');

            xex_start_addr <= (others => '0');
            xex_end_addr   <= (others => '0');
            xex_write_addr <= (others => '0');

            first_segment <= '1';
            segment_index <= to_unsigned(1, segment_index'length);
            stream_count      <= (others => '0');
            last_stream_addr  <= (others => '0');
            stream_addr_valid <= '0';

            reset_count      <= (others => '0');
            settle_count     <= (others => '0');
            loader_index     <= 0;
            fixed_index      <= 0;
            block_prep_index <= 0;

            dma_addr_reg       <= (others => '0');
            dma_data_reg       <= (others => '0');
            dma_read_reg       <= '0';
            dma_req_toggle_reg <= '0';

            dma_ack_seen     <= '0';
            dma_readback_reg <= (others => '0');

            xex_loader_mode <= '0';
            core_reset      <= '0';
            core_pause      <= '0';

            qnice_resp_status  <= C_CSR_RESP_IDLE;
            qnice_resp_error   <= (others => '0');
            qnice_resp_address <= (others => '0');

            qnice_wait_reg <= '1';


         else

            -- Default to stalling streamed file data.  Individual parser
            -- states release exactly the transaction they have consumed.
            qnice_wait_reg <= '1';

            ----------------------------------------------------------------
            -- Framework explicitly reported an error
            ----------------------------------------------------------------

            if qnice_req_status = C_CSR_REQ_ERR then

               qnice_resp_status <= C_CSR_RESP_ERROR;
               qnice_resp_error  <= x"1";

               core_reset <= '0';
               core_pause <= '0';

               state <= ERROR_ST;


            else

               case state is

                  ----------------------------------------------------------
                  -- Waiting for a new XEX load request
                  ----------------------------------------------------------

                  when IDLE_ST =>

                     qnice_resp_status <= C_CSR_RESP_IDLE;
                     qnice_resp_error  <= (others => '0');

                     core_reset <= '0';
                     core_pause <= '0';

                     -- Non-stream accesses are ready while idle.  As soon as
                     -- a load request begins, re-stall before advertising the
                     -- PARSING response so byte 0 cannot be acknowledged early.
                     qnice_wait_reg <= '0';

                     if qnice_req_status = C_CSR_REQ_LDNG then

                        qnice_wait_reg <= '1';

                        stream_count      <= (others => '0');
                        last_stream_addr  <= (others => '0');
                        stream_addr_valid <= '0';
                        first_segment <= '1';
                        segment_index <= to_unsigned(1, segment_index'length);

                        xex_start_addr <= (others => '0');
                        xex_end_addr   <= (others => '0');
                        xex_write_addr <= (others => '0');

                        -- Align to the current ACK toggle before issuing our
                        -- first DMA transaction of this load.
                        dma_ack_seen <= dma_ack_sync2;

                        qnice_resp_status <= C_CSR_RESP_PARSING;

                        state <= START_XEX_ST;

                     end if;


                  ----------------------------------------------------------
                  -- MiSTer-style XEX startup:
                  -- pause Atari, pulse reset, enable D1xx XEX loader RAM.
                  ----------------------------------------------------------

                  when START_XEX_ST =>

                     core_pause      <= '1';
                     core_reset      <= '1';
                     xex_loader_mode <= '1';

                     reset_count <= (others => '0');

                     state <= RESET_HOLD_ST;


                  ----------------------------------------------------------
                  -- Hold reset long enough to comfortably exceed the core's
                  -- minimum reset pulse requirement.
                  ----------------------------------------------------------

                  when RESET_HOLD_ST =>

                     if reset_count = to_unsigned(127, reset_count'length) then

                        core_reset <= '0';

                        settle_count <= (others => '0');
                        state <= MODE_SETTLE_ST;

                     else

                        reset_count <= reset_count + 1;

                     end if;


                  ----------------------------------------------------------
                  -- Allow XEX_LOADER_MODE CDC to settle in the Atari domain.
                  ----------------------------------------------------------

                  when MODE_SETTLE_ST =>

                     if settle_count = to_unsigned(15, settle_count'length) then

                        loader_index <= 0;
                        state <= INSTALL_LOADER_ST;

                     else

                        settle_count <= settle_count + 1;

                     end if;


                  ----------------------------------------------------------
                  -- Install 33-byte Atari bootstrap at $D100.
                  ----------------------------------------------------------

                  when INSTALL_LOADER_ST =>

                     dma_addr_reg <=
                        "0000000000" &
                        std_logic_vector(
                           C_XEX_MAGIC_ADDR + to_unsigned(loader_index, 16)
                        );

                     dma_data_reg <= C_XEX_LOADER(loader_index);
                     dma_read_reg <= '0';

                     dma_req_toggle_reg <= not dma_req_toggle_reg;

                     dma_return_state <= INSTALL_LOADER_NEXT_ST;
                     state <= DMA_WAIT_ST;


                  when INSTALL_LOADER_NEXT_ST =>

                     if loader_index = 32 then

                        fixed_index <= 0;
                        state <= INSTALL_FIXED_ST;

                     else

                        loader_index <= loader_index + 1;
                        state <= INSTALL_LOADER_ST;

                     end if;


                  ----------------------------------------------------------
                  -- Install Atari OS variables/vectors.
                  ----------------------------------------------------------

                  when INSTALL_FIXED_ST =>

                     dma_addr_reg <=
                        "0000000000" &
                        std_logic_vector(fixed_addr(fixed_index));

                     dma_data_reg <= fixed_data(fixed_index);
                     dma_read_reg <= '0';

                     dma_req_toggle_reg <= not dma_req_toggle_reg;

                     dma_return_state <= INSTALL_FIXED_NEXT_ST;
                     state <= DMA_WAIT_ST;


                  when INSTALL_FIXED_NEXT_ST =>

                     if fixed_index = 11 then

                        state <= RELEASE_ATARI_ST;

                     else

                        fixed_index <= fixed_index + 1;
                        state <= INSTALL_FIXED_ST;

                     end if;


                  ----------------------------------------------------------
                  -- Let the Atari run.
                  --
                  -- CASINI points at $D101.  The Atari-side bootstrap will:
                  --   D100: $61 -> $60
                  --   D10E: $01 -> $00
                  -- and then spin waiting for the host.
                  ----------------------------------------------------------

                  when RELEASE_ATARI_ST =>

                     core_pause <= '0';

                     state <= POLL_MAGIC_REQ_ST;


                  ----------------------------------------------------------
                  -- Wait for bootstrap ready:
                  --    D100 = $60
                  --    D10E = $00
                  ----------------------------------------------------------

                  when POLL_MAGIC_REQ_ST =>

                     dma_addr_reg <=
                        "0000000000" &
                        std_logic_vector(C_XEX_MAGIC_ADDR);

                     dma_data_reg <= (others => '0');
                     dma_read_reg <= '1';

                     dma_req_toggle_reg <= not dma_req_toggle_reg;

                     dma_return_state <= POLL_MAGIC_CHECK_ST;
                     state <= DMA_WAIT_ST;


                  when POLL_MAGIC_CHECK_ST =>

                     if dma_readback_reg = x"60" then
                        state <= POLL_STATUS_REQ_ST;
                     else
                        state <= POLL_MAGIC_REQ_ST;
                     end if;


                  when POLL_STATUS_REQ_ST =>

                     dma_addr_reg <=
                        "0000000000" &
                        std_logic_vector(C_XEX_STATUS_ADDR);

                     dma_data_reg <= (others => '0');
                     dma_read_reg <= '1';

                     dma_req_toggle_reg <= not dma_req_toggle_reg;

                     dma_return_state <= POLL_STATUS_CHECK_ST;
                     state <= DMA_WAIT_ST;


                  when POLL_STATUS_CHECK_ST =>

                     if dma_readback_reg = x"00" then
                        state <= WORD_LO_ST;
                     else
                        state <= POLL_MAGIC_REQ_ST;
                     end if;


                  ----------------------------------------------------------
                  -- Read low byte of marker/start word.
                  --
                  -- At a block boundary the next word is either:
                  --    $FFFF
                  -- or START.
                  --
                  -- EOF is only valid at a block boundary.
                  ----------------------------------------------------------

                  when WORD_LO_ST =>

                     qnice_resp_status <= C_CSR_RESP_PARSING;

                     if qnice_req_status = C_CSR_REQ_OK then

                        state <= EOF_ST;

                     elsif qnice_ce_i = '1' and
                           qnice_csr = '0' and
                           qnice_we_i = '1' and
                           (stream_addr_valid = '0' or
                            qnice_addr_i /= last_stream_addr) then

                        word_lo <= qnice_data_i(7 downto 0);
                        stream_count <= stream_count + 1;
                        last_stream_addr <= qnice_addr_i;
                        stream_addr_valid <= '1';
                        qnice_wait_reg <= '0';
                        state <= WORD_HI_ST;

                     end if;


                  ----------------------------------------------------------
                  -- Read high byte of marker/start word.
                  ----------------------------------------------------------

                  when WORD_HI_ST =>

                     if qnice_req_status = C_CSR_REQ_OK then

                        qnice_resp_status <= C_CSR_RESP_ERROR;
                        qnice_resp_error  <= x"3";
                        state <= ERROR_ST;

                     elsif qnice_ce_i = '1' and
                           qnice_csr = '0' and
                           qnice_we_i = '1' and
                           (stream_addr_valid = '0' or
                            qnice_addr_i /= last_stream_addr) then

                        word_v(7 downto 0)  := unsigned(word_lo);
                        word_v(15 downto 8) := unsigned(qnice_data_i(7 downto 0));

                        stream_count <= stream_count + 1;
                        last_stream_addr <= qnice_addr_i;
                        stream_addr_valid <= '1';
                        qnice_wait_reg <= '0';

                        if word_v = x"FFFF" then
                           state <= WORD_LO_ST;
                        else
                           xex_start_addr <= word_v;
                           state <= END_LO_ST;
                        end if;

                     end if;


                  ----------------------------------------------------------
                  -- Segment END low byte
                  ----------------------------------------------------------

                  when END_LO_ST =>

                     if qnice_req_status = C_CSR_REQ_OK then

                        qnice_resp_status <= C_CSR_RESP_ERROR;
                        qnice_resp_error  <= x"3";
                        state <= ERROR_ST;

                     elsif qnice_ce_i = '1' and
                           qnice_csr = '0' and
                           qnice_we_i = '1' and
                           (stream_addr_valid = '0' or
                            qnice_addr_i /= last_stream_addr) then

                        word_lo <= qnice_data_i(7 downto 0);
                        stream_count <= stream_count + 1;
                        last_stream_addr <= qnice_addr_i;
                        stream_addr_valid <= '1';
                        qnice_wait_reg <= '0';
                        state <= END_HI_ST;

                     end if;


                  ----------------------------------------------------------
                  -- Segment END high byte
                  ----------------------------------------------------------

                  when END_HI_ST =>

                     if qnice_req_status = C_CSR_REQ_OK then

                        qnice_resp_status <= C_CSR_RESP_ERROR;
                        qnice_resp_error  <= x"3";
                        state <= ERROR_ST;

                     elsif qnice_ce_i = '1' and
                           qnice_csr = '0' and
                           qnice_we_i = '1' and
                           (stream_addr_valid = '0' or
                            qnice_addr_i /= last_stream_addr) then

                        word_v(7 downto 0)  := unsigned(word_lo);
                        word_v(15 downto 8) := unsigned(qnice_data_i(7 downto 0));

                        stream_count <= stream_count + 1;
                        last_stream_addr <= qnice_addr_i;
                        stream_addr_valid <= '1';
                        qnice_wait_reg <= '0';

                        if word_v < xex_start_addr then

                           qnice_resp_status <= C_CSR_RESP_ERROR;
                           qnice_resp_error  <= x"2";
                           qnice_resp_address <=
                              std_logic_vector(segment_index) &
                              std_logic_vector(xex_start_addr);
                           state <= ERROR_ST;

                        else

                           xex_end_addr   <= word_v;
                           xex_write_addr <= xex_start_addr;
                           block_prep_index <= 0;
                           state <= PREP_BLOCK_ST;

                        end if;

                     end if;


                  ----------------------------------------------------------
                  -- Before every segment:
                  --
                  -- INITAD = $D100.
                  --
                  -- Before the first segment only:
                  -- RUNAD = first segment START.
                  ----------------------------------------------------------

                  when PREP_BLOCK_ST =>

                     prep_addr_v := C_INITAD_LO;
                     prep_data_v := x"00";

                     case block_prep_index is

                        when 0 =>
                           prep_addr_v := C_INITAD_LO;
                           prep_data_v := x"00";

                        when 1 =>
                           prep_addr_v := C_INITAD_HI;
                           prep_data_v := x"D1";

                        when 2 =>
                           prep_addr_v := C_RUNAD_LO;
                           prep_data_v :=
                              std_logic_vector(xex_start_addr(7 downto 0));

                        when others =>
                           prep_addr_v := C_RUNAD_HI;
                           prep_data_v :=
                              std_logic_vector(xex_start_addr(15 downto 8));

                     end case;

                     dma_addr_reg <=
                        "0000000000" &
                        std_logic_vector(prep_addr_v);

                     dma_data_reg <= prep_data_v;
                     dma_read_reg <= '0';

                     dma_req_toggle_reg <= not dma_req_toggle_reg;

                     dma_return_state <= PREP_BLOCK_NEXT_ST;
                     state <= DMA_WAIT_ST;


                  when PREP_BLOCK_NEXT_ST =>

                     if first_segment = '1' then

                        if block_prep_index = 3 then

                           first_segment <= '0';
                           state <= PAYLOAD_ST;

                        else

                           block_prep_index <= block_prep_index + 1;
                           state <= PREP_BLOCK_ST;

                        end if;

                     else

                        if block_prep_index = 1 then

                           state <= PAYLOAD_ST;

                        else

                           block_prep_index <= block_prep_index + 1;
                           state <= PREP_BLOCK_ST;

                        end if;

                     end if;


                  ----------------------------------------------------------
                  -- Payload byte.
                  --
                  -- QNICE is held in WAIT while the Atari DMA transaction
                  -- completes.
                  ----------------------------------------------------------

                  when PAYLOAD_ST =>

                     if qnice_req_status = C_CSR_REQ_OK then

                        qnice_resp_status <= C_CSR_RESP_ERROR;
                        qnice_resp_error  <= x"3";
                        state <= ERROR_ST;

                     elsif qnice_ce_i = '1' and
                           qnice_csr = '0' and
                           qnice_we_i = '1' and
                           (stream_addr_valid = '0' or
                            qnice_addr_i /= last_stream_addr) then

                        dma_addr_reg <=
                           "0000000000" &
                           std_logic_vector(xex_write_addr);

                        dma_data_reg <= qnice_data_i(7 downto 0);
                        dma_read_reg <= '0';
                        dma_req_toggle_reg <= not dma_req_toggle_reg;

                        stream_count <= stream_count + 1;
                        last_stream_addr <= qnice_addr_i;
                        stream_addr_valid <= '1';

                        dma_return_state <= PAYLOAD_COMPLETE_ST;
                        state <= DMA_WAIT_ST;

                     end if;


                  when PAYLOAD_COMPLETE_ST =>

                     if xex_write_addr = xex_end_addr then

                        segment_index <= segment_index + 1;
                        stream_return_state <= RELEASE_BLOCK_ST;

                     else

                        xex_write_addr <= xex_write_addr + 1;
                        stream_return_state <= PAYLOAD_ST;

                     end if;

                     state <= STREAM_RELEASE_ST;


                  ----------------------------------------------------------
                  -- One complete segment is in Atari RAM.
                  --
                  -- D10E = $01 releases the Atari-side bootstrap.  It jumps
                  -- through INITAD and returns to the bootstrap.
                  ----------------------------------------------------------

                  when RELEASE_BLOCK_ST =>

                     dma_addr_reg <=
                        "0000000000" &
                        std_logic_vector(C_XEX_STATUS_ADDR);

                     dma_data_reg <= x"01";
                     dma_read_reg <= '0';

                     dma_req_toggle_reg <= not dma_req_toggle_reg;

                     dma_return_state <= WAIT_NEXT_MAGIC_REQ_ST;
                     state <= DMA_WAIT_ST;


                  ----------------------------------------------------------
                  -- Wait for INITAD to finish and bootstrap to ask for the
                  -- next segment:
                  --
                  --    D100 = $60
                  --    D10E = $00
                  ----------------------------------------------------------

                  when WAIT_NEXT_MAGIC_REQ_ST =>

                     dma_addr_reg <=
                        "0000000000" &
                        std_logic_vector(C_XEX_MAGIC_ADDR);

                     dma_data_reg <= (others => '0');
                     dma_read_reg <= '1';

                     dma_req_toggle_reg <= not dma_req_toggle_reg;

                     dma_return_state <= WAIT_NEXT_MAGIC_CHECK_ST;
                     state <= DMA_WAIT_ST;


                  when WAIT_NEXT_MAGIC_CHECK_ST =>

                     if dma_readback_reg = x"60" then
                        state <= WAIT_NEXT_STATUS_REQ_ST;
                     else
                        state <= WAIT_NEXT_MAGIC_REQ_ST;
                     end if;


                  when WAIT_NEXT_STATUS_REQ_ST =>

                     dma_addr_reg <=
                        "0000000000" &
                        std_logic_vector(C_XEX_STATUS_ADDR);

                     dma_data_reg <= (others => '0');
                     dma_read_reg <= '1';

                     dma_req_toggle_reg <= not dma_req_toggle_reg;

                     dma_return_state <= WAIT_NEXT_STATUS_CHECK_ST;
                     state <= DMA_WAIT_ST;


                  when WAIT_NEXT_STATUS_CHECK_ST =>

                     if dma_readback_reg = x"00" then
                        state <= WORD_LO_ST;
                     else
                        state <= WAIT_NEXT_MAGIC_REQ_ST;
                     end if;


                  ----------------------------------------------------------
                  -- EOF.
                  --
                  -- D10E = $FF is negative, so the bootstrap takes init_go,
                  -- changes D100 $60->$5F and jumps through RUNAD.
                  ----------------------------------------------------------

                  when EOF_ST =>

                     dma_addr_reg <=
                        "0000000000" &
                        std_logic_vector(C_XEX_STATUS_ADDR);

                     dma_data_reg <= x"FF";
                     dma_read_reg <= '0';

                     dma_req_toggle_reg <= not dma_req_toggle_reg;

                     dma_return_state <= EOF_COMPLETE_ST;
                     state <= DMA_WAIT_ST;


                  when EOF_COMPLETE_ST =>

                     qnice_resp_status <= C_CSR_RESP_READY;
                     state <= DONE_ST;


                  ----------------------------------------------------------
                  -- Generic DMA completion state
                  ----------------------------------------------------------

                  when DMA_WAIT_ST =>

                     if dma_ack_sync2 /= dma_ack_seen then

                        dma_ack_seen <= dma_ack_sync2;
                        dma_readback_reg <= dma_readback_i;

                        state <= dma_return_state;

                     end if;


                  ----------------------------------------------------------
                  -- Release one completed payload transaction.
                  --
                  -- The framework may either drop CE or move directly to the
                  -- next QNICE address.  Both mean that the held byte has
                  -- completed.  The combinational WAIT logic re-stalls a new
                  -- address immediately so the next payload byte cannot run
                  -- ahead while we change state.
                  ----------------------------------------------------------

                  when STREAM_RELEASE_ST =>

                     -- The payload byte has already completed its Atari DMA
                     -- transaction before we enter this state.  Release only
                     -- that held QNICE write.  Once QNICE drops CE or advances
                     -- to the next address, WAIT returns high and the parser
                     -- moves on to its saved return state.
                     if qnice_ce_i = '1' and
                        qnice_csr = '0' and
                        qnice_we_i = '1' and
                        stream_addr_valid = '1' and
                        qnice_addr_i = last_stream_addr then

                        qnice_wait_reg <= '0';

                     elsif qnice_ce_i = '0' or
                           qnice_addr_i /= last_stream_addr then

                        state <= stream_return_state;

                     end if;


                  ----------------------------------------------------------
                  -- File parsed / handed to Atari
                  ----------------------------------------------------------

                  when DONE_ST =>

                     qnice_wait_reg <= '0';

                     qnice_resp_status <= C_CSR_RESP_READY;

                     if qnice_req_status = C_CSR_REQ_IDLE then

                        qnice_resp_status <= C_CSR_RESP_IDLE;
                        qnice_resp_error  <= (others => '0');

                        state <= IDLE_ST;

                     end if;


                  ----------------------------------------------------------
                  -- Parse / transfer failure
                  ----------------------------------------------------------

                  when ERROR_ST =>

                     qnice_wait_reg <= '0';

                     qnice_resp_status <= C_CSR_RESP_ERROR;

                     core_reset <= '0';
                     core_pause <= '0';

                     if qnice_req_status = C_CSR_REQ_IDLE then

                        qnice_resp_status <= C_CSR_RESP_IDLE;
                        qnice_resp_error  <= (others => '0');

                        state <= IDLE_ST;

                     end if;

               end case;

            end if;

         end if;

      end if;

   end process qnice_proc;

end architecture beh;
