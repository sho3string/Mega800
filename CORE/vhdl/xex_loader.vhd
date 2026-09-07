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
   
   constant C_XEX_LOADER : byte_array_t(0 to 33) := (
   x"61", x"A2", x"00", x"86", x"09", x"CA", x"9A", x"CE",
   x"00", x"D1", x"CE", x"0E", x"D1", x"A9", x"01", x"F0",
   x"FC", x"30", x"09", x"A9", x"D1", x"48", x"A9", x"09",
   x"48", x"6C", x"E2", x"02", x"CE", x"00", x"D1", x"6C",
   x"E0", x"02"
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

      CLEAR_RAM_ST,
      CLEAR_RAM_NEXT_ST,
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

      TAIL_VALIDATE_WORD_LO_ST,
      TAIL_VALIDATE_WORD_HI_ST,
      TAIL_VALIDATE_END_LO_ST,
      TAIL_VALIDATE_END_HI_ST,
      TAIL_VALIDATE_PAYLOAD_ST,

      TAIL_WAIT_MAGIC_REQ_ST,
      TAIL_WAIT_MAGIC_CHECK_ST,
      TAIL_WAIT_STATUS_REQ_ST,
      TAIL_WAIT_STATUS_CHECK_ST,

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
   -- Pending stream FIFO
   --
   -- While an Atari INIT routine is running, keep accepting QNICE file bytes
   -- instead of stalling the host stream. If INIT returns, these bytes are
   -- replayed through the normal parser. If physical EOF arrives while INIT
   -- never returns, the buffered tail is no longer needed and EOF can finish.
   ---------------------------------------------------------------------------

   constant C_TAIL_FIFO_DEPTH : natural := 1024;

   type tail_fifo_t is array (0 to C_TAIL_FIFO_DEPTH - 1) of
      std_logic_vector(7 downto 0);

   signal tail_fifo   : tail_fifo_t;
   signal tail_wr_ptr : unsigned(9 downto 0) := (others => '0');
   signal tail_rd_ptr : unsigned(9 downto 0) := (others => '0');
   signal tail_count  : unsigned(10 downto 0) := (others => '0');

   signal payload_from_fifo : std_logic := '0';

   -- Non-destructive validator for buffered bytes when physical EOF arrives
   -- while INIT is still running.
   signal tail_scan_ptr       : unsigned(9 downto 0) := (others => '0');
   signal tail_scan_left      : unsigned(10 downto 0) := (others => '0');
   signal tail_scan_lo        : std_logic_vector(7 downto 0) := (others => '0');
   signal tail_scan_start     : unsigned(15 downto 0) := (others => '0');
   signal tail_scan_end       : unsigned(15 downto 0) := (others => '0');
   signal tail_scan_payload   : unsigned(16 downto 0) := (others => '0');


   ---------------------------------------------------------------------------
   -- Bootstrap/setup indexes
   ---------------------------------------------------------------------------

   signal reset_count      : unsigned(7 downto 0) := (others => '0');
   signal settle_count     : unsigned(4 downto 0) := (others => '0');
   signal clear_addr       : unsigned(15 downto 0) := (others => '0');


   signal loader_index     : integer range 0 to 33 := 0;
   signal fixed_index      : integer range 0 to 11 := 0;
   signal block_prep_index : integer range 0 to 3 := 0;


   ---------------------------------------------------------------------------
   -- DMA registers and ACK CDC
   ---------------------------------------------------------------------------

   signal dma_addr_reg : std_logic_vector(25 downto 0) := (others => '0');
   signal dma_data_reg : std_logic_vector(7 downto 0) := (others => '0');
   signal dma_read_reg : std_logic := '0';
   signal dma_req_toggle_reg : std_logic := '0';
   signal dma_ack_sync1 : std_logic := '0';
   signal dma_ack_sync2 : std_logic := '0';
   signal dma_ack_seen  : std_logic := '0';

   signal dma_readback_reg : std_logic_vector(7 downto 0) := (others => '0');


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
   -- File-stream accesses use qnice_wait_reg.  Unlike a state-derived
   -- combinational WAIT, qnice_wait_reg is only deasserted by qnice_proc
   -- after the pending transaction has actually been consumed.  This
   -- prevents a newly-entered parser state from acknowledging a held byte
   -- one clock before that state's clocked capture logic runs.
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

      variable live_byte_valid_v : boolean;
      variable parser_byte_valid_v : boolean;
      variable parser_byte_fifo_v : boolean;
      variable parser_byte_v : std_logic_vector(7 downto 0);

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

            tail_wr_ptr       <= (others => '0');
            tail_rd_ptr       <= (others => '0');
            tail_count        <= (others => '0');
            payload_from_fifo <= '0';

            tail_scan_ptr     <= (others => '0');
            tail_scan_left    <= (others => '0');
            tail_scan_lo      <= (others => '0');
            tail_scan_start   <= (others => '0');
            tail_scan_end     <= (others => '0');
            tail_scan_payload <= (others => '0');

            reset_count      <= (others => '0');
            settle_count     <= (others => '0');
            clear_addr       <= (others => '0');

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

            -- Default to stalling streamed file data. Individual parser
            -- states release exactly the transaction they have consumed.
            qnice_wait_reg <= '1';

            -- A live byte is a new non-CSR QNICE write transaction.
            live_byte_valid_v :=
               qnice_ce_i = '1' and
               qnice_csr = '0' and
               qnice_we_i = '1' and
               (stream_addr_valid = '0' or
                qnice_addr_i /= last_stream_addr);

            -- Parser input priority: replay pending FIFO bytes first. Only
            -- when the FIFO is empty can the parser consume the live stream.
            parser_byte_valid_v := false;
            parser_byte_fifo_v  := false;
            parser_byte_v       := (others => '0');

            if tail_count /= 0 then
               parser_byte_valid_v := true;
               parser_byte_fifo_v  := true;
               parser_byte_v :=
                  tail_fifo(to_integer(tail_rd_ptr));
            elsif live_byte_valid_v then
               parser_byte_valid_v := true;
               parser_byte_fifo_v  := false;
               parser_byte_v       := qnice_data_i(7 downto 0);
            end if;

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

               ----------------------------------------------------------------
               -- While Atari INIT code is running, continue accepting the host
               -- file stream into the pending FIFO. This removes the circular
               -- dependency where QNICE could not reach physical EOF until INIT
               -- returned.
               --
               -- If the FIFO fills, WAIT naturally remains asserted until the
               -- Atari returns and the parser starts replaying buffered bytes.
               ----------------------------------------------------------------

               if (state = WAIT_NEXT_MAGIC_REQ_ST or
                   state = WAIT_NEXT_MAGIC_CHECK_ST or
                   state = WAIT_NEXT_STATUS_REQ_ST or
                   state = WAIT_NEXT_STATUS_CHECK_ST) and
                  qnice_req_status /= C_CSR_REQ_OK and
                  live_byte_valid_v and
                  tail_count < to_unsigned(C_TAIL_FIFO_DEPTH,
                                           tail_count'length) then

                  tail_fifo(to_integer(tail_wr_ptr)) <= qnice_data_i(7 downto 0);
                  tail_wr_ptr <= tail_wr_ptr + 1;
                  tail_count  <= tail_count + 1;

                  stream_count <= stream_count + 1;
                  last_stream_addr <= qnice_addr_i;
                  stream_addr_valid <= '1';

                  -- Acknowledge this QNICE byte immediately. It is safely
                  -- buffered even though the Atari INIT is still running.
                  qnice_wait_reg <= '0';

               end if;

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

                        tail_wr_ptr       <= (others => '0');
                        tail_rd_ptr       <= (others => '0');
                        tail_count        <= (others => '0');
                        payload_from_fifo <= '0';

                        tail_scan_ptr     <= (others => '0');
                        tail_scan_left    <= (others => '0');
                        tail_scan_lo      <= (others => '0');
                        tail_scan_start   <= (others => '0');
                        tail_scan_end     <= (others => '0');
                        tail_scan_payload <= (others => '0');

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

                        clear_addr <= (others => '0');
                        state <= CLEAR_RAM_ST;

                     else

                        settle_count <= settle_count + 1;

                     end if;


                  ----------------------------------------------------------
                  -- Match MiSTer XEX startup: clear the first 64K of Atari RAM
                  -- before installing the $D100 bootstrap and OS variables.
                  ----------------------------------------------------------

                  when CLEAR_RAM_ST =>

                     dma_addr_reg <=
                        "0000000000" &
                        std_logic_vector(clear_addr);

                     dma_data_reg <= x"00";
                     dma_read_reg <= '0';

                     dma_req_toggle_reg <= not dma_req_toggle_reg;

                     dma_return_state <= CLEAR_RAM_NEXT_ST;
                     state <= DMA_WAIT_ST;


                  when CLEAR_RAM_NEXT_ST =>

                     if clear_addr = x"FFFF" then

                        loader_index <= 0;
                        state <= INSTALL_LOADER_ST;

                     else

                        clear_addr <= clear_addr + 1;
                        state <= CLEAR_RAM_ST;

                     end if;


                  ----------------------------------------------------------
                  -- Install 34-byte Atari bootstrap at $D100.
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

                   if loader_index = 33 then
                
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

                     if parser_byte_valid_v then

                        word_lo <= parser_byte_v;

                        if parser_byte_fifo_v then
                           tail_rd_ptr <= tail_rd_ptr + 1;
                           tail_count  <= tail_count - 1;
                        else
                           stream_count <= stream_count + 1;
                           last_stream_addr <= qnice_addr_i;
                           stream_addr_valid <= '1';
                           qnice_wait_reg <= '0';
                        end if;

                        state <= WORD_HI_ST;

                     elsif qnice_req_status = C_CSR_REQ_OK then

                        state <= EOF_ST;

                     end if;


                  ----------------------------------------------------------
                  -- Read high byte of marker/start word.
                  ----------------------------------------------------------

                  when WORD_HI_ST =>

                     if parser_byte_valid_v then

                        word_v(7 downto 0)  := unsigned(word_lo);
                        word_v(15 downto 8) := unsigned(parser_byte_v);

                        if parser_byte_fifo_v then
                           tail_rd_ptr <= tail_rd_ptr + 1;
                           tail_count  <= tail_count - 1;
                        else
                           stream_count <= stream_count + 1;
                           last_stream_addr <= qnice_addr_i;
                           stream_addr_valid <= '1';
                           qnice_wait_reg <= '0';
                        end if;

                        if word_v = x"FFFF" then
                           state <= WORD_LO_ST;
                        else
                           xex_start_addr <= word_v;
                           state <= END_LO_ST;
                        end if;

                     elsif qnice_req_status = C_CSR_REQ_OK then

                        state <= EOF_ST;

                     end if;


                  ----------------------------------------------------------
                  -- Segment END low byte
                  ----------------------------------------------------------

                  when END_LO_ST =>

                     if parser_byte_valid_v then

                        word_lo <= parser_byte_v;

                        if parser_byte_fifo_v then
                           tail_rd_ptr <= tail_rd_ptr + 1;
                           tail_count  <= tail_count - 1;
                        else
                           stream_count <= stream_count + 1;
                           last_stream_addr <= qnice_addr_i;
                           stream_addr_valid <= '1';
                           qnice_wait_reg <= '0';
                        end if;

                        state <= END_HI_ST;

                     elsif qnice_req_status = C_CSR_REQ_OK then

                        state <= EOF_ST;

                     end if;


                  ----------------------------------------------------------
                  -- Segment END high byte
                  ----------------------------------------------------------

                  when END_HI_ST =>

                     if parser_byte_valid_v then

                        word_v(7 downto 0)  := unsigned(word_lo);
                        word_v(15 downto 8) := unsigned(parser_byte_v);

                        if parser_byte_fifo_v then
                           tail_rd_ptr <= tail_rd_ptr + 1;
                           tail_count  <= tail_count - 1;
                        else
                           stream_count <= stream_count + 1;
                           last_stream_addr <= qnice_addr_i;
                           stream_addr_valid <= '1';
                           qnice_wait_reg <= '0';
                        end if;

                        if word_v < xex_start_addr then

                           -- MiSTer: read_len < 1 goes directly to xex_eof.
                           state <= EOF_ST;

                        else

                           xex_end_addr   <= word_v;
                           xex_write_addr <= xex_start_addr;
                           block_prep_index <= 0;
                           state <= PREP_BLOCK_ST;

                        end if;

                     elsif qnice_req_status = C_CSR_REQ_OK then

                        state <= EOF_ST;

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

                     if parser_byte_valid_v then

                        dma_addr_reg <=
                           "0000000000" &
                           std_logic_vector(xex_write_addr);

                        dma_data_reg <= parser_byte_v;
                        dma_read_reg <= '0';
                        dma_req_toggle_reg <= not dma_req_toggle_reg;

                        if parser_byte_fifo_v then
                           tail_rd_ptr <= tail_rd_ptr + 1;
                           tail_count  <= tail_count - 1;
                           payload_from_fifo <= '1';
                        else
                           stream_count <= stream_count + 1;
                           last_stream_addr <= qnice_addr_i;
                           stream_addr_valid <= '1';
                           payload_from_fifo <= '0';
                        end if;

                        dma_return_state <= PAYLOAD_COMPLETE_ST;
                        state <= DMA_WAIT_ST;

                     elsif qnice_req_status = C_CSR_REQ_OK then

                        state <= EOF_ST;

                     end if;


                  when PAYLOAD_COMPLETE_ST =>

                     if xex_write_addr = xex_end_addr then

                        segment_index <= segment_index + 1;

                        if payload_from_fifo = '1' then
                           state <= RELEASE_BLOCK_ST;
                        else
                           stream_return_state <= RELEASE_BLOCK_ST;
                           state <= STREAM_RELEASE_ST;
                        end if;

                     else

                        xex_write_addr <= xex_write_addr + 1;

                        if payload_from_fifo = '1' then
                           state <= PAYLOAD_ST;
                        else
                           stream_return_state <= PAYLOAD_ST;
                           state <= STREAM_RELEASE_ST;
                        end if;

                     end if;


                  ----------------------------------------------------------
                  -- One complete segment is in Atari RAM.
                  --
                  -- D10E = $01 releases the Atari-side bootstrap.  It jumps
                  -- through INITAD and returns to the bootstrap.
                  ----------------------------------------------------------

                  when RELEASE_BLOCK_ST =>

                     -- One complete segment is in Atari RAM. Release the
                     -- Atari-side bootstrap through INITAD.
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
                  --
                  -- IMPORTANT: if the segment we just released was the last
                  -- one in the file, INITAD may point at real program code
                  -- that never returns to the bootstrap spin loop (e.g. it
                  -- IS the game's entry point).  In that case D100/D10E will
                  -- never show $60/$00 again.  By the time HANDLE_CRTROM_M
                  -- sets STATUS=OK, the entire file has already streamed
                  -- through us (see crts-and-roms.asm's _LI_FREAD_S loop),
                  -- so if we observe REQ_OK while still waiting here, that
                  -- is a normal, successful end of file, not an error --
                  -- go straight to EOF_ST rather than spinning forever.
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

                     elsif qnice_req_status = C_CSR_REQ_OK then

                        -- Physical EOF arrived while INIT is still running.
                        -- Validate the buffered tail before deciding whether it
                        -- is legitimate XEX data or ignorable physical trailer.
                        if tail_count = 0 then
                           state <= EOF_ST;
                        else
                           tail_scan_ptr  <= tail_rd_ptr;
                           tail_scan_left <= tail_count;
                           state <= TAIL_VALIDATE_WORD_LO_ST;
                        end if;

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

                        -- INIT returned. Replay FIFO before taking live bytes.
                        state <= WORD_LO_ST;

                     elsif qnice_req_status = C_CSR_REQ_OK then

                        -- EOF while INIT is still running: validate pending bytes.
                        if tail_count = 0 then
                           state <= EOF_ST;
                        else
                           tail_scan_ptr  <= tail_rd_ptr;
                           tail_scan_left <= tail_count;
                           state <= TAIL_VALIDATE_WORD_LO_ST;
                        end if;

                     else

                        state <= WAIT_NEXT_MAGIC_REQ_ST;

                     end if;


                  ----------------------------------------------------------
                  -- Validate pending FIFO content as a complete XEX tail.
                  --
                  -- The validator is non-destructive: tail_rd_ptr/tail_count
                  -- remain untouched. A valid tail is replayed only after INIT
                  -- returns. An invalid/incomplete tail is treated as physical
                  -- trailer data and discarded.
                  ----------------------------------------------------------

                  when TAIL_VALIDATE_WORD_LO_ST =>

                     if tail_scan_left = 0 then

                        -- Exactly consumed a valid sequence of segments.
                        state <= TAIL_WAIT_MAGIC_REQ_ST;

                     else

                        tail_scan_lo <= tail_fifo(to_integer(tail_scan_ptr));
                        tail_scan_ptr <= tail_scan_ptr + 1;
                        tail_scan_left <= tail_scan_left - 1;
                        state <= TAIL_VALIDATE_WORD_HI_ST;

                     end if;


                  when TAIL_VALIDATE_WORD_HI_ST =>

                     if tail_scan_left = 0 then

                        -- Odd trailing byte: not a complete XEX header.
                        tail_rd_ptr <= tail_wr_ptr;
                        tail_count  <= (others => '0');
                        state <= EOF_ST;

                     else

                        word_v(7 downto 0)  := unsigned(tail_scan_lo);
                        word_v(15 downto 8) :=
                           unsigned(tail_fifo(to_integer(tail_scan_ptr)));

                        tail_scan_ptr <= tail_scan_ptr + 1;
                        tail_scan_left <= tail_scan_left - 1;

                        if word_v = x"FFFF" then

                           state <= TAIL_VALIDATE_WORD_LO_ST;

                        else

                           tail_scan_start <= word_v;
                           state <= TAIL_VALIDATE_END_LO_ST;

                        end if;

                     end if;


                  when TAIL_VALIDATE_END_LO_ST =>

                     if tail_scan_left = 0 then

                        tail_rd_ptr <= tail_wr_ptr;
                        tail_count  <= (others => '0');
                        state <= EOF_ST;

                     else

                        tail_scan_lo <= tail_fifo(to_integer(tail_scan_ptr));
                        tail_scan_ptr <= tail_scan_ptr + 1;
                        tail_scan_left <= tail_scan_left - 1;
                        state <= TAIL_VALIDATE_END_HI_ST;

                     end if;


                  when TAIL_VALIDATE_END_HI_ST =>

                     if tail_scan_left = 0 then

                        tail_rd_ptr <= tail_wr_ptr;
                        tail_count  <= (others => '0');
                        state <= EOF_ST;

                     else

                        word_v(7 downto 0)  := unsigned(tail_scan_lo);
                        word_v(15 downto 8) :=
                           unsigned(tail_fifo(to_integer(tail_scan_ptr)));

                        tail_scan_ptr <= tail_scan_ptr + 1;
                        tail_scan_left <= tail_scan_left - 1;
                        tail_scan_end <= word_v;

                        if word_v < tail_scan_start then

                           -- Invalid segment length in the pending tail.
                           tail_rd_ptr <= tail_wr_ptr;
                           tail_count  <= (others => '0');
                           state <= EOF_ST;

                        else

                           -- Payload byte count = END - START + 1.
                           tail_scan_payload <=
                              resize(word_v, 17) -
                              resize(tail_scan_start, 17) + 1;

                           state <= TAIL_VALIDATE_PAYLOAD_ST;

                        end if;

                     end if;


                  when TAIL_VALIDATE_PAYLOAD_ST =>

                     if tail_scan_payload = 0 then

                        state <= TAIL_VALIDATE_WORD_LO_ST;

                     elsif tail_scan_left = 0 then

                        -- Segment claims more payload than physically remains.
                        tail_rd_ptr <= tail_wr_ptr;
                        tail_count  <= (others => '0');
                        state <= EOF_ST;

                     else

                        -- Payload contents do not matter to syntactic validity.
                        tail_scan_ptr <= tail_scan_ptr + 1;
                        tail_scan_left <= tail_scan_left - 1;
                        tail_scan_payload <= tail_scan_payload - 1;

                     end if;


                  ----------------------------------------------------------
                  -- Pending tail is syntactically valid XEX data. Physical EOF
                  -- has already happened, so keep polling the Atari until INIT
                  -- returns. Then replay the FIFO through the normal parser.
                  ----------------------------------------------------------

                  when TAIL_WAIT_MAGIC_REQ_ST =>

                     dma_addr_reg <=
                        "0000000000" &
                        std_logic_vector(C_XEX_MAGIC_ADDR);

                     dma_data_reg <= (others => '0');
                     dma_read_reg <= '1';
                     dma_req_toggle_reg <= not dma_req_toggle_reg;

                     dma_return_state <= TAIL_WAIT_MAGIC_CHECK_ST;
                     state <= DMA_WAIT_ST;


                  when TAIL_WAIT_MAGIC_CHECK_ST =>

                     if dma_readback_reg = x"60" then
                        state <= TAIL_WAIT_STATUS_REQ_ST;
                     else
                        state <= TAIL_WAIT_MAGIC_REQ_ST;
                     end if;


                  when TAIL_WAIT_STATUS_REQ_ST =>

                     dma_addr_reg <=
                        "0000000000" &
                        std_logic_vector(C_XEX_STATUS_ADDR);

                     dma_data_reg <= (others => '0');
                     dma_read_reg <= '1';
                     dma_req_toggle_reg <= not dma_req_toggle_reg;

                     dma_return_state <= TAIL_WAIT_STATUS_CHECK_ST;
                     state <= DMA_WAIT_ST;


                  when TAIL_WAIT_STATUS_CHECK_ST =>

                     if dma_readback_reg = x"00" then

                        -- INIT finally returned. The FIFO still contains the
                        -- complete validated tail, so replay it normally.
                        state <= WORD_LO_ST;

                     else

                        state <= TAIL_WAIT_MAGIC_REQ_ST;

                     end if;


                  ----------------------------------------------------------
                  -- EOF.
                  --
                  -- D10E = $FF is negative, so the bootstrap takes init_go,
                  -- changes D100 $60->$5F and jumps through RUNAD.
                  --
                  -- NOTE: if we reached EOF_ST via the "last segment never
                  -- returned" path above (rather than via WORD_LO_ST), the
                  -- Atari CPU is not necessarily sitting in the bootstrap
                  -- spin loop waiting for this write -- it may already be
                  -- running the loaded program.  This write is harmless in
                  -- that case (D10E of a program that isn't the bootstrap
                  -- is just an unused RAM byte); its only purpose is to
                  -- cleanly finish our own protocol with the QNICE side.
                  ----------------------------------------------------------

                  when EOF_ST =>

                     -- Final host signal.  If the Atari is waiting in the
                     -- bootstrap, $FF is negative and takes init_go ->
                     -- JMP ($02E0).  If the last INIT already started the
                     -- program and never returned, this is just a harmless
                     -- write to the loader status byte.
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
                  --
                  -- EOF handling: if this was the last byte of the last
                  -- segment (stream_return_state = RELEASE_BLOCK_ST), the
                  -- framework declaring REQ_OK here is the normal, successful
                  -- end of file -- go to EOF_ST. If more payload was still
                  -- expected (stream_return_state = PAYLOAD_ST), REQ_OK here
                  -- means the file ended in the middle of a segment, which is
                  -- a genuine error.
                  ----------------------------------------------------------

                  when STREAM_RELEASE_ST =>

                     if qnice_req_status = C_CSR_REQ_OK then

                        state <= EOF_ST;

                     elsif qnice_ce_i = '1' and
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

                     -- M2M keeps the CRT/ROM status at OK after a completed
                     -- manual load so the menu can remember that the slot is
                     -- loaded. Therefore a second load does NOT necessarily
                     -- pass through C_CSR_REQ_IDLE. Re-arm immediately when
                     -- the framework starts a new byte stream.
                     if qnice_req_status = C_CSR_REQ_LDNG then

                        qnice_wait_reg <= '1';

                        stream_count      <= (others => '0');
                        last_stream_addr  <= (others => '0');
                        stream_addr_valid <= '0';

                        tail_wr_ptr       <= (others => '0');
                        tail_rd_ptr       <= (others => '0');
                        tail_count        <= (others => '0');
                        payload_from_fifo <= '0';

                        tail_scan_ptr     <= (others => '0');
                        tail_scan_left    <= (others => '0');
                        tail_scan_lo      <= (others => '0');
                        tail_scan_start   <= (others => '0');
                        tail_scan_end     <= (others => '0');
                        tail_scan_payload <= (others => '0');

                        first_segment     <= '1';
                        segment_index     <= to_unsigned(1, segment_index'length);

                        xex_start_addr <= (others => '0');
                        xex_end_addr   <= (others => '0');
                        xex_write_addr <= (others => '0');
                        qnice_resp_error   <= (others => '0');
                        qnice_resp_address <= (others => '0');

                        -- Align to the current ACK toggle before the new load.
                        dma_ack_seen <= dma_ack_sync2;

                        qnice_resp_status <= C_CSR_RESP_PARSING;
                        state <= START_XEX_ST;

                     elsif qnice_req_status = C_CSR_REQ_IDLE then

                        qnice_resp_status <= C_CSR_RESP_IDLE;
                        qnice_resp_error  <= (others => '0');
                        qnice_resp_address <= (others => '0');
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

                     -- Same re-arm rule as DONE_ST: a new manual file load can
                     -- transition directly to LDNG without an intervening IDLE.
                     if qnice_req_status = C_CSR_REQ_LDNG then

                        qnice_wait_reg <= '1';

                        stream_count      <= (others => '0');
                        last_stream_addr  <= (others => '0');
                        stream_addr_valid <= '0';

                        tail_wr_ptr       <= (others => '0');
                        tail_rd_ptr       <= (others => '0');
                        tail_count        <= (others => '0');
                        payload_from_fifo <= '0';

                        tail_scan_ptr     <= (others => '0');
                        tail_scan_left    <= (others => '0');
                        tail_scan_lo      <= (others => '0');
                        tail_scan_start   <= (others => '0');
                        tail_scan_end     <= (others => '0');
                        tail_scan_payload <= (others => '0');

                        first_segment     <= '1';
                        segment_index     <= to_unsigned(1, segment_index'length);

                        xex_start_addr <= (others => '0');
                        xex_end_addr   <= (others => '0');
                        xex_write_addr <= (others => '0');
                        qnice_resp_error   <= (others => '0');
                        qnice_resp_address <= (others => '0');

                        -- Align to the current ACK toggle before the new load.
                        dma_ack_seen <= dma_ack_sync2;

                        qnice_resp_status <= C_CSR_RESP_PARSING;
                        state <= START_XEX_ST;

                     elsif qnice_req_status = C_CSR_REQ_IDLE then

                        qnice_resp_status <= C_CSR_RESP_IDLE;
                        qnice_resp_error  <= (others => '0');
                        qnice_resp_address <= (others => '0');
                        state <= IDLE_ST;

                     end if;


               end case;

            end if;

         end if;

      end if;

   end process qnice_proc;

end architecture beh;
