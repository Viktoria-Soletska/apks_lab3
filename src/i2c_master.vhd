LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

ENTITY i2c_master IS
  GENERIC (
    CLK_DIV : INTEGER := 4 -- Дільник системної частоти (чверть періоду SCL)
  );
  PORT (
    clk       : IN    STD_LOGIC;                    -- Системний тактовий сигнал (50 МГц)
    rst       : IN    STD_LOGIC;                    -- Асинхронне скидання (активна '1')
    start     : IN    STD_LOGIC;                    -- Сигнал запуску транзакції
    rw        : IN    STD_LOGIC;                    -- Режим: '0' - запис, '1' - читання
    addr      : IN    STD_LOGIC_VECTOR(6 DOWNTO 0); -- 7-бітна адреса веденого (Slave)
    data_in   : IN    STD_LOGIC_VECTOR(7 DOWNTO 0); -- Байт даних для запису
    scl       : INOUT STD_LOGIC;                    -- Лінія тактування I2C (відкритий стік)
    sda       : INOUT STD_LOGIC;                    -- Лінія даних I2C (відкритий стік)
    busy      : OUT   STD_LOGIC;                    -- Прапорець зайнятості шини
    ack_error : OUT   STD_LOGIC;                    -- Ознака помилки підтвердження (NACK)
    done      : OUT   STD_LOGIC;                    -- Імпульс завершення операції
    data_out  : OUT   STD_LOGIC_VECTOR(7 DOWNTO 0)  -- Прийнятий байт при читанні
  );
END ENTITY i2c_master;

ARCHITECTURE behavioral OF i2c_master IS

  TYPE t_fsm_state IS (
    ST_IDLE,       -- Очікування запуску (SCL = 1, SDA = 1)
    ST_START,      -- Формування умови START
    ST_ADDR_TX,    -- Передача 7 біт адреси та біта R/W
    ST_ADDR_ACK,   -- Очікування ACK на адресу
    ST_DATA_TX,    -- Передача байта даних (запис)
    ST_DATA_ACK,   -- Очікування ACK на дані
    ST_DATA_RX,    -- Прийом байта даних (читання)
    ST_MASTER_ACK, -- Видача NACK ведучим після читання
    ST_STOP        -- Формування умови STOP
  );

  SIGNAL fsm_state   : t_fsm_state := ST_IDLE;
  SIGNAL phase       : INTEGER RANGE 0 TO 3 := 0;
  SIGNAL div_cnt     : INTEGER RANGE 0 TO CLK_DIV - 1 := 0;
  SIGNAL phase_tick  : STD_LOGIC := '0';
  SIGNAL bit_idx     : INTEGER RANGE 0 TO 7 := 7;

  SIGNAL scl_reg     : STD_LOGIC := '1';
  SIGNAL sda_reg     : STD_LOGIC := '1';
  SIGNAL shift_tx    : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL shift_rx    : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL ack_err_reg : STD_LOGIC := '0';
  SIGNAL done_pulse  : STD_LOGIC := '0';
  SIGNAL rw_latched  : STD_LOGIC := '0';

BEGIN

  -- Тристабільні буфери для режиму відкритого стоку (Open-Drain)
  scl <= '0' WHEN scl_reg = '0' ELSE 'Z';
  sda <= '0' WHEN sda_reg = '0' ELSE 'Z';

  busy      <= '0' WHEN fsm_state = ST_IDLE ELSE '1';
  ack_error <= ack_err_reg;
  done      <= done_pulse;
  data_out  <= shift_rx;

  -- Процес формування стробів чверть-періоду SCL
  clk_divider_proc : PROCESS(clk, rst)
  BEGIN
    IF rst = '1' THEN
      div_cnt    <= 0;
      phase_tick <= '0';
    ELSIF RISING_EDGE(clk) THEN
      IF fsm_state = ST_IDLE THEN
        div_cnt    <= 0;
        phase_tick <= '0';
      ELSIF div_cnt = CLK_DIV - 1 THEN
        div_cnt    <= 0;
        phase_tick <= '1';
      ELSE
        div_cnt    <= div_cnt + 1;
        phase_tick <= '0';
      END IF;
    END IF;
  END PROCESS clk_divider_proc;

  -- Основний процес керуючого скінченного автомата (FSM)
  fsm_proc : PROCESS(clk, rst)
  BEGIN
    IF rst = '1' THEN
      fsm_state   <= ST_IDLE;
      phase       <= 0;
      bit_idx     <= 7;
      scl_reg     <= '1';
      sda_reg     <= '1';
      shift_tx    <= (OTHERS => '0');
      shift_rx    <= (OTHERS => '0');
      ack_err_reg <= '0';
      done_pulse  <= '0';
      rw_latched  <= '0';
    ELSIF RISING_EDGE(clk) THEN
      done_pulse <= '0'; -- Строб завершення триває 1 такт clk

      IF fsm_state = ST_IDLE THEN
        scl_reg <= '1';
        sda_reg <= '1';
        phase   <= 0;
        bit_idx <= 7;
        IF start = '1' THEN
          rw_latched  <= rw;
          shift_tx    <= addr & rw;
          ack_err_reg <= '0';
          fsm_state   <= ST_START;
        END IF;

      ELSIF phase_tick = '1' THEN
        CASE fsm_state IS

          WHEN ST_START =>
            IF phase = 0 THEN
              scl_reg <= '1';
              sda_reg <= '1';
              phase   <= 1;
            ELSIF phase = 1 THEN
              scl_reg <= '1';
              sda_reg <= '0'; -- Спад SDA при високому SCL
              phase   <= 2;
            ELSIF phase = 2 THEN
              scl_reg <= '1';
              sda_reg <= '0';
              phase   <= 3;
            ELSE
              scl_reg   <= '0';
              sda_reg   <= '0';
              phase     <= 0;
              bit_idx   <= 7;
              fsm_state <= ST_ADDR_TX;
            END IF;

          WHEN ST_ADDR_TX =>
            IF phase = 0 THEN
              scl_reg <= '0';
              sda_reg <= shift_tx(bit_idx);
              phase   <= 1;
            ELSIF phase = 1 OR phase = 2 THEN
              scl_reg <= '1';
              phase   <= phase + 1;
            ELSE
              scl_reg <= '0';
              phase   <= 0;
              IF bit_idx > 0 THEN
                bit_idx <= bit_idx - 1;
              ELSE
                fsm_state <= ST_ADDR_ACK;
              END IF;
            END IF;

          WHEN ST_ADDR_ACK =>
            IF phase = 0 THEN
              scl_reg <= '0';
              sda_reg <= '1'; -- Перехід SDA у 'Z' для ACK
              phase   <= 1;
            ELSIF phase = 1 THEN
              scl_reg <= '1';
              phase   <= 2;
            ELSIF phase = 2 THEN
              scl_reg <= '1';
              IF TO_X01(sda) /= '0' THEN
                ack_err_reg <= '1';
              END IF;
              phase <= 3;
            ELSE
              scl_reg <= '0';
              phase   <= 0;
              bit_idx <= 7;
              IF ack_err_reg = '1' OR TO_X01(sda) /= '0' THEN
                sda_reg   <= '0';
                fsm_state <= ST_STOP;
              ELSIF rw_latched = '0' THEN
                shift_tx  <= data_in;
                fsm_state <= ST_DATA_TX;
              ELSE
                fsm_state <= ST_DATA_RX;
              END IF;
            END IF;

          WHEN ST_DATA_TX =>
            IF phase = 0 THEN
              scl_reg <= '0';
              sda_reg <= shift_tx(bit_idx);
              phase   <= 1;
            ELSIF phase = 1 OR phase = 2 THEN
              scl_reg <= '1';
              phase   <= phase + 1;
            ELSE
              scl_reg <= '0';
              phase   <= 0;
              IF bit_idx > 0 THEN
                bit_idx <= bit_idx - 1;
              ELSE
                fsm_state <= ST_DATA_ACK;
              END IF;
            END IF;

          WHEN ST_DATA_ACK =>
            IF phase = 0 THEN
              scl_reg <= '0';
              sda_reg <= '1';
              phase   <= 1;
            ELSIF phase = 1 THEN
              scl_reg <= '1';
              phase   <= 2;
            ELSIF phase = 2 THEN
              scl_reg <= '1';
              IF TO_X01(sda) /= '0' THEN
                ack_err_reg <= '1';
              END IF;
              phase <= 3;
            ELSE
              scl_reg   <= '0';
              sda_reg   <= '0';
              phase     <= 0;
              fsm_state <= ST_STOP;
            END IF;

          WHEN ST_DATA_RX =>
            IF phase = 0 THEN
              scl_reg <= '0';
              sda_reg <= '1';
              phase   <= 1;
            ELSIF phase = 1 THEN
              scl_reg <= '1';
              phase   <= 2;
            ELSIF phase = 2 THEN
              scl_reg           <= '1';
              shift_rx(bit_idx) <= TO_X01(sda);
              phase             <= 3;
            ELSE
              scl_reg <= '0';
              phase   <= 0;
              IF bit_idx > 0 THEN
                bit_idx <= bit_idx - 1;
              ELSE
                fsm_state <= ST_MASTER_ACK;
              END IF;
            END IF;

          WHEN ST_MASTER_ACK =>
            IF phase = 0 THEN
              scl_reg <= '0';
              sda_reg <= '1'; -- NACK ('1') після завершення читання
              phase   <= 1;
            ELSIF phase = 1 OR phase = 2 THEN
              scl_reg <= '1';
              phase   <= phase + 1;
            ELSE
              scl_reg   <= '0';
              sda_reg   <= '0';
              phase     <= 0;
              fsm_state <= ST_STOP;
            END IF;

          WHEN ST_STOP =>
            IF phase = 0 THEN
              scl_reg <= '0';
              sda_reg <= '0';
              phase   <= 1;
            ELSIF phase = 1 THEN
              scl_reg <= '1';
              sda_reg <= '0';
              phase   <= 2;
            ELSIF phase = 2 THEN
              scl_reg <= '1';
              sda_reg <= '1'; -- Наростання SDA при високому SCL
              phase   <= 3;
            ELSE
              scl_reg    <= '1';
              sda_reg    <= '1';
              done_pulse <= '1';
              phase      <= 0;
              fsm_state  <= ST_IDLE;
            END IF;

          WHEN OTHERS =>
            fsm_state <= ST_IDLE;

        END CASE;
      END IF;
    END IF;
  END PROCESS fsm_proc;

END ARCHITECTURE behavioral;
