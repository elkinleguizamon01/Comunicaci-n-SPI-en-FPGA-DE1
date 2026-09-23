library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
 
entity spi_slave is
    generic (
        N_BITS     : integer                        := 8;
        CPOL       : std_logic                       := '0';
        CPHA       : std_logic                       := '0';
        MSB_FIRST  : boolean                         := true;
        ID_ESCLAVO : std_logic_vector(7 downto 0)    := x"9A"   -- (S+90) mod 256, S=64
    );
    port (
        clk      : in  std_logic;                              -- CLOCK_50, unico reloj del diseno
        reset    : in  std_logic;                              -- reset sincrono, activo en alto
 
        sclk_in  : in  std_logic;                              -- GPIO_0[1], señal EXTERNA (dato, no reloj)
        mosi_in  : in  std_logic;                              -- GPIO_0[3], señal EXTERNA
        ss_n_in  : in  std_logic;                              -- GPIO_0[7], señal EXTERNA
        miso     : out std_logic;                              -- GPIO_0[4]
 
        valid    : out std_logic;                              -- pulso de un ciclo: dato recibido listo
        data_out : out std_logic_vector(N_BITS-1 downto 0)     -- byte recibido (a HEX1-HEX0)
    );
end entity spi_slave;
 
architecture rtl of spi_slave is
 
    -- SAMPLE_ON_RISING es una CONSTANTE (CPOL y CPHA se fijan por GENERIC,
    -- es decir, en tiempo de compilacion): true = se muestrea en la subida.
    constant SAMPLE_ON_RISING : boolean := (CPOL = CPHA);
 
    -- sincronizadores de 3 etapas: las dos primeras resuelven metaestabilidad,
    -- la tercera queda disponible para comparar y detectar flancos de forma
    -- segura (item 1 y 2 de la seccion 5.3 de la guia)
    signal sclk_s : std_logic_vector(2 downto 0) := (others => '1');
    signal ss_n_s : std_logic_vector(2 downto 0) := (others => '1');
    signal mosi_s : std_logic_vector(2 downto 0) := (others => '0');
 
    signal ss_falling : std_logic;
    signal ss_rising   : std_logic;
    signal sclk_edge   : std_logic;
 
    signal edge_cnt : integer range 0 to 2*N_BITS;
    signal sh_tx     : std_logic_vector(N_BITS-1 downto 0);
    signal sh_rx     : std_logic_vector(N_BITS-1 downto 0);
 
    signal miso_reg     : std_logic;
    signal valid_reg     : std_logic;
    signal data_out_reg  : std_logic_vector(N_BITS-1 downto 0);
 
    -- misma funcion auxiliar que en el maestro, para soportar LSB_FIRST
    -- reutilizando internamente la logica de desplazamiento MSB-first
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
 
    miso     <= miso_reg;
    valid    <= valid_reg;
    data_out <= data_out_reg;
 
    -- flancos derivados de las muestras YA sincronizadas (indices 2 y 1),
    -- nunca de la señal externa directamente (item 2: SCLK es un dato)
    ss_falling <= '1' when (ss_n_s(2) = '1' and ss_n_s(1) = '0') else '0';
    ss_rising  <= '1' when (ss_n_s(2) = '0' and ss_n_s(1) = '1') else '0';
    sclk_edge  <= '1' when (sclk_s(2) /= sclk_s(1))               else '0';
 
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                sclk_s       <= (others => '1');
                ss_n_s       <= (others => '1');
                mosi_s       <= (others => '0');
                edge_cnt     <= 0;
                sh_tx        <= (others => '0');
                sh_rx        <= (others => '0');
                miso_reg     <= '0';
                valid_reg    <= '0';
                data_out_reg <= (others => '0');
            else
                -- los sincronizadores corren SIEMPRE, en todo estado
                sclk_s <= sclk_s(1 downto 0) & sclk_in;
                ss_n_s <= ss_n_s(1 downto 0) & ss_n_in;
                mosi_s <= mosi_s(1 downto 0) & mosi_in;
 
                valid_reg <= '0';  -- pulso de un ciclo por defecto
 
                ----------------------------------------------------------
                -- item 1: flanco de bajada de SS_N -> inicia transaccion
                ----------------------------------------------------------
                if ss_falling = '1' then
                    if MSB_FIRST then
                        sh_tx <= ID_ESCLAVO;
                    else
                        sh_tx <= reverse_vector(ID_ESCLAVO);
                    end if;
                    edge_cnt <= 0;
                    if CPHA = '0' then
                        -- primer flanco es de muestreo: el bit debe estar listo antes
                        if MSB_FIRST then
                            miso_reg <= ID_ESCLAVO(N_BITS-1);
                        else
                            miso_reg <= ID_ESCLAVO(0);
                        end if;
                    end if;
 
                ----------------------------------------------------------
                -- item 4: flanco de subida de SS_N -> entrega el dato recibido
                ----------------------------------------------------------
                elsif ss_rising = '1' then
                    if MSB_FIRST then
                        data_out_reg <= sh_rx;
                    else
                        data_out_reg <= reverse_vector(sh_rx);
                    end if;
                    valid_reg <= '1';
                    miso_reg  <= '0';  -- reposo: no controla MISO con datos validos
 
                ----------------------------------------------------------
                -- item 2 y 3: seleccionado (SS_N activo) y llega un flanco de SCLK
                ----------------------------------------------------------
                elsif ss_n_s(1) = '0' then
                    if sclk_edge = '1' then
                        edge_cnt <= edge_cnt + 1;
 
                        if (sclk_s(1) = '1' and SAMPLE_ON_RISING) or
                           (sclk_s(1) = '0' and not SAMPLE_ON_RISING) then
                            -- flanco de muestreo: capturar MOSI ya sincronizado
                            sh_rx <= sh_rx(N_BITS-2 downto 0) & mosi_s(1);
                        else
                            -- flanco de cambio: desplazar sh_tx y sacar el siguiente bit
                            sh_tx    <= sh_tx(N_BITS-2 downto 0) & '0';
                            miso_reg <= sh_tx(N_BITS-2);
                        end if;
                    end if;
 
                ----------------------------------------------------------
                -- deseleccionado, sin transicion en este ciclo: reposo
                ----------------------------------------------------------
                else
                    miso_reg <= '0';
                    edge_cnt <= 0;
                end if;
            end if;
        end if;
    end process;
 
end architecture rtl;
 
