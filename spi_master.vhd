-------------------------------------------------------------------------------
-- spi_master.vhd
-- Maestro SPI parametrizado. Genera SCLK, SS_N y MOSI; captura MISO.
-- Taller 1 - Electronica Digital II - UPTC
-- Grupo: semilla S = 64  =>  Modo 0 (CPOL=0, CPHA=0), CLKS_PER_HALF=25,
--                            MSB primero, un unico dominio de reloj (CLOCK_50)
-- Nombres: Elkin Felipe Leguizamon Martinez y Angela Yereth Burbano
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity spi_master is
    generic (
        N_BITS        : integer   := 8;     -- ancho de la palabra
        CLKS_PER_HALF : integer   := 25;     -- ciclos de CLOCK_50 por medio periodo de SCLK
        CPOL          : std_logic := '0';    -- polaridad de reposo de SCLK
        CPHA          : std_logic := '0';    -- fase de muestreo
        MSB_FIRST     : boolean   := true    -- orden de bits en el enlace
    );
    port (
        clk      : in  std_logic;                              -- CLOCK_50
        reset    : in  std_logic;                              -- reset sincrono, activo en alto
        start    : in  std_logic;                              -- pulso de un ciclo (desde debounce)
        data_in  : in  std_logic_vector(N_BITS-1 downto 0);    -- SW[7..0]

        sclk     : out std_logic;                              -- GPIO_0[0]
        mosi     : out std_logic;                              -- GPIO_0[2]
        ss_n     : out std_logic;                              -- GPIO_0[6]
        miso     : in  std_logic;                              -- GPIO_0[5]

        busy     : out std_logic;                              -- a LEDR[0]
        done     : out std_logic;                              -- pulso de un ciclo, dato valido
        data_out : out std_logic_vector(N_BITS-1 downto 0)     -- byte recibido (a HEX3-HEX2)
    );
end entity spi_master;

architecture rtl of spi_master is

    type state_t is (ST_REPOSO, ST_PREPARACION, ST_TRANSFERENCIA, ST_LIBERACION);
    signal state : state_t;

    signal half_cnt : integer range 0 to CLKS_PER_HALF-1;
    signal edge_cnt : integer range 0 to 2*N_BITS;

    signal sh_tx : std_logic_vector(N_BITS-1 downto 0);
    signal sh_rx : std_logic_vector(N_BITS-1 downto 0);

    signal sclk_reg     : std_logic;
    signal ss_n_reg      : std_logic;
    signal mosi_reg      : std_logic;
    signal busy_reg      : std_logic;
    signal done_reg      : std_logic;
    signal data_out_reg  : std_logic_vector(N_BITS-1 downto 0);

    -- invierte el orden de los bits de un vector (para soportar LSB_FIRST
    -- reutilizando internamente la misma logica de desplazamiento MSB-first)
    function reverse_vector(v : std_logic_vector) return std_logic_vector is
        variable r : std_logic_vector(v'range);
        constant n : integer := v'length;
    begin
        for i in 0 to n-1 loop
            r(i) := v(n-1-i);
        end loop;
        return r;
    end function;

begin

    sclk     <= sclk_reg;
    ss_n     <= ss_n_reg;
    mosi     <= mosi_reg;
    busy     <= busy_reg;
    done     <= done_reg;
    data_out <= data_out_reg;

    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state        <= ST_REPOSO;
                sclk_reg     <= CPOL;
                ss_n_reg     <= '1';
                mosi_reg     <= '0';
                busy_reg     <= '0';
                done_reg     <= '0';
                half_cnt     <= 0;
                edge_cnt     <= 0;
                sh_tx        <= (others => '0');
                sh_rx        <= (others => '0');
                data_out_reg <= (others => '0');
            else
                done_reg <= '0';  -- por defecto en cada ciclo; se activa un unico ciclo en LIBERACION

                case state is

                    ----------------------------------------------------------
                    when ST_REPOSO =>
                        sclk_reg <= CPOL;
                        ss_n_reg <= '1';
                        busy_reg <= '0';
                        half_cnt <= 0;
                        edge_cnt <= 0;

                        if start = '1' then
                            if MSB_FIRST then
                                sh_tx <= data_in;
                            else
                                sh_tx <= reverse_vector(data_in);
                            end if;
                            sh_rx    <= (others => '0');
                            busy_reg <= '1';
                            ss_n_reg <= '0';
                            state    <= ST_PREPARACION;
                        end if;

                    ----------------------------------------------------------
                    when ST_PREPARACION =>
                        -- con CPHA=0 el primer flanco es de muestreo, asi que
                        -- el primer bit debe estar en MOSI antes de que ocurra
                        if CPHA = '0' then
                            mosi_reg <= sh_tx(N_BITS-1);
                        end if;

                        if half_cnt = CLKS_PER_HALF-1 then
                            half_cnt <= 0;
                            state    <= ST_TRANSFERENCIA;
                        else
                            half_cnt <= half_cnt + 1;
                        end if;

                    ----------------------------------------------------------
                    when ST_TRANSFERENCIA =>
                        if half_cnt = CLKS_PER_HALF-1 then
                            half_cnt <= 0;
                            sclk_reg <= not sclk_reg;
                            edge_cnt <= edge_cnt + 1;

                            -- CPHA=0: flancos impares (1,3,5...) = muestreo
                            -- CPHA=1: flancos pares  (2,4,6...) = muestreo
                            if ((CPHA = '0' and ((edge_cnt+1) mod 2) = 1) or
                                (CPHA = '1' and ((edge_cnt+1) mod 2) = 0)) then
                                -- flanco de muestreo: capturar MISO
                                sh_rx <= sh_rx(N_BITS-2 downto 0) & miso;
                            else
                                -- flanco de cambio de dato: desplazar y sacar el siguiente bit
                                sh_tx    <= sh_tx(N_BITS-2 downto 0) & '0';
                                mosi_reg <= sh_tx(N_BITS-2);
                            end if;

                            if (edge_cnt+1) = 2*N_BITS then
                                state <= ST_LIBERACION;
                            end if;
                        else
                            half_cnt <= half_cnt + 1;
                        end if;

                    ----------------------------------------------------------
                    when ST_LIBERACION =>
                        if half_cnt = CLKS_PER_HALF-1 then
                            half_cnt  <= 0;
                            ss_n_reg  <= '1';
                            busy_reg  <= '0';
                            done_reg  <= '1';
                            if MSB_FIRST then
                                data_out_reg <= sh_rx;
                            else
                                data_out_reg <= reverse_vector(sh_rx);
                            end if;
                            state <= ST_REPOSO;
                        else
                            half_cnt <= half_cnt + 1;
                        end if;

                end case;
            end if;
        end if;
    end process;

end architecture rtl;
