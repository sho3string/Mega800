----------------------------------------------------------------------------------
-- Atari disk image backend
--
-- Extracted from main.vhd.  This module owns ATR image parsing, geometry,
-- logical-sector translation and vdrive block reads.  The SIO protocol and
-- control/metadata CDC remain in main.vhd; sector payload CDC is handled here
-- by a dual-clock sector RAM.
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.vdrives_pkg.all;

entity atari_disk_image is
   generic (
      G_VDNUM : natural
   );
   port (
      qnice_clk_i : in std_logic;

      -- Already synchronized in main.vhd: bit 0 = disk-change toggle,
      -- bit 1 = D1 mounted state.
      vdrive_event_qnice_i : in std_logic_vector(1 downto 0);

      -- Already synchronized in main.vhd: logical-sector request from SIO.
      sector_req_qnice_i        : in std_logic_vector(23 downto 0);
      sector_req_toggle_qnice_i : in std_logic_vector(0 downto 0);

      -- QNICE-side result.  Existing CDC remains in main.vhd.
      sector_done_toggle_qnice_o : out std_logic_vector(0 downto 0);
      sector_service_ok_qnice_o  : out std_logic;
      sector_length_qnice_o      : out unsigned(9 downto 0);
      -- Dual-clock logical-sector RAM read port.
      sector_read_clk_i  : in  std_logic;
      sector_read_addr_i : in  unsigned(8 downto 0);
      sector_read_data_o : out std_logic_vector(7 downto 0);

      -- Parsed image metadata.  Existing CDC remains in main.vhd.
      atr_valid_qnice_o        : out std_logic;
      atr_sector_size_qnice_o  : out unsigned(15 downto 0);
      atr_sector_count_qnice_o : out unsigned(23 downto 0);

      -- vdrives QNICE-domain block interface.
      sd_lba_o       : out vd_vec_array(G_VDNUM - 1 downto 0)(31 downto 0);
      sd_blk_cnt_o   : out vd_vec_array(G_VDNUM - 1 downto 0)(5 downto 0);
      sd_rd_o        : out vd_std_array(G_VDNUM - 1 downto 0);
      sd_wr_o        : out vd_std_array(G_VDNUM - 1 downto 0);
      sd_ack_i       : in  vd_std_array(G_VDNUM - 1 downto 0);
      sd_buff_addr_i : in  std_logic_vector(8 downto 0);
      sd_buff_dout_i : in  std_logic_vector(7 downto 0);
      sd_buff_din_o  : out vd_vec_array(G_VDNUM - 1 downto 0)(7 downto 0);
      sd_buff_wr_i   : in  std_logic
   );
end entity atari_disk_image;

architecture rtl of atari_disk_image is

   type t_atr_block_state is (
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

   type t_atr_block_buffer is array (0 to 511) of std_logic_vector(7 downto 0);

   type t_atr_sector_ram is array (0 to 511) of std_logic_vector(7 downto 0);

   signal atr_sector_ram       : t_atr_sector_ram;
   signal atr_sector_read_data : std_logic_vector(7 downto 0);
   signal atr_sector4_ok       : std_logic := '0';

   attribute ram_style : string;
   attribute ram_style of atr_sector_ram : signal is "block";

   signal atr_sector_number : unsigned(23 downto 0) := to_unsigned(4, 24);
   signal atr_sector_length : unsigned(9 downto 0)  := (others => '0');

   signal atr_byte_offset : unsigned(31 downto 0) := (others => '0');
   signal atr_current_lba : unsigned(31 downto 0) := (others => '0');
   signal atr_lba_offset  : unsigned(8 downto 0)  := (others => '0');

   signal atr_first_chunk : unsigned(9 downto 0) := (others => '0');
   signal atr_remaining   : unsigned(9 downto 0) := (others => '0');
   signal atr_copy_index  : unsigned(9 downto 0) := (others => '0');

   signal atr_sector_ready : std_logic := '0';

   signal atr_block_state  : t_atr_block_state := ATR_IDLE;
   signal atr_block_buffer : t_atr_block_buffer;
   signal atr_header_ok   : std_logic := '0';

   signal disk_change_qnice_d : std_logic := '0';
   signal disk_change_pending : std_logic := '0';

   signal atr_valid        : std_logic := '0';
   signal atr_sector_size  : unsigned(15 downto 0) := (others => '0');
   signal atr_paragraphs   : unsigned(23 downto 0) := (others => '0');
   signal atr_sector_count : unsigned(23 downto 0) := (others => '0');

   signal atr_req_seen_qnice        : std_logic := '0';
   signal atr_sector_service_active : std_logic := '0';
   signal atr_sector_service_ok     : std_logic := '0';
   signal atr_done_toggle_qnice     : std_logic_vector(0 downto 0) := (others => '0');

   -- Local names preserve the original ATR state-machine body verbatim.
   signal vdrive_event_qnice       : std_logic_vector(1 downto 0);
   signal sio_atr_req_sector_qnice : std_logic_vector(23 downto 0);
   signal sio_atr_req_toggle_qnice : std_logic_vector(0 downto 0);

   signal sd_lba      : vd_vec_array(G_VDNUM - 1 downto 0)(31 downto 0);
   signal sd_blk_cnt  : vd_vec_array(G_VDNUM - 1 downto 0)(5 downto 0);
   signal sd_rd       : vd_std_array(G_VDNUM - 1 downto 0);
   signal sd_wr       : vd_std_array(G_VDNUM - 1 downto 0);
   signal sd_ack      : vd_std_array(G_VDNUM - 1 downto 0);
   signal sd_buff_addr : std_logic_vector(8 downto 0);
   signal sd_buff_dout : std_logic_vector(7 downto 0);
   signal sd_buff_din  : vd_vec_array(G_VDNUM - 1 downto 0)(7 downto 0);
   signal sd_buff_wr   : std_logic;

begin

   vdrive_event_qnice       <= vdrive_event_qnice_i;
   sio_atr_req_sector_qnice <= sector_req_qnice_i;
   sio_atr_req_toggle_qnice <= sector_req_toggle_qnice_i;

   sd_ack       <= sd_ack_i;
   sd_buff_addr <= sd_buff_addr_i;
   sd_buff_dout <= sd_buff_dout_i;
   sd_buff_wr   <= sd_buff_wr_i;

   sd_lba_o      <= sd_lba;
   sd_blk_cnt_o  <= sd_blk_cnt;
   sd_rd_o       <= sd_rd;
   sd_wr_o       <= sd_wr;
   sd_buff_din_o <= sd_buff_din;

   sector_done_toggle_qnice_o <= atr_done_toggle_qnice;
   sector_service_ok_qnice_o  <= atr_sector_service_ok;
   sector_length_qnice_o      <= atr_sector_length;
   
   sector_ram_read : process(sector_read_clk_i)
   begin
      if rising_edge(sector_read_clk_i) then
         atr_sector_read_data <=
            atr_sector_ram(to_integer(sector_read_addr_i));
      end if;
   end process;

   sector_read_data_o <= atr_sector_read_data;

   atr_valid_qnice_o        <= atr_valid;
   atr_sector_size_qnice_o  <= atr_sector_size;
   atr_sector_count_qnice_o <= atr_sector_count;

   atr_block_buffer_write : process(qnice_clk_i)
    begin
       if rising_edge(qnice_clk_i) then
    
          if sd_buff_wr = '1' then
             atr_block_buffer(to_integer(unsigned(sd_buff_addr))) <= sd_buff_dout;
          end if;
    
       end if;
    end process;
    
    atr_vdrive : process(qnice_clk_i)
    begin
       if rising_edge(qnice_clk_i) then
          -- defaults
          sd_wr(0)      <= '0';
          sd_buff_din(0) <= (others => '0');
          
          -- Latch a disk-change event until the FSM has consumed it.
          if vdrive_event_qnice(0) /= disk_change_qnice_d then
            disk_change_pending <= '1';
          end if;
    
          -- remember the previous mount-toggle state
          disk_change_qnice_d <= vdrive_event_qnice(0);
          case atr_block_state is
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
                      atr_block_state <= ATR_READ_START;
                   end if;
                
                end if;
             -------------------------------------------------------
             -- Request one 512-byte block, LBA 0
             -------------------------------------------------------
             when ATR_READ_START =>
                sd_lba(0)     <= x"00000000";
                sd_blk_cnt(0) <= "000000";    -- blocks - 1 = 0 => one block
                sd_rd(0)      <= '1';
                atr_block_state <= ATR_WAIT_ACK_HIGH;
    
    
             -------------------------------------------------------
             -- Wait for QNICE to accept the request
             -------------------------------------------------------
             when ATR_WAIT_ACK_HIGH =>
               if sd_ack(0) = '1' then
                  -- Request has been accepted.
                  -- Drop RD now so it cannot be interpreted as another request
                  -- when ACK returns low.
                  sd_rd(0) <= '0';
            
                  atr_block_state <= ATR_WAIT_ACK_LOW;
               end if;
   
             -------------------------------------------------------
             -- Keep request asserted for whole transfer
             -------------------------------------------------------
             when ATR_WAIT_ACK_LOW =>
               if sd_ack(0) = '0' then
                  atr_block_state <= ATR_CHECK_HEADER;
               end if;
 
             -------------------------------------------------------
             -- ATR magic is little-endian $0296:
             --
             -- file byte 0 = $96
             -- file byte 1 = $02
             -------------------------------------------------------
             when ATR_CHECK_HEADER =>
               if atr_block_buffer(0) = x"96" and
                  atr_block_buffer(1) = x"02" then atr_valid <= '1';
            
                  -- bytes 4/5: sector size, little endian
                atr_sector_size <=
                   unsigned(atr_block_buffer(5)) & unsigned(atr_block_buffer(4));
                
                -- bytes 2/3 plus byte 6: paragraph count, little endian
                atr_paragraphs <=
                   unsigned(atr_block_buffer(6)) &
                   unsigned(atr_block_buffer(3)) &
                   unsigned(atr_block_buffer(2));
                else
                  atr_valid       <= '0';
                  atr_sector_size <= (others => '0');
                  atr_paragraphs  <= (others => '0');
            
               end if;
            
               atr_block_state <= ATR_CALC_GEOMETRY;
             
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
               atr_block_state <= ATR_CALC_GEOMETRY_2;

             when ATR_CALC_GEOMETRY_2 =>
                atr_block_state <= ATR_DONE;
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
                   atr_block_state        <= ATR_SERVICE_COMPLETE;
            
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
            
                  atr_block_state <= ATR_SECTOR_PREP;
            
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
            
                  atr_block_state <= ATR_SECTOR_PREP;
            
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
            
                  atr_block_state <= ATR_SECTOR_PREP;
            
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
            
                  atr_block_state <= ATR_SECTOR_PREP;
            
               else
            
                  atr_sector_service_ok <= '0';
                  atr_block_state <= ATR_SERVICE_COMPLETE;
            
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
               atr_block_state <= ATR_SECTOR_READ1_START;

            -------------------------------------------------------
            -- Read first 512-byte LBA.
            -------------------------------------------------------
            when ATR_SECTOR_READ1_START =>
            
               sd_lba(0)     <= std_logic_vector(atr_current_lba);
               sd_blk_cnt(0) <= "000000";
               sd_rd(0)      <= '1';
            
               atr_block_state <= ATR_SECTOR_READ1_WAIT_ACK_HIGH;
            
            
            when ATR_SECTOR_READ1_WAIT_ACK_HIGH =>
               if sd_ack(0) = '1' then
                  sd_rd(0) <= '0';
                  atr_block_state <= ATR_SECTOR_READ1_WAIT_ACK_LOW;
               end if;

            when ATR_SECTOR_READ1_WAIT_ACK_LOW =>
               if sd_ack(0) = '0' then
                  atr_copy_index <= (others => '0');
                  atr_block_state <= ATR_SECTOR_COPY1;
               end if;

            -------------------------------------------------------
            -- Copy first piece, one byte per QNICE clock.
            -------------------------------------------------------
            when ATR_SECTOR_COPY1 =>
               if atr_copy_index < atr_first_chunk then
            
                    atr_sector_ram(to_integer(atr_copy_index)) <=
                       atr_block_buffer(
                          to_integer(unsigned(atr_lba_offset)) +
                          to_integer(atr_copy_index)
                       );
            
                  atr_copy_index <= atr_copy_index + 1;
               else
            
                  atr_copy_index <= (others => '0');
            
                  if atr_remaining = 0 then
                     atr_sector_ready <= '1';
                     atr_block_state   <= ATR_SECTOR_CHECK;
                  else
                     atr_current_lba <= atr_current_lba + 1;
                     atr_block_state  <= ATR_SECTOR_READ2_START;
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
               atr_block_state <= ATR_SECTOR_READ2_WAIT_ACK_HIGH;
            
            
            when ATR_SECTOR_READ2_WAIT_ACK_HIGH =>
               if sd_ack(0) = '1' then
                  sd_rd(0) <= '0';
                  atr_block_state <= ATR_SECTOR_READ2_WAIT_ACK_LOW;
               end if;
            
            
            when ATR_SECTOR_READ2_WAIT_ACK_LOW =>
               if sd_ack(0) = '0' then
                  atr_copy_index <= (others => '0');
                  atr_block_state <= ATR_SECTOR_COPY2;
               end if;
            
            
            -------------------------------------------------------
            -- Copy remaining bytes from start of second LBA.
            -------------------------------------------------------
            when ATR_SECTOR_COPY2 =>
               if atr_copy_index < atr_remaining then
            
                  atr_sector_ram(
                       to_integer(atr_first_chunk + atr_copy_index)
                    ) <= atr_block_buffer(to_integer(atr_copy_index));
            
                  atr_copy_index <= atr_copy_index + 1;
            
               else
            
                  atr_sector_ready <= '1';
                  atr_block_state   <= ATR_SECTOR_CHECK;
            
               end if;
            
            
            -- marks a completed service successful.
            -------------------------------------------------------
            when ATR_SECTOR_CHECK =>
               -------------------------------------------------------
               -- Sector has been completely reconstructed in
                -- atr_sector_ram.
               -------------------------------------------------------
            
               if atr_sector_service_active = '1' then
                  atr_sector_service_ok <= '1';
                  atr_block_state        <= ATR_SERVICE_COMPLETE;
               else
                  atr_block_state <= ATR_DONE;
               end if;
            
            
            when ATR_SERVICE_COMPLETE =>
               -------------------------------------------------------
               -- Result metadata and the sector ram were made
               -- stable in the previous QNICE state.
               --
               -- Toggle completion only now, one QNICE clock later.
               -------------------------------------------------------
            
               atr_done_toggle_qnice(0)  <= not atr_done_toggle_qnice(0);
               atr_sector_service_active <= '0';
               atr_block_state <= ATR_DONE;
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
            
               if disk_change_pending = '1' then atr_block_state <= ATR_IDLE;
            
            
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
            
                     atr_block_state <= ATR_SECTOR_CALC;
            
                  else
            
                     atr_sector_service_ok     <= '0';
                     atr_sector_service_active <= '1';
            
                     atr_block_state <= ATR_SERVICE_COMPLETE;
            
                  end if;
                end if;
            end case;
         end if;
      end process atr_vdrive;

end architecture rtl;
