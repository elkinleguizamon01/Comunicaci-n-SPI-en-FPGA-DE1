library ieee;
use ieee.std_logic_1164.all;
 
entity top_master_test is
    port (
        CLOCK_50 : in  std_logic;
        SW       : in  std_logic_vector(8 downto 0);
        KEY      : in  std_logic_vector(1 downto 0);
        LEDR     : out std_logic_vector(3 downto 0)
    );
end entity top_master_test;
 
architecture test of top_master_test is
 
    signal reset_i    : std_logic;
    signal start_i    : std_logic;
    signal key0_sync  : std_logic_vector(2 downto 0) := (others => '1');
 
    signal sclk_i, mosi_i, ss_n_i, busy_i, done_i : std_logic;
    signal data_out_i : std_logic_vector(7 downto 0);
 
begin
 
    -- KEY(1) es activo en bajo -> reset_i activo en alto, tal como exige
    -- el maestro (reset sincrono, activo en alto)
    reset_i <= not KEY(1);
 
    -- generador de un pulso de un solo ciclo a partir de KEY(0).
    -- ESTO ES SOLO PARA ESTA PRUEBA VISUAL: no es antirrebote real,
    -- se reemplaza por debounce.vhd en la Fase 2 del taller.
    process(CLOCK_50)
    begin
        if rising_edge(CLOCK_50) then
            key0_sync <= key0_sync(1 downto 0) & KEY(0);
        end if;
    end process;
    start_i <= '1' when (key0_sync(2) = '1' and key0_sync(1) = '0') else '0';
 
    u_master : entity work.spi_master
        generic map (
            N_BITS        => 8,
            CLKS_PER_HALF => 12_500_000,  -- SCLK ~2 Hz, SOLO para esta prueba
            CPOL          => '0',          -- valor del grupo (S=64, modo 0)
            CPHA          => '0',          -- valor del grupo (S=64, modo 0)
            MSB_FIRST     => true          -- valor del grupo (S=64)
        )
        port map (
            clk      => CLOCK_50,
            reset    => reset_i,
            start    => start_i,
            data_in  => SW(7 downto 0),
            sclk     => sclk_i,
            mosi     => mosi_i,
            ss_n     => ss_n_i,
            miso     => SW(8),
            busy     => busy_i,
            done     => done_i,
            data_out => data_out_i
        );
 
    LEDR(0) <= sclk_i;
    LEDR(1) <= mosi_i;
    LEDR(2) <= ss_n_i;
    LEDR(3) <= busy_i;
 
end architecture test;
 
