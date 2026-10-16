-- Atari CAS reader and standard FSK playback producer.
-- QNICE domain. One 32-bit tape FIFO entry is transferred at a time using
-- a toggle/acknowledge handshake to the main-clock domain.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity atari_cas is
   generic ( TAPE_CLOCK_HZ : positive := 48000000 );
   port (
      qnice_clk_i          : in std_logic;
      reset_i              : in std_logic;
      cas_change_toggle_i  : in std_logic;
      cas_mounted_i        : in std_logic;
      cas_size_i           : in std_logic_vector(31 downto 0);
      sd_lba_o             : out std_logic_vector(31 downto 0);
      sd_blk_cnt_o         : out std_logic_vector(5 downto 0);
      sd_rd_o              : out std_logic;
      sd_ack_i             : in std_logic;
      sd_buff_addr_i       : in std_logic_vector(8 downto 0);
      sd_buff_dout_i       : in std_logic_vector(7 downto 0);
      sd_buff_wr_i         : in std_logic;
      sd_buff_cas_i        : in std_logic;
      cas_valid_o          : out std_logic;
      cas_error_o          : out std_logic;
      cas_position_o       : out std_logic_vector(31 downto 0);
      cas_baud_o           : out std_logic_vector(15 downto 0);
      cas_data_chunk_o     : out std_logic;
      cas_chunk_length_o   : out std_logic_vector(15 downto 0);
      cas_chunk_silence_o  : out std_logic_vector(15 downto 0);
      tape_word_o          : out std_logic_vector(31 downto 0);
      tape_request_toggle_o: out std_logic;
      tape_ack_toggle_i    : in std_logic
   );
end entity;

architecture rtl of atari_cas is
   type block_t is array (0 to 511) of std_logic_vector(7 downto 0);
   signal block_ram : block_t;
   type state_t is (idle, read_header, fetch, wait_ack_high, wait_ack_low,
                    header_byte, decode_header, skip_chunk, data_chunk,
                    start_marker, silence_emit, payload_read, payload_byte, serial_emit,
                    queue_entry, wait_queue, finished, invalid);
   signal state : state_t := idle;
   signal after_fetch : state_t := read_header;
   signal after_queue : state_t := read_header;
   signal change_d, change_pending : std_logic := '0';
   signal position : unsigned(31 downto 0) := (others => '0');
   signal cached_lba : unsigned(22 downto 0) := (others => '0');
   signal cache_valid : std_logic := '0';
   signal header : std_logic_vector(63 downto 0) := (others => '0');
   signal header_index : integer range 0 to 7 := 0;
   signal chunk_remaining : unsigned(15 downto 0) := (others => '0');
   signal file_size : unsigned(31 downto 0) := (others => '0');
   signal valid, error : std_logic := '0';
   signal baud : std_logic_vector(15 downto 0) := x"0258";
   signal bit_ticks : unsigned(30 downto 0) := to_unsigned(TAPE_CLOCK_HZ / 600,31);
   signal data_chunk_seen : std_logic := '0';
   signal chunk_length, chunk_silence : std_logic_vector(15 downto 0) := (others => '0');
   signal silence_remaining : unsigned(15 downto 0) := (others => '0');
   signal byte_value, serial_byte : std_logic_vector(7 downto 0) := (others => '0');
   signal serial_index : integer range 0 to 10 := 0;
   signal lba_reg : std_logic_vector(31 downto 0) := (others => '0');
   signal rd_reg : std_logic := '0';
   signal first_header : std_logic := '1';
   signal tape_word : std_logic_vector(31 downto 0) := (others => '0');
   signal tape_request : std_logic := '0';
   signal tape_ack_sync : std_logic_vector(2 downto 0) := (others => '0');
   signal entry_word : std_logic_vector(31 downto 0) := (others => '0');
   signal queued_toggle : std_logic := '0';

   function duration_word(cycles : unsigned(30 downto 0); level : std_logic)
      return std_logic_vector is
   begin
      return std_logic_vector(cycles) & level;
   end function;
begin
   sd_lba_o <= lba_reg;
   sd_blk_cnt_o <= (others => '0');
   sd_rd_o <= rd_reg;
   cas_valid_o <= valid;
   cas_error_o <= error;
   cas_position_o <= std_logic_vector(position);
   cas_baud_o <= baud;
   cas_data_chunk_o <= data_chunk_seen;
   cas_chunk_length_o <= chunk_length;
   cas_chunk_silence_o <= chunk_silence;
   tape_word_o <= tape_word;
   tape_request_toggle_o <= tape_request;

   process(qnice_clk_i)
      variable sig : std_logic_vector(31 downto 0);
      variable len : unsigned(15 downto 0);
      variable aux : std_logic_vector(15 downto 0);
      variable end_pos : unsigned(31 downto 0);
      variable slice_ms : natural;
      variable level : std_logic;
   begin
      if rising_edge(qnice_clk_i) then
         tape_ack_sync <= tape_ack_sync(1 downto 0) & tape_ack_toggle_i;
         if sd_buff_wr_i = '1' and sd_buff_cas_i = '1' then
            block_ram(to_integer(unsigned(sd_buff_addr_i))) <= sd_buff_dout_i;
         end if;
         if cas_change_toggle_i /= change_d then
            change_pending <= '1';
         end if;
         change_d <= cas_change_toggle_i;

         if reset_i = '1' then
            state <= idle;
            rd_reg <= '0';
            valid <= '0';
            error <= '0';
            cache_valid <= '0';
            change_pending <= '0';
         elsif change_pending = '1' then
            -- Do not start another tape until the previous outstanding entry
            -- has been accepted. main.vhd resets its FIFO on mount change.
            if tape_request = tape_ack_sync(2) then
               change_pending <= '0';
               rd_reg <= '0';
               cache_valid <= '0';
               valid <= '0';
               error <= '0';
               data_chunk_seen <= '0';
               position <= (others => '0');
               file_size <= unsigned(cas_size_i);
               first_header <= '1';
               header_index <= 0;
               baud <= x"0258";
               bit_ticks <= to_unsigned(TAPE_CLOCK_HZ / 600,31);
               if cas_mounted_i = '1' and unsigned(cas_size_i) >= 8 then
                  state <= read_header;
               else
                  state <= idle;
               end if;
            end if;
         else
            case state is
               when idle => null;
               when read_header | payload_read =>
                  if position >= file_size then
                     if state = read_header then state <= finished;
                     else state <= invalid; end if;
                  elsif cache_valid = '0' or cached_lba /= position(31 downto 9) then
                     lba_reg <= std_logic_vector(shift_right(position, 9));
                     after_fetch <= state;
                     state <= fetch;
                  else
                     byte_value <= block_ram(to_integer(position(8 downto 0)));
                     if state = read_header then state <= header_byte;
                     else state <= payload_byte; end if;
                  end if;
               when fetch =>
                  rd_reg <= '1';
                  state <= wait_ack_high;
               when wait_ack_high =>
                  if sd_ack_i = '1' then
                     rd_reg <= '0';
                     state <= wait_ack_low;
                  end if;
               when wait_ack_low =>
                  if sd_ack_i = '0' then
                     cached_lba <= position(31 downto 9);
                     cache_valid <= '1';
                     state <= after_fetch;
                  end if;
               when header_byte =>
                  header(header_index*8+7 downto header_index*8) <= byte_value;
                  position <= position + 1;
                  if header_index = 7 then
                     header_index <= 0;
                     state <= decode_header;
                  else
                     header_index <= header_index + 1;
                     state <= read_header;
                  end if;
               when decode_header =>
                  sig := header(31 downto 0);
                  len := unsigned(header(47 downto 32));
                  aux := header(63 downto 48);
                  end_pos := position + resize(len,32);
                  if end_pos < position or end_pos > file_size then
                     state <= invalid;
                  elsif first_header = '1' then
                     if sig = x"494A5546" then
                        first_header <= '0';
                        chunk_remaining <= len;
                        state <= skip_chunk;
                     else state <= invalid; end if;
                  elsif sig = x"64756162" then
                     if len /= 0 then state <= invalid;
                     elsif unsigned(aux) = 300 then
                        baud <= aux;
                        bit_ticks <= to_unsigned(TAPE_CLOCK_HZ / 300,31);
                        state <= read_header;
                     elsif unsigned(aux) = 600 then
                        baud <= aux;
                        bit_ticks <= to_unsigned(TAPE_CLOCK_HZ / 600,31);
                        state <= read_header;
                     elsif unsigned(aux) = 1200 then
                        baud <= aux;
                        bit_ticks <= to_unsigned(TAPE_CLOCK_HZ / 1200,31);
                        state <= read_header;
                     elsif unsigned(aux) = 2400 then
                        baud <= aux;
                        bit_ticks <= to_unsigned(TAPE_CLOCK_HZ / 2400,31);
                        state <= read_header;
                     else
                        -- Unsupported baud rates must not silently play at 600.
                        state <= invalid;
                     end if;
                  elsif sig = x"61746164" then
                     valid <= '1';
                     data_chunk_seen <= '1';
                     chunk_length <= std_logic_vector(len);
                     chunk_silence <= aux;
                     chunk_remaining <= len;
                     silence_remaining <= unsigned(aux);
                     state <= start_marker;
                  else
                     -- FSK/PWM chunks require their own decoder; skip for now.
                     chunk_remaining <= len;
                     state <= skip_chunk;
                  end if;
               when skip_chunk =>
                  if chunk_remaining = 0 then
                     if position = file_size then state <= finished;
                     else state <= read_header; end if;
                  else
                     position <= position + resize(chunk_remaining,32);
                     chunk_remaining <= (others => '0');
                  end if;
               when start_marker =>
                  -- tape_handler special entry: active FSK, not PWM.
                  entry_word <= x"00000001";
                  after_queue <= silence_emit;
                  state <= queue_entry;
               when silence_emit =>
                  if silence_remaining = 0 then
                     state <= data_chunk;
                  else
                     if silence_remaining > 100 then slice_ms := 100;
                     else slice_ms := to_integer(silence_remaining); end if;
                     silence_remaining <= silence_remaining - to_unsigned(slice_ms,16);
                     entry_word <= duration_word(to_unsigned((TAPE_CLOCK_HZ / 1000) * slice_ms,31),'1');
                     after_queue <= silence_emit;
                     state <= queue_entry;
                  end if;
               when data_chunk =>
                  if chunk_remaining = 0 then
                     if position = file_size then state <= finished;
                     else state <= read_header; end if;
                  else
                     state <= payload_read;
                  end if;
               when payload_byte =>
                  serial_byte <= byte_value;
                  serial_index <= 0;
                  position <= position + 1;
                  chunk_remaining <= chunk_remaining - 1;
                  state <= serial_emit;
               when serial_emit =>
                  if serial_index = 0 then level := '0';
                  elsif serial_index <= 8 then level := serial_byte(serial_index - 1);
                  else level := '1'; end if;
                  entry_word <= duration_word(bit_ticks,level);
                  if serial_index = 9 then
                     after_queue <= data_chunk;
                  else
                     serial_index <= serial_index + 1;
                     after_queue <= serial_emit;
                  end if;
                  state <= queue_entry;
               when queue_entry =>
                  if tape_request = tape_ack_sync(2) then
                     tape_word <= entry_word;
                     tape_request <= not tape_request;
                     state <= wait_queue;
                  end if;
               when wait_queue =>
                  if tape_request = tape_ack_sync(2) then
                     state <= after_queue;
                  end if;
               when finished => null;
               when invalid =>
                  error <= '1';
                  valid <= '0';
            end case;
         end if;
      end if;
   end process;
end architecture;
