library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.qnice_csr_pkg.all;


entity cart_loader is
   port (
      -----------------------------------------------------------------------
      -- QNICE interface
      -----------------------------------------------------------------------
      qnice_clk_i  : in  std_logic;
      qnice_rst_i  : in  std_logic;
      qnice_addr_i : in  std_logic_vector(27 downto 0);
      qnice_data_i : in  std_logic_vector(15 downto 0);
      qnice_ce_i   : in  std_logic;
      qnice_we_i   : in  std_logic;
      qnice_data_o : out std_logic_vector(15 downto 0);
      qnice_wait_o : out std_logic;

      -----------------------------------------------------------------------
      -- Cartridge payload DMA interface
      -----------------------------------------------------------------------
      dma_addr_o       : out std_logic_vector(25 downto 0);
      dma_data_o       : out std_logic_vector(7 downto 0);
      dma_read_o       : out std_logic;
      dma_req_toggle_o : out std_logic;

      dma_ack_toggle_i : in  std_logic;
      dma_readback_i   : in  std_logic_vector(7 downto 0)
   );
end entity cart_loader;


architecture beh of cart_loader is

   ---------------------------------------------------------------------------
   -- M2M CSR
   ---------------------------------------------------------------------------

   signal qnice_req_status : std_logic_vector(3 downto 0);
   signal qnice_req_length : std_logic_vector(22 downto 0);

   signal qnice_csr_data : std_logic_vector(15 downto 0);
   signal qnice_csr_wait : std_logic;
   signal qnice_csr      : std_logic;

   signal qnice_resp_status : std_logic_vector(3 downto 0)
                              := C_CSR_RESP_IDLE;

   signal qnice_resp_error : std_logic_vector(3 downto 0)
                             := (others => '0');

   signal qnice_resp_address : std_logic_vector(22 downto 0)
                               := (others => '0');


   ---------------------------------------------------------------------------
   -- Cartridge mode selected by QNICE
   --
   -- $00 = no cartridge
   -- $01 = Standard 8K
   -- $21 = Standard 16K
   ---------------------------------------------------------------------------

   signal cart_mode : std_logic_vector(7 downto 0) := x"00";


   ---------------------------------------------------------------------------
   -- DMA
   ---------------------------------------------------------------------------

   signal dma_addr_reg       : std_logic_vector(25 downto 0)
                               := (others => '0');

   signal dma_data_reg       : std_logic_vector(7 downto 0)
                               := (others => '0');

   signal dma_req_toggle_reg : std_logic := '0';

   -- ACK synchronizer into QNICE clock domain
   signal dma_ack_sync1 : std_logic := '0';
   signal dma_ack_sync2 : std_logic := '0';
   signal dma_ack_seen  : std_logic := '0';


   ---------------------------------------------------------------------------
   -- Diagnostic
   --
   -- Exactly ONE payload byte is allowed to generate a DMA transaction.
   ---------------------------------------------------------------------------

   signal first_payload_seen : std_logic := '0';


   ---------------------------------------------------------------------------
   -- WAIT for streamed payload accesses
   ---------------------------------------------------------------------------

   signal qnice_wait_reg : std_logic := '0';


   ---------------------------------------------------------------------------
   -- Payload state machine
   ---------------------------------------------------------------------------

   type state_t is (
      IDLE_ST,
      DMA_WAIT_ST,
      BUS_RELEASE_ST
   );

   signal state : state_t := IDLE_ST;


   ---------------------------------------------------------------------------
   -- CSR constants
   ---------------------------------------------------------------------------

   constant C_CSR_RESP_OK : std_logic_vector(3 downto 0) := x"2";

   constant C_ERROR_STRINGS : string_vector(0 to 15) := (
      0      => "OK                 \n",
      1      => "Framework error    \n",
      others => "Unknown error      \n"
   );


begin

   ---------------------------------------------------------------------------
   -- DMA outputs
   ---------------------------------------------------------------------------

   dma_addr_o       <= dma_addr_reg;
   dma_data_o       <= dma_data_reg;
   dma_read_o       <= '0';
   dma_req_toggle_o <= dma_req_toggle_reg;


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
   -- QNICE bus
   ---------------------------------------------------------------------------

   process(all)
   begin

      qnice_data_o <= (others => '0');
      qnice_wait_o <= '0';

      if qnice_ce_i = '1' then

         ---------------------------------------------------------------
         -- Private cartridge mode register
         ---------------------------------------------------------------

         if qnice_addr_i = x"FFFE000" then
            qnice_data_o <= x"00" & cart_mode;
            qnice_wait_o <= '0';


         ---------------------------------------------------------------
         -- Framework CSR
         ---------------------------------------------------------------

         elsif qnice_csr = '1' then
            qnice_data_o <= qnice_csr_data;
            qnice_wait_o <= qnice_csr_wait;


         ---------------------------------------------------------------
         -- CAR payload stream
         ---------------------------------------------------------------

         else
            qnice_wait_o <= qnice_wait_reg;
         end if;
      end if;
   end process;


   ---------------------------------------------------------------------------
   -- Loader controller
   ---------------------------------------------------------------------------

   process(qnice_clk_i)
   begin

      if falling_edge(qnice_clk_i) then

         --------------------------------------------------------------------
         -- Synchronise Atari DMA acknowledge into QNICE domain
         --------------------------------------------------------------------

         dma_ack_sync1 <= dma_ack_toggle_i;
         dma_ack_sync2 <= dma_ack_sync1;


         --------------------------------------------------------------------
         -- Reset
         --------------------------------------------------------------------

         if qnice_rst_i = '1' then
            qnice_resp_status  <= C_CSR_RESP_IDLE;
            qnice_resp_error   <= (others => '0');
            qnice_resp_address <= (others => '0');

            cart_mode <= x"00";

            dma_addr_reg       <= (others => '0');
            dma_data_reg       <= (others => '0');
            dma_req_toggle_reg <= '0';

            dma_ack_seen <= '0';
            first_payload_seen <= '0';
            qnice_wait_reg <= '0';
            state <= IDLE_ST;


         else

            ----------------------------------------------------------------
            -- Private cartridge mode register
            ----------------------------------------------------------------

            if qnice_ce_i = '1' and
               qnice_we_i = '1' and
               qnice_addr_i = x"FFFE000" then
               cart_mode <= qnice_data_i(7 downto 0);

            end if;


            ----------------------------------------------------------------
            -- CSR controller
            ----------------------------------------------------------------

            case qnice_req_status is

               when C_CSR_REQ_LDNG =>
                  qnice_resp_status <= C_CSR_RESP_PARSING;
                  qnice_resp_error  <= (others => '0');


               when C_CSR_REQ_OK =>
                  qnice_resp_status <= C_CSR_RESP_OK;
                  qnice_resp_error  <= (others => '0');


               when others =>
                  if qnice_req_status = C_CSR_REQ_IDLE then
                     qnice_resp_status <= C_CSR_RESP_IDLE;
                  end if;
            end case;


            ----------------------------------------------------------------
            -- CAR payload stream
            --
            -- DIAGNOSTIC:
            --
            -- FIRST payload transaction:
            --     issue exactly ONE DMA write and wait for ACK.
            --
            -- ALL subsequent payload transactions:
            --     consume without DMA.
            ----------------------------------------------------------------

            case state is

               -------------------------------------------------------------
               -- Wait for streamed payload byte
               -------------------------------------------------------------

               when IDLE_ST =>
                  qnice_wait_reg <= '0';
                  
                  if qnice_ce_i = '1' and
                     qnice_we_i = '1' and
                     qnice_csr = '0' and
                     qnice_addr_i /= x"FFFE000" then

                     if first_payload_seen = '0' then

                        ---------------------------------------------------
                        -- FIRST payload byte only.
                        ---------------------------------------------------

                        first_payload_seen <= '1';
                        
                        -- Keep the incoming stream address visible in CSR
                        -- for diagnostics.
                        qnice_resp_address <= qnice_addr_i(22 downto 0);

                        ---------------------------------------------------
                        -- Hold this QNICE transaction until DMA completes.
                        ---------------------------------------------------

                        qnice_wait_reg <= '1';

                        ---------------------------------------------------
                        -- Cartridge backing RAM:
                        --
                        -- DMA byte address =
                        --
                        --     $0800000 + QNICE stream address
                        ---------------------------------------------------

                        dma_addr_reg <= std_logic_vector(
                           to_unsigned(16#2800000#, 26)
                        );

                        dma_data_reg <= qnice_data_i(7 downto 0);

                        ---------------------------------------------------
                        -- Establish current ACK phase BEFORE toggling REQ.
                        ---------------------------------------------------

                        dma_ack_seen <= dma_ack_sync2;

                        ---------------------------------------------------
                        -- Launch exactly one DMA request.
                        ---------------------------------------------------

                        dma_req_toggle_reg <= not dma_req_toggle_reg;
                        state <= DMA_WAIT_ST;


                     else

                        ---------------------------------------------------
                        -- Every remaining payload byte:
                        --
                        -- NO DMA.
                        ---------------------------------------------------

                        qnice_wait_reg <= '0';
                        state <= BUS_RELEASE_ST;

                     end if;

                  end if;


               -------------------------------------------------------------
               -- Wait for Atari side to acknowledge our ONE DMA request.
               -------------------------------------------------------------

               when DMA_WAIT_ST =>

                  qnice_wait_reg <= '1';

                  if dma_ack_sync2 /= dma_ack_seen then
                     dma_ack_seen <= dma_ack_sync2;
                     qnice_wait_reg <= '0';
                     state <= BUS_RELEASE_ST;

                  end if;


               -------------------------------------------------------------
               -- Release completed QNICE transaction.
               -------------------------------------------------------------

               when BUS_RELEASE_ST =>
                  qnice_wait_reg <= '0';
                  state <= IDLE_ST;

            end case;
         end if;
      end if;
   end process;


end architecture beh;