LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

ENTITY i2c_master_tb IS
END ENTITY i2c_master_tb;

ARCHITECTURE testbench OF i2c_master_tb IS

  CONSTANT CLK_PERIOD : TIME := 20 ns; -- Системна частота 50 МГц

  SIGNAL clk          : STD_LOGIC := '0';
  SIGNAL rst          : STD_LOGIC := '0';
  SIGNAL start        : STD_LOGIC := '0';
  SIGNAL rw           : STD_LOGIC := '0';
  SIGNAL addr         : STD_LOGIC_VECTOR(6 DOWNTO 0) := (OTHERS => '0');
  SIGNAL data_in      : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL scl          : STD_LOGIC := 'H';
  SIGNAL sda          : STD_LOGIC := 'H';
  SIGNAL busy         : STD_LOGIC;
  SIGNAL ack_error    : STD_LOGIC;
  SIGNAL done         : STD_LOGIC;
  SIGNAL data_out     : STD_LOGIC_VECTOR(7 DOWNTO 0);

  SIGNAL slave_drv    : STD_LOGIC := 'Z';
  SIGNAL sim_finished : BOOLEAN := FALSE;

BEGIN

  -- Імітація підтягуючих резисторів (Pull-up) та драйвера Slave
  scl <= 'H';
  sda <= 'H';
  sda <= slave_drv;

  -- Неперервна генерація тактового сигналу 50 МГц
  clk <= NOT clk AFTER CLK_PERIOD / 2 WHEN NOT sim_finished ELSE '0';

  -- Екземпляр тестованого контролера (UUT)
  uut : ENTITY work.i2c_master
    GENERIC MAP (
      CLK_DIV => 4
    )
    PORT MAP (
      clk       => clk,
      rst       => rst,
      start     => start,
      rw        => rw,
      addr      => addr,
      data_in   => data_in,
      scl       => scl,
      sda       => sda,
      busy      => busy,
      ack_error => ack_error,
      done      => done,
      data_out  => data_out
    );

  -- Поведінкова модель веденого пристрою (I2C Slave, адреса 0x38)
  slave_model : PROCESS
    VARIABLE rx_frame   : STD_LOGIC_VECTOR(7 DOWNTO 0);
    VARIABLE tx_pattern : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"C3";
  BEGIN
    slave_drv <= 'Z';
    WAIT UNTIL FALLING_EDGE(sda) AND TO_X01(scl) = '1';

    -- Прийом адресного кадру (7 біт адреси + біт R/W)
    FOR idx IN 7 DOWNTO 0 LOOP
      WAIT UNTIL RISING_EDGE(scl);
      rx_frame(idx) := TO_X01(sda);
    END LOOP;

    IF rx_frame(7 DOWNTO 1) = "0111000" THEN
      -- Підтвердження адреси (ACK)
      WAIT UNTIL FALLING_EDGE(scl);
      slave_drv <= '0';
      WAIT UNTIL FALLING_EDGE(scl);
      slave_drv <= 'Z';

      IF rx_frame(0) = '0' THEN
        -- Операція запису: прийом 8 бітів даних
        FOR idx IN 7 DOWNTO 0 LOOP
          WAIT UNTIL RISING_EDGE(scl);
          rx_frame(idx) := TO_X01(sda);
        END LOOP;
        WAIT UNTIL FALLING_EDGE(scl);
        slave_drv <= '0';
        WAIT UNTIL FALLING_EDGE(scl);
        slave_drv <= 'Z';
      ELSE
        -- Операція читання: видача байта 0xC3
        FOR idx IN 7 DOWNTO 0 LOOP
          slave_drv <= tx_pattern(idx);
          WAIT UNTIL FALLING_EDGE(scl);
        END LOOP;
        slave_drv <= 'Z';
        WAIT UNTIL FALLING_EDGE(scl);
      END IF;
    END IF;
  END PROCESS slave_model;

  -- Процес формування тестових сценаріїв
  stim_proc : PROCESS
  BEGIN
    -- Асинхронне скидання
    rst <= '1';
    WAIT FOR 100 ns;
    rst <= '0';
    WAIT FOR 40 ns;

    -- Тест 1: Запис байта 0xA5 за адресою 0x38
    addr    <= "0111000";
    rw      <= '0';
    data_in <= x"A5";
    start   <= '1';
    WAIT FOR CLK_PERIOD;
    start   <= '0';

    WAIT UNTIL done = '1';
    WAIT FOR 200 ns;

    -- Тест 2: Читання байта з адреси 0x38 (очікується 0xC3)
    addr  <= "0111000";
    rw    <= '1';
    start <= '1';
    WAIT FOR CLK_PERIOD;
    start <= '0';

    WAIT UNTIL done = '1';
    WAIT FOR 200 ns;

    ASSERT data_out = x"C3"
      REPORT "Error: Expected data_out = 0xC3!" SEVERITY ERROR;

    ASSERT FALSE
      REPORT "Simulation completed successfully!" SEVERITY NOTE;

    sim_finished <= TRUE;
    WAIT;
  END PROCESS stim_proc;

END ARCHITECTURE testbench;

