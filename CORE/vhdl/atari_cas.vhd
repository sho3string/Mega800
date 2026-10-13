-- Atari CAS virtual-drive reader, stage 1.
-- Read-only CAS validation and sequential chunk scanning.
-- No tape FIFO output in this stage.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity atari_cas is
   port (
      qnice_clk_i          : in  std_logic;
      reset_i              : in  std_logic;
      cas_change_toggle_i  : in  std_logic;
      cas_mounted_i        : in  std_logic;
      cas_size_i           : in  std_logic_vector(31 downto 0);
      sd_lba_o             : out std_logic_vector(31 downto 0);
      sd_blk_cnt_o         : out std_logic_vector(5 downto 0);
      sd_rd_o              : out std_logic;
      sd_ack_i             : in  std_logic;
      sd_buff_addr_i       : in  std_logic_vector(8 downto 0);
      sd_buff_dout_i       : in  std_logic_vector(7 downto 0);
      sd_buff_wr_i         : in  std_logic;
      -- Assert only when the shared vdrive transfer belongs to CAS.
      sd_buff_cas_i        : in  std_logic;
      cas_valid_o          : out std_logic;
      cas_error_o          : out std_logic;
      cas_position_o       : out std_logic_vector(31 downto 0);
      cas_baud_o           : out std_logic_vector(15 downto 0);
      cas_data_chunk_o     : out std_logic;
      cas_chunk_length_o   : out std_logic_vector(15 downto 0);
      cas_chunk_silence_o  : out std_logic_vector(15 downto 0)
   );
end entity;

architecture rtl of atari_cas is
   type block_t is array (0 to 511) of std_logic_vector(7 downto 0);
   signal block_ram : block_t;
   type state_t is (idle, fetch, wait_ack_high, wait_ack_low,
                    read_byte, consume_byte, decode_header, skip_chunk,
                    data_chunk, finished, invalid);
   signal state : state_t := idle;
   signal after_fetch : state_t := read_byte;
   signal change_d : std_logic := '0';
   signal change_pending : std_logic := '0';
   signal position : unsigned(31 downto 0) := (others => '0');
   signal cached_lba : unsigned(22 downto 0) := (others => '0');
   signal cache_valid : std_logic := '0';
   signal header : std_logic_vector(63 downto 0) := (others => '0');
   signal header_index : integer range 0 to 7 := 0;
   signal chunk_remaining : unsigned(15 downto 0) := (others => '0');
   signal file_size : unsigned(31 downto 0) := (others => '0');
   signal valid : std_logic := '0';
   signal error : std_logic := '0';
   signal baud : std_logic_vector(15 downto 0) := x"0258";
   signal data_chunk_seen : std_logic := '0';
   signal chunk_length : std_logic_vector(15 downto 0) := (others => '0');
   signal chunk_silence : std_logic_vector(15 downto 0) := (others => '0');
   signal byte_value : std_logic_vector(7 downto 0) := (others => '0');
   signal lba_reg : std_logic_vector(31 downto 0) := (others => '0');
   signal rd_reg : std_logic := '0';
   signal next_state : state_t := read_byte;
   signal first_header : std_logic := '1';
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

   process(qnice_clk_i)
      variable sig : std_logic_vector(31 downto 0);
      variable len : unsigned(15 downto 0);
      variable aux : std_logic_vector(15 downto 0);
      variable end_pos : unsigned(31 downto 0);
   begin
      if rising_edge(qnice_clk_i) then
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
            if cas_mounted_i = '1' and unsigned(cas_size_i) >= 8 then
               state <= read_byte;
            else
               state <= idle;
            end if;
         else
            case state is
               when idle => null;
               when read_byte =>
                  if position >= file_size then
                     state <= finished;
                  elsif cache_valid = '0' or cached_lba /= position(31 downto 9) then
                     lba_reg <= std_logic_vector(shift_right(position, 9));
                     state <= fetch;
                  else
                     byte_value <= block_ram(to_integer(position(8 downto 0)));
                     state <= consume_byte;
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
                     state <= read_byte;
                  end if;
               when consume_byte =>
                  header(header_index*8+7 downto header_index*8) <= byte_value;
                  position <= position + 1;
                  if header_index = 7 then
                     header_index <= 0;
                     state <= decode_header;
                  else
                     header_index <= header_index + 1;
                     state <= read_byte;
                  end if;
               when decode_header =>
                  sig := header(31 downto 0);
                  len := unsigned(header(47 downto 32));
                  aux := header(63 downto 48);
                  end_pos := position + resize(len, 32);
                  if end_pos < position or end_pos > file_size then
                     state <= invalid;
                  elsif first_header = '1' then
                     if sig = x"494A5546" then -- FUJI, little endian
                        first_header <= '0';
                        chunk_remaining <= len;
                        state <= skip_chunk;
                     else
                        state <= invalid;
                     end if;
                  elsif sig = x"64756162" then -- baud
                     if len /= 0 or unsigned(aux) = 0 then
                        state <= invalid;
                     else
                        baud <= aux;
                        state <= read_byte;
                     end if;
                  elsif sig = x"61746164" then -- data
                     valid <= '1';
                     data_chunk_seen <= '1';
                     chunk_length <= std_logic_vector(len);
                     chunk_silence <= aux;
                     chunk_remaining <= len;
                     state <= data_chunk;
                  else
                     -- Stage 1: skip other chunk payloads, including FSK/PWM.
                     chunk_remaining <= len;
                     state <= skip_chunk;
                  end if;
               when skip_chunk =>
                  if chunk_remaining = 0 then
                     if position = file_size then
                        state <= finished;
                     else
                        state <= read_byte;
                     end if;
                  else
                     -- Skip without reading payload bytes; next read refills as needed.
                     position <= position + resize(chunk_remaining, 32);
                     chunk_remaining <= (others => '0');
                  end if;
               when data_chunk =>
                  -- Stage 1 validation only. The playback stage will consume bytes.
                  if chunk_remaining = 0 then
                     if position = file_size then
                        state <= finished;
                     else
                        state <= read_byte;
                     end if;
                  else
                     position <= position + resize(chunk_remaining, 32);
                     chunk_remaining <= (others => '0');
                  end if;
               when finished => null;
               when invalid =>
                  error <= '1';
                  valid <= '0';
               when others => state <= invalid;
            end case;
         end if;
      end if;
   end process;
end architecture;
