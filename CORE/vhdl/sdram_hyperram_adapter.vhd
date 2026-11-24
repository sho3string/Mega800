----------------------------------------------------------------------------------
-- Mega800: drop-in replacement for the Atari800 core's sdram_statemachine
-- with a BRAM read cache in front of HyperRAM and a low-latency clock crossing.
--
-- Two clock domains:
--    CLK_SYSTEM (Atari main clock): core handshake + cache
--    hr_clk_i   (HyperRAM clock)  : engine that drives the Avalon master
-- They talk through a toggle handshake instead of async FIFOs:
--    main -> HR : cmd_* registers + cmd_tog        (2 FF sync in HR domain)
--    HR -> main : rbuf registers + crit_tog/done_tog (2 FF sync in main domain)
-- cmd_* are stable while a command is outstanding; rbuf is stable from the
-- toggle until the next command. CORE.xdc constrains these paths with
-- set_max_delay -datapath_only.
--
-- Why: ANTIC consumes DMA data at a fixed point in the bus cycle. Each cache
-- miss must come back quickly. The generic avm_fifo crossing added ~300 ns.
--
-- Cache (main domain):
--    direct mapped, 128 KiB, 16-byte lines, per-byte valid bits
--    Byte reads : hit  -> COMPLETE after 2 clocks
--                 miss -> line burst (8 words); COMPLETE as soon as the
--                         requested word is in (critical word first); the line
--                         is copied into the cache when the burst is done.
--                         A request arriving meanwhile is held and served next.
--    Byte writes: write-through (posted) + write-allocate (byte valid bit).
--    16/32-bit accesses (DMA readback only) bypass the cache.
--    Prefetch (C_PREFETCH): after a demand miss on line L the next line L+1
--    is fetched in the background; when the core first hits a prefetched line
--    the line after it is fetched (follows sequential streams). While a
--    prefetch is in flight, read hits are still served; writes and misses
--    are held until it is done.
--
-- Handshake to the core (identical to sdram_statemachine):
--    REQUEST   : one-clock pulse, ADDRESS_IN/DATA_IN/READ_EN/WRITE_EN/width
--                valid in that cycle
--    COMPLETE  : '0' in the request cycle and while busy, '1' otherwise
--    DATA_OUT  : held until the next read completes
--
-- Address map (core SDRAM byte address -> HyperRAM byte address):
--    0x000000 - 0x4AFFFF  (4.7 MB) -> 0x100000 - 0x5AFFFF   RAM banks, freezer
--    0x780000 - 0x7BFFFF           -> NOT MAPPED (PokeyMAX sample RAM / SID ROM:
--                                     polled constantly by the core, never loaded
--                                     on Mega800; answered in 1 clock with 0xFF)
--    0x800000 - 0x8FFFFF  (1 MB)   -> 0x5F0000 - 0x6EFFFF   cartridge 1
--    anything else                 -> unmapped: reads 0xFF, writes ignored
--
--    HyperRAM 0x000000 - 0x0FFFFF : M2M ascal framebuffer
--    HyperRAM 0x700000 - 0x7FFFFF : Step 1 mount buffers (CAS, D1)
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sdram_hyperram_adapter is
   port (
      CLK_SYSTEM            : in  std_logic;
      RESET_N               : in  std_logic;

      -- Atari core side (same names as sdram_statemachine)
      READ_EN               : in  std_logic;
      WRITE_EN              : in  std_logic;
      REQUEST               : in  std_logic;
      BYTE_ACCESS           : in  std_logic;
      WORD_ACCESS           : in  std_logic;
      LONGWORD_ACCESS       : in  std_logic;
      REFRESH               : in  std_logic;   -- unused
      ADDRESS_IN            : in  std_logic_vector(24 downto 0);  -- byte address
      DATA_IN               : in  std_logic_vector(31 downto 0);
      DATA_OUT              : out std_logic_vector(31 downto 0);
      COMPLETE              : out std_logic;
      reset_client_n        : out std_logic;

      -- Avalon-MM master, HyperRAM clock domain, 16-bit word addressed
      hr_clk_i              : in  std_logic;
      hr_rst_i              : in  std_logic;
      avm_write_o           : out std_logic;
      avm_read_o            : out std_logic;
      avm_address_o         : out std_logic_vector(31 downto 0);
      avm_writedata_o       : out std_logic_vector(15 downto 0);
      avm_byteenable_o      : out std_logic_vector(1 downto 0);
      avm_burstcount_o      : out std_logic_vector(7 downto 0);
      avm_readdata_i        : in  std_logic_vector(15 downto 0);
      avm_readdatavalid_i   : in  std_logic;
      avm_waitrequest_i     : in  std_logic
   );
end entity sdram_hyperram_adapter;

architecture synthesis of sdram_hyperram_adapter is

   ---------------------------------------------------------------------------
   -- Cache geometry
   ---------------------------------------------------------------------------
   constant C_LINE_WORDS : natural := 8;    -- 16 bytes per line
   constant C_IDX_BITS   : natural := 13;   -- 128 KiB
   constant C_TAG_LO     : natural := 4 + C_IDX_BITS;          -- 17
   constant C_TAG_BITS   : natural := 23 - C_TAG_LO;           -- HyperRAM byte address bits 22..17
   constant C_PREFETCH   : boolean := true;  -- set false to disable next-line prefetch

   ---------------------------------------------------------------------------
   -- Main clock domain
   ---------------------------------------------------------------------------
   type state_t is (S_IDLE, S_PEND, S_LOOKUP, S_WAIT_W, S_WAIT_R,
                    S_WAIT_CRIT, S_WAIT_DONE, S_COPY,
                    S_PF, S_PF_LOOK, S_PF_HOLD, S_PF_COPY);
   signal state         : state_t := S_IDLE;

   -- Latched request
   signal req_addr      : unsigned(22 downto 0) := (others => '0');  -- HyperRAM byte address
   signal req_we        : std_logic := '0';
   signal req_data      : std_logic_vector(7 downto 0) := (others => '0');
   signal is_long       : std_logic := '0';
   signal data_out_reg  : std_logic_vector(31 downto 0) := (others => '1');
   signal answered      : std_logic := '0';    -- core already got COMPLETE for current op
   signal copy_cnt      : unsigned(2 downto 0) := (others => '0');

   -- Prefetch
   signal pf_want       : std_logic := '0';                         -- a prefetch is wanted
   signal pf_target     : unsigned(22 downto 0) := (others => '0'); -- line base to prefetch
   signal pf_addr       : unsigned(22 downto 0) := (others => '0'); -- line base being prefetched
   signal last_pf_line  : unsigned(22 downto 0) := (others => '1'); -- last completed prefetch

   -- Request held while the previous operation finishes
   signal pend          : std_logic := '0';
   signal pend_mapped   : boolean   := false;
   signal pend_addr     : unsigned(22 downto 0) := (others => '0');
   signal pend_we       : std_logic := '0';
   signal pend_data     : std_logic_vector(31 downto 0) := (others => '0');
   signal pend_long     : std_logic := '0';
   signal pend_word     : std_logic := '0';

   -- Command registers (main -> HR). Stable while a command is outstanding.
   signal cmd_we        : std_logic := '0';
   signal cmd_addr      : std_logic_vector(21 downto 0) := (others => '0');  -- word address
   signal cmd_be        : std_logic_vector(1 downto 0)  := (others => '0');
   signal cmd_wdata     : std_logic_vector(15 downto 0) := (others => '0');
   signal cmd_wdata_hi  : std_logic_vector(15 downto 0) := (others => '0');
   signal cmd_burst     : unsigned(3 downto 0)          := (others => '0');
   signal cmd_crit      : unsigned(2 downto 0)          := (others => '0');
   signal cmd_tog       : std_logic := '0';

   -- Expected toggle values for the outstanding command
   signal exp_crit      : std_logic := '0';
   signal exp_done      : std_logic := '0';

   -- HR -> main toggles, synchronised
   signal crit_sync1, crit_sync2 : std_logic := '0';
   signal done_sync1, done_sync2 : std_logic := '0';
   attribute ASYNC_REG : string;
   attribute ASYNC_REG of crit_sync1, crit_sync2, done_sync1, done_sync2 : signal is "TRUE";
   signal crit_ok       : std_logic;
   signal done_ok       : std_logic;

   -- Address remap
   signal mapped        : boolean;
   signal hr_byte_addr  : unsigned(22 downto 0);

   -- Cache RAMs (single port, read-first, 1 clock read latency)
   -- tag RAM entry: byte-valid mask (15..0) & tag
   type tag_ram_t  is array (0 to 2**C_IDX_BITS - 1) of std_logic_vector(C_TAG_BITS + 15 downto 0);
   type data_ram_t is array (0 to 2**(C_IDX_BITS+3) - 1) of std_logic_vector(7 downto 0);     -- per word
   signal tag_ram  : tag_ram_t  := (others => (others => '0'));
   signal dlo_ram  : data_ram_t := (others => (others => '0'));
   signal dhi_ram  : data_ram_t := (others => (others => '0'));

   signal c_line    : unsigned(C_IDX_BITS - 1 downto 0);
   signal c_word    : unsigned(C_IDX_BITS + 2 downto 0);
   signal tag_we    : std_logic;
   signal tag_wd    : std_logic_vector(C_TAG_BITS + 15 downto 0);
   signal dlo_we    : std_logic;
   signal dhi_we    : std_logic;
   signal dlo_wd    : std_logic_vector(7 downto 0);
   signal dhi_wd    : std_logic_vector(7 downto 0);
   signal tag_q     : std_logic_vector(C_TAG_BITS + 15 downto 0);
   signal tag_match : std_logic;
   signal q_mask    : std_logic_vector(15 downto 0);
   signal dlo_q     : std_logic_vector(7 downto 0);
   signal dhi_q     : std_logic_vector(7 downto 0);
   signal hit       : std_logic;

   ---------------------------------------------------------------------------
   -- HyperRAM clock domain
   ---------------------------------------------------------------------------
   type rbuf_t is array (0 to C_LINE_WORDS - 1) of std_logic_vector(15 downto 0);
   signal rbuf          : rbuf_t := (others => (others => '0'));  -- read by main after toggle
   signal crit_tog      : std_logic := '0';
   signal done_tog      : std_logic := '0';
   signal cmd_sync1, cmd_sync2 : std_logic := '0';
   attribute ASYNC_REG of cmd_sync1, cmd_sync2 : signal is "TRUE";
   signal cmd_seen      : std_logic := '0';

   type e_state_t is (E_IDLE, E_CMD, E_WRITE2, E_RDATA);
   signal e_state       : e_state_t := E_IDLE;
   signal e_beat        : unsigned(3 downto 0) := (others => '0');
   signal e_write       : std_logic := '0';
   signal e_read        : std_logic := '0';
   signal e_address     : std_logic_vector(31 downto 0) := (others => '0');
   signal e_writedata   : std_logic_vector(15 downto 0) := (others => '0');
   signal e_byteenable  : std_logic_vector(1 downto 0)  := (others => '0');
   signal e_burstcount  : std_logic_vector(7 downto 0)  := x"01";

begin

   reset_client_n <= RESET_N;
   DATA_OUT       <= data_out_reg;

   COMPLETE <= '1' when REQUEST = '0' and pend = '0' and
                        (state = S_IDLE or state = S_PF or state = S_PF_COPY or
                         (answered = '1' and (state = S_WAIT_W or state = S_WAIT_DONE or state = S_COPY)))
               else '0';

   crit_ok <= '1' when crit_sync2 = exp_crit else '0';
   done_ok <= '1' when done_sync2 = exp_done else '0';

   ---------------------------------------------------------------------------
   -- Address remap (combinational, used in the request cycle)
   ---------------------------------------------------------------------------
   remap_proc : process (ADDRESS_IN)
      variable a : unsigned(24 downto 0);
   begin
      a := unsigned(ADDRESS_IN);
      mapped       <= true;
      hr_byte_addr <= (others => '0');
      if a < 16#4B0000# then
         hr_byte_addr <= resize(a + 16#100000#, 23);
      elsif a >= 16#800000# and a < 16#900000# then
         hr_byte_addr <= resize(a - 16#800000# + 16#5F0000#, 23);
      else
         mapped <= false;
      end if;
   end process remap_proc;

   ---------------------------------------------------------------------------
   -- Cache RAM control (combinational)
   ---------------------------------------------------------------------------
   tag_match <= '1' when unsigned(tag_q(C_TAG_BITS - 1 downto 0)) = req_addr(22 downto C_TAG_LO) else '0';
   q_mask    <= tag_q(C_TAG_BITS + 15 downto C_TAG_BITS);
   hit       <= tag_match and q_mask(to_integer(req_addr(3 downto 0)));

   cache_ctrl_proc : process (all)
      variable bit_mask : std_logic_vector(15 downto 0);
   begin
      tag_we <= '0';
      dlo_we <= '0';
      dhi_we <= '0';
      tag_wd <= (others => '1');                                 -- default: all bytes valid
      tag_wd(C_TAG_BITS - 1 downto 0) <= std_logic_vector(req_addr(22 downto C_TAG_LO));
      dlo_wd <= req_data;
      dhi_wd <= req_data;

      bit_mask := (others => '0');
      bit_mask(to_integer(req_addr(3 downto 0))) := '1';

      case state is
         when S_IDLE | S_PF =>
            -- Look up the incoming request (address valid in the REQUEST cycle)
            c_line <= hr_byte_addr(C_TAG_LO - 1 downto 4);
            c_word <= hr_byte_addr(C_TAG_LO - 1 downto 1);

         when S_PF_COPY =>
            -- Copy the prefetched line from rbuf (stable) into the cache
            c_line <= pf_addr(C_TAG_LO - 1 downto 4);
            c_word <= pf_addr(C_TAG_LO - 1 downto 4) & copy_cnt;
            dlo_we <= '1';
            dhi_we <= '1';
            dlo_wd <= rbuf(to_integer(copy_cnt))(7 downto 0);
            dhi_wd <= rbuf(to_integer(copy_cnt))(15 downto 8);
            tag_wd(C_TAG_BITS - 1 downto 0) <= std_logic_vector(pf_addr(22 downto C_TAG_LO));
            if copy_cnt = C_LINE_WORDS - 1 then
               tag_we <= '1';                                     -- tag + all 16 bytes valid
            end if;

         when S_LOOKUP =>
            c_line <= req_addr(C_TAG_LO - 1 downto 4);
            c_word <= req_addr(C_TAG_LO - 1 downto 1);
            -- Write: always store the byte (write-allocate), update the mask
            if req_we = '1' then
               if req_addr(0) = '1' then
                  dhi_we <= '1';
               else
                  dlo_we <= '1';
               end if;
               tag_we <= '1';
               if tag_match = '1' then
                  tag_wd(C_TAG_BITS + 15 downto C_TAG_BITS) <= q_mask or bit_mask;
               else
                  tag_wd(C_TAG_BITS + 15 downto C_TAG_BITS) <= bit_mask;
               end if;
            end if;

         when S_COPY =>
            -- Copy the filled line from rbuf (stable) into the cache
            c_line <= req_addr(C_TAG_LO - 1 downto 4);
            c_word <= req_addr(C_TAG_LO - 1 downto 4) & copy_cnt;
            dlo_we <= '1';
            dhi_we <= '1';
            dlo_wd <= rbuf(to_integer(copy_cnt))(7 downto 0);
            dhi_wd <= rbuf(to_integer(copy_cnt))(15 downto 8);
            if copy_cnt = C_LINE_WORDS - 1 then
               tag_we <= '1';                                     -- tag + all 16 bytes valid
            end if;

         when others =>
            -- S_PEND looks up a held request with req_addr
            c_line <= req_addr(C_TAG_LO - 1 downto 4);
            c_word <= req_addr(C_TAG_LO - 1 downto 1);
      end case;
   end process cache_ctrl_proc;

   cache_ram_proc : process (CLK_SYSTEM)
   begin
      if rising_edge(CLK_SYSTEM) then
         if tag_we = '1' then
            tag_ram(to_integer(c_line)) <= tag_wd;
         end if;
         tag_q <= tag_ram(to_integer(c_line));

         if dlo_we = '1' then
            dlo_ram(to_integer(c_word)) <= dlo_wd;
         end if;
         dlo_q <= dlo_ram(to_integer(c_word));

         if dhi_we = '1' then
            dhi_ram(to_integer(c_word)) <= dhi_wd;
         end if;
         dhi_q <= dhi_ram(to_integer(c_word));
      end if;
   end process cache_ram_proc;

   ---------------------------------------------------------------------------
   -- Main state machine (CLK_SYSTEM)
   ---------------------------------------------------------------------------
   fsm_proc : process (CLK_SYSTEM)
      variable v_be : std_logic_vector(1 downto 0);

      -- Send a command to the HR engine
      procedure issue (
         p_we    : std_logic;
         p_addr  : std_logic_vector(21 downto 0);
         p_be    : std_logic_vector(1 downto 0);
         p_wd    : std_logic_vector(15 downto 0);
         p_wd_hi : std_logic_vector(15 downto 0);
         p_burst : natural;
         p_crit  : unsigned(2 downto 0)) is
      begin
         cmd_we       <= p_we;
         cmd_addr     <= p_addr;
         cmd_be       <= p_be;
         cmd_wdata    <= p_wd;
         cmd_wdata_hi <= p_wd_hi;
         cmd_burst    <= to_unsigned(p_burst, 4);
         cmd_crit     <= p_crit;
         cmd_tog      <= not cmd_tog;
         exp_done     <= not exp_done;
         if p_we = '0' then
            exp_crit  <= not exp_crit;
         end if;
      end procedure issue;

      -- Start a new request (from the core directly, or one that was held)
      procedure start_req (
         p_mapped : boolean;
         p_addr   : unsigned(22 downto 0);
         p_we     : std_logic;
         p_data   : std_logic_vector(31 downto 0);
         p_long   : std_logic;
         p_word   : std_logic;
         p_held   : boolean) is
         variable burst : natural;
      begin
         answered <= '0';
         if not p_mapped then
            if p_we = '0' then
               data_out_reg <= (others => '1');
            end if;
            state <= S_IDLE;
         else
            req_addr <= p_addr;
            req_we   <= p_we;
            req_data <= p_data(7 downto 0);
            is_long  <= p_long;
            if p_long = '0' and p_word = '0' then
               -- Byte access: through the cache
               if p_held then
                  state <= S_PEND;     -- BRAM lookup with req_addr first
               else
                  state <= S_LOOKUP;   -- lookup already issued in S_IDLE
               end if;
            else
               -- 16/32-bit access: bypass the cache (DMA readback only)
               if p_long = '1' then
                  burst := 2;
               else
                  burst := 1;
               end if;
               issue(p_we, std_logic_vector(p_addr(22 downto 1)), "11",
                     p_data(15 downto 0), p_data(31 downto 16), burst, "000");
               if p_we = '1' then
                  answered <= '1';     -- posted write
                  state    <= S_WAIT_W;
               else
                  state    <= S_WAIT_R;
               end if;
            end if;
         end if;
      end procedure start_req;

      -- Current operation finished: serve a held / new request or go idle
      procedure finish is
      begin
         answered <= '0';
         if pend = '1' then
            pend <= '0';
            start_req(pend_mapped, pend_addr, pend_we, pend_data, pend_long, pend_word, true);
         elsif REQUEST = '1' then
            pend <= '0';         -- overrides the hold above: served right now
            start_req(mapped, hr_byte_addr, WRITE_EN, DATA_IN, LONGWORD_ACCESS, WORD_ACCESS, true);
         else
            state <= S_IDLE;
         end if;
      end procedure finish;

   begin
      if rising_edge(CLK_SYSTEM) then
         -- Synchronise HR -> main toggles
         crit_sync1 <= crit_tog;
         crit_sync2 <= crit_sync1;
         done_sync1 <= done_tog;
         done_sync2 <= done_sync1;

         -- Hold a request that arrives while the current op is still finishing
         -- (only possible after COMPLETE was given, i.e. answered = '1')
         if REQUEST = '1' and state /= S_IDLE and state /= S_PF then
            pend        <= '1';
            pend_mapped <= mapped;
            pend_addr   <= hr_byte_addr;
            pend_we     <= WRITE_EN;
            pend_data   <= DATA_IN;
            pend_long   <= LONGWORD_ACCESS;
            pend_word   <= WORD_ACCESS;
         end if;

         case state is

            when S_IDLE =>
               if REQUEST = '1' then
                  start_req(mapped, hr_byte_addr, WRITE_EN, DATA_IN, LONGWORD_ACCESS, WORD_ACCESS, false);
               elsif pf_want = '1' then
                  pf_want <= '0';
                  pf_addr <= pf_target;
                  issue('0', std_logic_vector(pf_target(22 downto 1)), "11",
                        x"0000", x"0000", C_LINE_WORDS, "000");
                  state   <= S_PF;
               end if;

            -- Prefetch in flight; the core is free. Serve read hits, hold the rest.
            when S_PF =>
               if REQUEST = '1' then
                  if not mapped then
                     if WRITE_EN = '0' then
                        data_out_reg <= (others => '1');
                     end if;
                  else
                     -- latch the request (lookup issued this clock by cache_ctrl_proc)
                     req_addr  <= hr_byte_addr;
                     req_we    <= WRITE_EN;
                     req_data  <= DATA_IN(7 downto 0);
                     is_long   <= LONGWORD_ACCESS;
                     pend_mapped <= mapped;
                     pend_addr <= hr_byte_addr;
                     pend_we   <= WRITE_EN;
                     pend_data <= DATA_IN;
                     pend_long <= LONGWORD_ACCESS;
                     pend_word <= WORD_ACCESS;
                     if LONGWORD_ACCESS = '0' and WORD_ACCESS = '0' and WRITE_EN = '0' then
                        state <= S_PF_LOOK;
                     else
                        pend  <= '1';           -- write / 16-32 bit: wait for prefetch
                        state <= S_PF_HOLD;
                     end if;
                  end if;
               elsif done_ok = '1' then
                  copy_cnt <= (others => '0');
                  state    <= S_PF_COPY;
               end if;

            when S_PF_LOOK =>
               if hit = '1' then
                  if req_addr(0) = '1' then
                     data_out_reg(7 downto 0) <= dhi_q;
                  else
                     data_out_reg(7 downto 0) <= dlo_q;
                  end if;
                  state <= S_PF;
               else
                  pend  <= '1';                 -- read miss: wait for prefetch
                  state <= S_PF_HOLD;
               end if;

            when S_PF_HOLD =>
               if done_ok = '1' then
                  copy_cnt <= (others => '0');
                  state    <= S_PF_COPY;
               end if;

            when S_PF_COPY =>
               copy_cnt <= copy_cnt + 1;
               if copy_cnt = C_LINE_WORDS - 1 then
                  last_pf_line <= pf_addr;
                  finish;
               end if;

            -- Held request: BRAM lookup was issued this clock with req_addr
            when S_PEND =>
               state <= S_LOOKUP;

            when S_LOOKUP =>
               if req_we = '1' then
                  -- Write-through (byte stored in the cache by cache_ctrl_proc)
                  if req_addr(0) = '1' then
                     v_be := "10";
                  else
                     v_be := "01";
                  end if;
                  issue('1', std_logic_vector(req_addr(22 downto 1)), v_be,
                        req_data & req_data, x"0000", 1, "000");
                  answered <= '1';     -- posted write
                  state    <= S_WAIT_W;
               elsif hit = '1' then
                  if req_addr(0) = '1' then
                     data_out_reg(7 downto 0) <= dhi_q;
                  else
                     data_out_reg(7 downto 0) <= dlo_q;
                  end if;
                  -- First hit on the last prefetched line: fetch the one after
                  if C_PREFETCH and req_addr(22 downto 4) = last_pf_line(22 downto 4) then
                     pf_want      <= '1';
                     pf_target    <= (req_addr(22 downto 4) + 1) & "0000";
                     last_pf_line <= (others => '1');
                  end if;
                  state <= S_IDLE;
               else
                  -- Read miss: burst the whole line, requested word first back
                  issue('0', std_logic_vector(req_addr(22 downto 4)) & "000", "11",
                        x"0000", x"0000", C_LINE_WORDS, req_addr(3 downto 1));
                  state <= S_WAIT_CRIT;
               end if;

            when S_WAIT_W =>
               if done_ok = '1' then
                  finish;
               end if;

            when S_WAIT_R =>
               if done_ok = '1' then
                  data_out_reg(15 downto 0) <= rbuf(0);
                  if is_long = '1' then
                     data_out_reg(31 downto 16) <= rbuf(1);
                  end if;
                  finish;
               end if;

            when S_WAIT_CRIT =>
               -- done can be seen before crit (separate synchronisers); both
               -- mean the requested word is in rbuf
               if crit_ok = '1' or done_ok = '1' then
                  if req_addr(0) = '1' then
                     data_out_reg(7 downto 0) <= rbuf(to_integer(req_addr(3 downto 1)))(15 downto 8);
                  else
                     data_out_reg(7 downto 0) <= rbuf(to_integer(req_addr(3 downto 1)))(7 downto 0);
                  end if;
                  answered <= '1';
                  if done_ok = '1' then
                     copy_cnt <= (others => '0');
                     state    <= S_COPY;
                  else
                     state    <= S_WAIT_DONE;
                  end if;
               end if;

            when S_WAIT_DONE =>
               if done_ok = '1' then
                  copy_cnt <= (others => '0');
                  state    <= S_COPY;
               end if;

            when S_COPY =>
               -- cache writes happen in cache_ctrl_proc
               copy_cnt <= copy_cnt + 1;
               if copy_cnt = C_LINE_WORDS - 1 then
                  if C_PREFETCH then
                     pf_want   <= '1';
                     pf_target <= (req_addr(22 downto 4) + 1) & "0000";
                  end if;
                  finish;
               end if;

         end case;
      end if;
   end process fsm_proc;

   ---------------------------------------------------------------------------
   -- HyperRAM engine (hr_clk_i)
   ---------------------------------------------------------------------------
   avm_write_o      <= e_write;
   avm_read_o       <= e_read;
   avm_address_o    <= e_address;
   avm_writedata_o  <= e_writedata;
   avm_byteenable_o <= e_byteenable;
   avm_burstcount_o <= e_burstcount;

   engine_proc : process (hr_clk_i)
   begin
      if rising_edge(hr_clk_i) then
         cmd_sync1 <= cmd_tog;
         cmd_sync2 <= cmd_sync1;

         case e_state is
            when E_IDLE =>
               if cmd_sync2 /= cmd_seen then
                  cmd_seen     <= cmd_sync2;
                  -- cmd_* have been stable for at least two HR clocks
                  e_address    <= "0000000000" & cmd_addr;
                  e_writedata  <= cmd_wdata;
                  e_byteenable <= cmd_be;
                  e_burstcount <= "0000" & std_logic_vector(cmd_burst);
                  e_write      <= cmd_we;
                  e_read       <= not cmd_we;
                  e_beat       <= (others => '0');
                  e_state      <= E_CMD;
               end if;

            when E_CMD =>
               if avm_waitrequest_i = '0' then
                  if e_write = '1' then
                     if cmd_burst = 2 then
                        e_writedata <= cmd_wdata_hi;   -- second write beat
                        e_state     <= E_WRITE2;
                     else
                        e_write  <= '0';
                        done_tog <= not done_tog;
                        e_state  <= E_IDLE;
                     end if;
                  else
                     e_read  <= '0';
                     e_state <= E_RDATA;
                  end if;
               end if;

            when E_WRITE2 =>
               if avm_waitrequest_i = '0' then
                  e_write  <= '0';
                  done_tog <= not done_tog;
                  e_state  <= E_IDLE;
               end if;

            when E_RDATA =>
               if avm_readdatavalid_i = '1' then
                  rbuf(to_integer(e_beat(2 downto 0))) <= avm_readdata_i;
                  if e_beat(2 downto 0) = cmd_crit then
                     crit_tog <= not crit_tog;
                  end if;
                  if e_beat = cmd_burst - 1 then
                     done_tog <= not done_tog;
                     e_state  <= E_IDLE;
                  end if;
                  e_beat <= e_beat + 1;
               end if;
         end case;

         if hr_rst_i = '1' then
            e_state <= E_IDLE;
            e_write <= '0';
            e_read  <= '0';
         end if;
      end if;
   end process engine_proc;

end architecture synthesis;
