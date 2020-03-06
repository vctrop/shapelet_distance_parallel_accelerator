library IEEE;
use IEEE.numeric_std.all;
use ieee.std_logic_1164.all;

use IEEE.math_real."ceil";
use IEEE.math_real."log2";      -- used to calculate the number of bits used by the input length

use work.comppack.all;          -- FPU package

-- Shapelet distance calculator hardware
-- NUM_PU: specificies the level of paralelism. Must be a power of 2. (WARNING: CURRENTLY ONLY THE DEFAULT VALUE OF 2 IS IN WORKING CONDITION)
-- MAX_LEN: specifies the maximun shapelet length possible. Must be a multiple of NUM_PU.
entity shapelet_distance is
    generic(
        NUM_PU      : natural := 2;
        MAX_LEN     : natural := 128
    );
    port (
        clk         : in std_logic;
        rst         : in std_logic;
        
        -- Operation
        -- '0': set shapelet LENGTH and  change the pivot shapelet and normalize it
        -- '1': change target shapelet and compute distance
        op_i        : in std_logic;
        
        -- Data input is a single precision float shapelet datapoint
        data_i      : in std_logic_vector(31 downto 0);

        -- begins opeartions
        start_i     : in std_logic;        
        -- Ready flag for operation completion
        ready_o     : out std_logic;
        --distance result
        distance_o  : out std_logic_vector(31 downto 0)
    );
end shapelet_distance;

architecture behavioral of shapelet_distance is
    
    -- Flip-flop to keep the desired operation constant during the entire processing
    signal reg_op_s                                     : std_logic;
    
    -- Register to keep the shapelet length
    signal reg_shapelet_length_s                        : natural range 0 to MAX_LEN;
   
    -- Register to keep output result
    signal reg_distance_s                               : std_logic_vector(31 downto 0);

    -- Shapelet distance FSM states definition
    type fsm_state_t                                    is (-- Initialization states
                                                            Sbegin, Sbuf_load,
                                                            -- Euclidean normalization states
                                                            --Snorm_square, Snorm_sum_acc, Snorm_reg_acc, Snorm_final_acc, Snorm_sqrt, Snorm_div,
                                                            -- Z-score normalization states
                                                            Savg_sum_acc, Savg_reg_acc, Savg_final_acc, Savg_div, Sstd_sub, Sstd_wb_sub, Sstd_square, Sstd_sum_acc,
                                                            Sstd_reg_acc, Sstd_final_acc, Sstd_div, Sstd_sqrt, Szscore_div,
                                                            -- Euclidean distance states
                                                            Sdist_sub, Sdist_square, Sdist_sum_acc, Sdist_reg_acc,
                                                            -- Finishing states
                                                            Spivot_norm_wb, Spivot_norm_ready, Sdist_final_acc, Sout_distance);
    -- Register to keep FSM state
    signal reg_state_s                                  : fsm_state_t;
    
    -- Buffer filling counter used to load the buffer. incremented by 1 each time.
    signal reg_buf_counter_s                            : natural range 0 to MAX_LEN-1;
    -- Operation counter used to select buffer elements to write back from the processing units. Incremented by NUM_PU. 
    signal reg_acc_counter_s                            : natural range 0 to MAX_LEN-1;
    signal inc_acc_counter_s                            : natural range 0 to 2*MAX_LEN; -- The range is double so that we avoid overflow
    
    ---- SHAPELET BUFFERING DEFINITIONS
    -- Define shapelet buffer 
    type shapelet_buffer_t                              is array (0 to MAX_LEN-1) of std_logic_vector(31 downto 0);
    -- Defines the en signal for each element of pivot buffer
    type shaplet_en_t                                     is array (0 to MAX_LEN-1) of std_logic;

    -- Shapelet pivot buffer
    signal buffer_pivot_s                               : shapelet_buffer_t;
    signal pivot_buf_rst_s                              : std_logic;
    signal en_pivot_load_s                              : shaplet_en_t;                 -- Pivot enable for each element of pivot_buffer_s when loading elements from data_i
    signal en_pivot_wb_norm_s                           : shaplet_en_t;                 -- Pivot enable for each element of pivot_buffer_s when writting back normalization results
    signal en_pivot_wb_sub_s                            : shaplet_en_t;                 --NEW: Pivot enable for each element of pivot_buffer_s when writing back subtraction by average results
    signal pivot_input_s                                : shapelet_buffer_t;            -- Mux that selects the input of pivot shapelet among data_i, addsub_out_s and div_out_s
    -- Shapelet target buffer
    signal buffer_target_s                              : shapelet_buffer_t;
    signal target_buf_rst_s                             : std_logic;
    -- signal target_buf_wr_s                              : std_logic;   
    signal en_target_load_s                              : shaplet_en_t;                 --NEW: Target enable for each element of pivot_buffer_s when loading elements from data_i
    signal en_target_wb_sub_s                            : shaplet_en_t;                 --NEW: Target enable for each element of pivot_buffer_s when writing back subtraction by average results
    signal target_input_s                                : shapelet_buffer_t;            --NEW: Mux that selects the input of target shapelet between data_i and addsub_out_s
    
    ---- FLOATING POINT OPERATORS
    -- PU's single precision floating point array types   
    type pu_operands_t                                  is array (0 to NUM_PU - 1) of std_logic_vector(31 downto 0); 
    
    -- Array of accumulator registers
    signal reg_accumulators_s                           : pu_operands_t;
    signal reg_final_accumulator_s                      : std_logic_vector(31 downto 0);    -- holds the sum of every reg_acumulator 
    signal accumulators_wr_s                            : std_logic;
    signal accumulators_rst_s                           : std_logic;
    
    -- Cycle counter signals
    signal counter_start_s                              : std_logic;
    signal counter_mode_s                               : std_logic_vector(1 downto 0);
    
    -- All floating point operations are flagged ready by the same signal
    signal fp_ready_s                                   : std_logic;
    
    -- addition/subtraction signals
    signal add_or_sub_s                                 : std_logic;                        -- 0: add, 1: sub
    signal addsub_opa_s                                 : pu_operands_t;
    signal addsub_opb_s                                 : pu_operands_t;
    signal addsub_out_s                                 : pu_operands_t;
    signal addsub_start_s                               : std_logic;                        -- used to start the cycle counter
    -- multiplication signals                          
    signal mul_start_s                                  : std_logic;
    signal mul_operator_s                               : pu_operands_t;
    signal mul_out_s                                    : pu_operands_t;
    -- division signals                                
    signal div_start_s                                  : std_logic;
    signal div_opa_s                                    : pu_operands_t;
    signal div_opb_s                                    : pu_operands_t;
    signal div_out_s                                    : pu_operands_t;
    
    -- sum of accumulators
    signal acc_sum_opa_s                                : std_logic_vector(31 downto 0);
    signal acc_sum_opb_s                                : std_logic_vector(31 downto 0);
    signal acc_sum_out_s                                : std_logic_vector(31 downto 0);
    
    -- sqrt signals                                     
    signal sqrt_start_s                                 : std_logic;
    signal sqrt_op_s                                    : std_logic_vector(31 downto 0);
    signal sqrt_out_s                                   : std_logic_vector(31 downto 0);
    
    -- PU output registers:
    signal reg_addsub_out_s                             : pu_operands_t;
    signal reg_mul_out_s                                : pu_operands_t;
    signal reg_div_out_s                                : pu_operands_t;
    signal reg_sqrt_out_s                               : std_logic_vector(31 downto 0);
    signal reg_acc_sum_out_s                            : std_logic_vector(31 downto 0);

    ---- SHAPELETS POSITIONS MUX
    --
    type positions_by_pu_t                              is array(0 to MAX_LEN/NUM_PU-1)  of std_logic_vector(31 downto 0);
    -- 
    type pu_matrix_t                                    is array(0 to NUM_PU-1)         of positions_by_pu_t;
    
    -- Input buffer may be either pivot or target shapelets
    signal input_buffer_s                               : shapelet_buffer_t;
    -- Register to count how many blocks of shapelet positions were already presented to the PUs, acting as a MUX selector for the shapelet . (reg_acc_counter_s is an absolute element count)
    signal reg_block_sel_s                              : natural range 0 to MAX_LEN/NUM_PU-1;
    signal block_sel_rst_s                              : std_logic;
    signal block_sel_inc_s                              : std_logic;
    -- Matrix with processing units as rows and shapelet positions for each PU as columns
    signal matrix_representation_s                      : pu_matrix_t;
    -- The shapelet positions presented to each of the NUM_PU processing elements
    signal shapelet_elements_mux_s                      : pu_operands_t;
    
begin
    
    CONTROL_FSM: process(clk)
    begin
    if rising_edge(clk) then
        if rst = '1' then
            reg_state_s <= Sbegin;
            reg_distance_s <= (others => '0');
        else
            case reg_state_s is
                -- INITIALIZATION STATES
                when Sbegin         =>
                    reg_op_s <= op_i;
                    -- reg_buf_counter_s e reg_acc_counter_s podem ser unidos num so reg
                    reg_buf_counter_s <= 0;
                    reg_acc_counter_s <= 0;
                    
                    if start_i = '1' then
                        -- If operation is set pivot and change length
                        if op_i = '0' then
                            -- the number of bits used by the length must be based on the log2 of the parameter MAX_LEN
                            -- for the default MAX_LEN=128 it should result in 7
                            reg_shapelet_length_s <= to_integer(unsigned(data_i(ceil(log2(real(MAX_LEN)))-1 downto 0)));
                        end if;
                        reg_state_s <= Sbuf_load;
                    end if;
                
                when Sbuf_load      => 
                    reg_buf_counter_s <= reg_buf_counter_s + 1;
                    
                    -- Next state
                    -- Reapeat until current buffer length = shapelet length - 1
                    if reg_buf_counter_s = reg_shapelet_length_s - 1 then
                        reg_state_s <= Snorm_square;
                    end if;
                    
                -- Z-SCORE NORMALIZATION STATES
                when Savg_sum_acc =>
                    -- Next state
                    if fp_ready_s = '1' then
                        reg_state_s <= Savg_reg_acc;
                    end if;
                    
                when Savg_reg_acc =>
                    reg_acc_counter_s <= inc_acc_counter_s;
                    -- Next state
                    -- Checks if the next iteration will exceed the shapelet length
                    -- The comparison with inc_acc is to offset the fact that we begin the iterations at 0
                    if inc_acc_counter_s >= reg_shapelet_length_s then
                        reg_state_s <= Savg_final_acc;
                    else
                        reg_state_s <= Savg_sum_acc;
                    end if;
                    
                when Savg_final_acc =>
                    reg_acc_counter_s <= 0;
                    -- Next state
                    if fp_ready_s = '1' then
                        reg_state_s <= Savg_div;
                    end if;
                    
                when Savg_div =>
                    -- Next state
                    if fp_ready_s = '1' then
                        reg_state_s <= Sstd_sub;
                    end if;
                    
                when Sstd_sub =>
                    -- Next state
                    if fp_ready_s = '1' then
                        reg_state_s <= Sstd_wb_sub;
                    end if;
                    
                -- Writing back subtraction by average results avoids the repetition of the same calculation when computing the normalized values
                when Sstd_wb_sub =>
                    -- Next state
                    reg_state_s <= Sstd_square;
                    
                when Sstd_square =>
                    -- Next state
                    if fp_ready_s = '1' then
                        reg_state_s <= Sstd_sum_acc;
                    end if;
                    
                when Sstd_sum_acc =>
                    -- Next state
                    if fp_ready_s = '1' then
                        reg_state_s <= Sstd_reg_acc;
                    end if;
                    
                when Sstd_reg_acc =>
                    reg_acc_counter_s <= inc_acc_counter_s;
                    -- Next state
                    -- Checks if the next iteration will exceed the shapelet length
                    -- The comparison with inc_acc is to offset the fact that we begin the iterations at 0
                    if inc_acc_counter_s >= reg_shapelet_length_s then
                        reg_state_s <= Sstd_final_acc;
                    else
                        reg_state_s <= Sstd_sub;
                    end if;
                    
                when Sstd_final_acc =>
                    reg_acc_counter_s <= 0;
                    -- Next state
                    if fp_ready_s = '1' then
                        reg_state_s <= Sstd_div;
                    end if;
                    
                when Sstd_div =>
                    -- Next state
                    if fp_ready_s = '1' then
                        reg_state_s <= Sstd_sqrt;
                    end if;
                    
                when Sstd_sqrt =>
                    -- Next state
                    if fp_ready_s = '1' then
                        reg_state_s <= Szscore_div;
                    end if;
                    
                when Szscore_div =>
                    -- Next state
                    if fp_ready_s = '1' then
                        if reg_op_s = '0' then
                            reg_state_s <= Spivot_norm_wb;
                        else
                            reg_state_s <= Sdist_sub;
                        end if;
                        
                -- EUCLIDEAN DISTANCE STATES
                when Sdist_sub      =>  
                        
                    -- Next state
                    -- Is subtraction ready?
                    if fp_ready_s = '1' then
                        reg_state_s <= Sdist_square;
                    end if;
                    
                when Sdist_square   =>  
                    
                    -- Next state
                    -- Is multiplication ready?
                    if fp_ready_s = '1' then
                        reg_state_s <= Sdist_sum_acc;
                    end if;
                
                when Sdist_sum_acc  =>  
                    
                    -- Next state
                    -- Is sum ready?
                    if fp_ready_s = '1' then
                        reg_state_s <= Sdist_reg_acc;
                    end if;
                
                when Sdist_reg_acc  =>  
                    reg_acc_counter_s <= inc_acc_counter_s;
                    
                    -- Next state
                    -- Checks if the next iteration will exceed the shapelet length
                    -- This is to offset the fact that we begin the iterations at 0
                    if inc_acc_counter_s >= reg_shapelet_length_s then
                        reg_state_s <= Sdist_final_acc;
                    else
                        reg_state_s <= Snorm_div;
                    end if;
                    
                -- FINISHING STATES
                when Spivot_norm_wb      =>  
                    reg_acc_counter_s <= inc_acc_counter_s;
                    
                    -- Next state
                    -- Checks if the next iteration will exceed the shapelet length
                    -- This is to offset the fact that we begin the iterations at 0
                    if inc_acc_counter_s >= reg_shapelet_length_s then
                        reg_state_s <= Spivot_norm_ready;
                    else
                        reg_state_s <= Snorm_div;
                    end if; 

                when Spivot_norm_ready    =>
                    -- Activate ready signal for 1 cycle at the end of operation 0
                    reg_state_s <= Sbegin;                  -- End operation 0  
                    
                when Sdist_final_acc =>
                    -- Sums each PU's accumulators
                    if fp_ready_s = '1' then
                        reg_state_s <= Sout_distance;
						reg_distance_s <= acc_sum_out_s;	 -- Write the distance calculation to distance output register
                    end if;

                when Sout_distance  =>
                    reg_state_s <= Sbegin;                  -- End operation 1
                
            end case;
        end if;
    end if;    
    end process;
    
    -- Entity outputs
    distance_o  <= reg_distance_s;
    ready_o     <= '1' when reg_state_s = Sout_distance or reg_state_s = Spivot_norm_ready else '0';
    
    -- PIVOT AND TARGET BUFFERS DEFINITION 
    -- Enables writing to pivot and target buffers when loading values from data_i during their respective operations
    GEN_LOADING_EN: for i in buffer_pivot_s'range generate 
        en_pivot_load_s(i)  <= '1' when reg_buf_counter_s = i and reg_state_s = Sbuf_load and reg_op_s = '0' else '0';
        en_target_load_s(i) <= '1' when reg_buf_counter_s = i and reg_state_s = Sbuf_load and reg_op_s = '1' else '0';
    end generate;

    -- Define write-back enables and the muxes of pivot_input_s and target_input_s
    GEN_WB_INPUT_J: for j in 0 to MAX_LEN/NUM_PU-1 generate
        GEN_WB_INPUT_I: for i in 0 to NUM_PU-1 generate
            --NEW: Enables writing to corresponding pivot and target buffers elements when writing back x - avg during normalization
            en_pivot_wb_sub_s(i + j*NUM_PU)     <= '1' when reg_block_sel_s = j and reg_state_s = Sstd_wb_sub and reg_op_s = '0' else '0';
            en_target_wb_sub_s(i + j*NUM_PU)    <= '1' when reg_block_sel_s = j and reg_state_s = Sstd_wb_sub and reg_op_s = '1' else '0';
            -- Enables writing to corresponding pivot buffer elements when writing back after normalization
            en_pivot_wb_norm_s(i + j*NUM_PU)    <= '1' when reg_block_sel_s = j and reg_state_s = Spivot_norm_wb else '0'; 
            -- Selects which data will the pivot buffer receive
            pivot_input_s(i + j*NUM_PU)  <= data_i          when reg_state_s = Sbuf_load    else
                                            addsub_out_s(i) when reg_state_s = Sstd_wb_sub  else                --NEW: make addsub_out_s be one of the inputs for the pivot shapelet
                                            div_out_s(i);
            --NEW: Selects which data will the target buffer receive
            target_input_s(i + j*NUM_PU) <= data_i          when reg_state_s = Sbuf_load    else
                                            addsub_out_s(i);
        end generate;
    end generate;

    -- The pivot buffer may receive data from PUs or data_i
    GEN_PIVOT_BUFFER: for i in buffer_pivot_s'range generate
        process(clk)
        begin 
            if rising_edge(clk) then
                if rst = '1' or pivot_buf_rst_s = '1' then
                    buffer_pivot_s(i) <= (others => '0');
                --NEW: consider en_pivot_wb_sub_s when writing on pivot
                elsif en_pivot_load_s(i) = '1' or en_pivot_wb_norm_s(i) = '1' or en_pivot_wb_sub_s(i) then
                    buffer_pivot_s(i) <= pivot_input_s(i);
                end if;
            end if;
        end process;
    end generate;
    
    --NEW: The target buffer may receive data from PUs or data_i
    GEN_TARGET_BUFFER: for i in buffer_target_s'range generate
        process(clk)
        begin 
            if rising_edge(clk) then
                if rst = '1' or target_buf_rst_s = '1' then
                    buffer_target_s(i) <= (others => '0');
                --NEW: consider en_pivot_wb_sub_s when writing on pivot
                elsif en_target_load_s(i) = '1' or en_target_wb_sub_s(i) then
                    buffer_target_s(i) <= target_input_s(i);
                end if;
            end if;
        end process;
    end generate;

    -- Buffers resetting logic
	-- Reset pivot at the beggining of operation 0 and target at the beggining of operation 1
    pivot_buf_rst_s     <= '1' when reg_state_s = Sbegin and start_i = '1' and op_i = '0' else '0';
    target_buf_rst_s    <= '1' when reg_state_s = Sbegin and start_i = '1' and op_i = '1' else '0';
    
    -- Increment reg_acc_counter_s out of process to create a single adder
    inc_acc_counter_s <= reg_acc_counter_s + NUM_PU;
        
    -- MUX TO PRESENT SHAPELET POSITIONS TO THE RIGHT PROCESSING UNITS
    -- Selects which shapelet is presented to the MUX
    input_buffer_s <=   buffer_pivot_s  when reg_op_s = '0' or (reg_op_s = '1' and reg_state_s = Sdist_sub) else
                        buffer_target_s;
    
    -- Generate MUX inputs
    -- Transform the input_buffer vector into a NUM_PU x MAX_LEN/NUM_PU matrix
    -- Each LINE of the matrix represents all elements of the input_buffer that
    -- will be input into a mux at each input of the processing elements. 
    -- For NUM_PU=2 and MAX_LEN=8 we have a buff(7 downto 0)
    -- the matrix will be as follows:
    -- ||       col(0)  col(1)  col(2)  col(3)
    -- line(0)  buff(0) buff(2) buff(4) buff(6)             <-- these will form the inputs of mux(0)
    -- line(1)  buff(1) buff(3) buff(5) buff(7)             <-- these will form the inputs of mux(1)
    OUTER: for i in NUM_PU - 1 downto 0 generate
        INNER: for j in (MAX_LEN/NUM_PU - 1) downto 0 generate
            matrix_representation_s(i)(j) <= input_buffer_s(i + j*NUM_PU);
        end generate INNER;
    end generate OUTER;
    
    -- Mux selector is a counter of how many blocks were processed to the moment 
    block_sel_rst_s <= '1' when reg_state_s = Sbegin        or reg_state_s = Savg_final_acc or reg_state_s = Sstd_final_acc     else '0';   --NEW: reset block counter for new norm states
    block_sel_inc_s <= '1' when reg_state_s = Savg_reg_acc  or reg_state_s = Sstd_reg_acc   or reg_state_s = Spivot_norm_wb     or reg_state_s = Sdist_reg_acc  else '0';       --NEW: increment block sel for the new norm states
    
    reg_selector: process(clk)
    begin
        if rising_edge(clk) then
            if block_sel_rst_s = '1' then
                reg_block_sel_s <= 0;
            elsif block_sel_inc_s = '1' then
                reg_block_sel_s <= reg_block_sel_s + 1;
            end if;
        end if;
    end process;
    
    -- GENERATE NUM_PU muxes that will be the data inputs for each processing unit
    -- Each mux formed by the LINES of the matrix. Each line containts 
    -- all the elements that will be processed by that unit.
    -- The sel signal is shared by all muxes created, so that
    -- each processing unit will recieve the signal 0 to MAX_LEN/NUM_PU
    -- For NUM_PU=2 and MAX_LEN=8 we have the following matrix
    -- ||       col(0)  col(1)  col(2)  col(3)
    -- line(0)  buff(0) buff(2) buff(4) buff(6)        <-- PE(0)
    -- line(1)  buff(1) buff(3) buff(5) buff(7)        <-- PE(1)
    --          ^       ^
    --          |       |
    --          sel=0   sel=1
    -- eg. when sel=1, processing unit 0 will receive buff(2) and processing unit 1 will recieve buff(3)
    MUXES: for i in NUM_PU - 1 downto 0 generate
        shapelet_elements_mux_s(i) <= matrix_representation_s(i)(reg_block_sel_s);
    end generate MUXES;
    
    
    ---- PROCESSING UNITS
    --NEW: Change operands and add new states in the multiplexation of PUs signals
    -- Addsub
    -- add_or_sub_s selcts if a addition='0' or subtraction='1' will be computed
    add_or_sub_s    <=  '1'                     when reg_state_s = Sdist_sub    or reg_state_s = Sstd_sub  else '0';
    addsub_opa_s    <=  reg_div_out_s           when reg_state_s = Sdist_sub    else
                        shapelet_elements_mux_s when reg_state_s = Sstd_sub     else
                        reg_accumulators_s;
    addsub_opb_s    <=  shapelet_elements_mux_s when reg_state_s = Savg_sum_acc or reg_state_s = Sdist_sub else
                        reg_div_out_s           when reg_state_s = Sstd_sub     else
                        reg_mul_out_s;
    addsub_start_s  <=  '0'                     when reg_state_s = Savg_sum_acc or reg_state_s = Savg_final_acc or reg_state_s = Sstd_sub   or reg_state_s = Sstd_sum_acc  or reg_state_s = Sstd_final_acc    or 
                                                     reg_state_s = Sdist_sub    or reg_state_s = Sdist_sum_acc  or reg_state_s = Sdist_final_acc
                                                     else '1';

    -- Multiplier 
    mul_start_s     <= '0'  when    reg_state_s = Sstd_square   or reg_state_s = Sdist_square   else '1';
    -- Square subtraction output in normalization and in euclidean distance calculation
    -- the multiplier unit always computes A*A (A^2)
    mul_operator_s  <= reg_addsub_out_s;
    
    -- Divider
    div_start_s     <= '0'  when reg_state_s = Savg_div or reg_state_s = Sstd_div  or reg_state_s = Szscore_div     else '1';
    --NEW: To use only one of the divisors in Savg_div and Sstd_div, the division operands beside the first one must come from a for .. generate
    div_opa_s(0)    <=  shapelet_elements_mux_s(0)  when reg_state_s = Szscore_div   else
                        reg_final_accumulator_s;
    div_opb_s(0)    <=  sqrt_out_s                  when reg_state_s = Szscore_div  else
                        reg_shapelet_length_s - 1   when reg_state_s = Sstd_div     else -- HERE: convert reg_shapelet_length_s and reg_shapelet_length_s - 1 to float
                        reg_shapelet_length_s;
                        
    DIV_OP_GEN: for i in NUM_PU - 1 downto 1 generate
        div_opa_s(i)    <= shapelet_elements_mux_s(i);    
        div_opb_s(i)    <= reg_sqrt_out_s;
    end generate DIV_OP_GEN;

    -- Single SQRT
    sqrt_op_s       <= reg_div_out_s(0);
    sqrt_start_s    <= '0'  when reg_state_s = Sstd_sqrt   else '1';
    
    -- Cycle counter
    -- Start cycle counter when an operation start is set down
    counter_start_s <= '1'  when addsub_start_s = '0'       or mul_start_s = '0' or div_start_s = '0' or sqrt_start_s = '0' else '0';
    -- Counter mode
    counter_mode_s  <=  "10" when reg_state_s = Sstd_square or reg_state_s = Sdist_square   else                                                                -- Multiplication
                        "01" when reg_state_s = Savg_div    or reg_state_s = Sstd_div       or reg_state_s = Szscore_div    or reg_state_s = Sstd_sqrt  else    -- Division and sqrt
                        "00";                                                                                                                                   -- Addition/Subtraction
    cycle_counter: entity work.cycle_counter
    port map(   
        clk     => clk,
        rst     => rst,
        -- mode defines the number of cycles to count down
        -- 00 = 6   ( add / sub)
        -- 01 = 33  ( division or sqrt)
        -- 10 = 12  ( multiplication )
        -- 11 = 0     
        mode_i  => counter_mode_s,

        start_i => counter_start_s,   -- start countdown
        ready_o => fp_ready_s  -- ready signal indicating cycle_counter has finished counting. Active for 1 clock cycle
    
    );
    
    -- Generate parameterized parallel processing units (adder/subtractor, multiplier, divider, square root)
    PROCESSING_UNITS: for i in 0 to NUM_PU - 1 generate
        -- Used in accumulator operation and subtraction during distance calculation
        -- ADDSUB computes in 6 cycles
        addsub: fp_addsub
        port map(
            clk_i 			=> clk,      
            op_type         => add_or_sub_s,                    -- 0 = add, 1 = sub
            opa_i        	=> addsub_opa_s(i),
            opb_i           => addsub_opb_s(i),
            output_o        => addsub_out_s(i),
            -- Exceptions
            ine_o 			=> open,                -- inexact
            overflow_o  	=> open,                -- overflow
            underflow_o 	=> open,                -- underflow
            inf_o			=> open,                -- infinity
            zero_o			=> open,                -- zero
            qnan_o			=> open,                -- queit Not-a-Number
            snan_o			=> open                 -- signaling Not-a-Number
        );
        
        -- MUL computes in 11 cycles
        mul: fp_mul
        port map(
            clk_i 			=> clk,
            start_i         => mul_start_s,
            opa_i        	=> mul_operator_s(i),                    -- Input Operands A & B
            opb_i           => mul_operator_s(i),
            output_o        => mul_out_s(i),
            -- Exceptions
            ine_o 			=> open,                -- inexact
            overflow_o  	=> open,                -- overflow
            underflow_o 	=> open,                -- underflow
            inf_o			=> open,                -- infinity
            zero_o			=> open,                -- zero
            qnan_o			=> open,                -- queit Not-a-Number
            snan_o			=> open                 -- signaling Not-a-Number
        );
        
        -- Div computes in 33 cycles (says fpu code)
        div: fp_div
        port map(
            clk_i 			=> clk,
            start_i         => div_start_s,
            opa_i        	=> div_opa_s(i),                    -- Input Operands A & B
            opb_i           => div_opb_s(i),                    --NEW: Div opb may come from different sources    
            output_o        => div_out_s(i),
            
            -- Exceptions
            ine_o 			 => open,                       -- inexact
            overflow_o  	 => open,                       -- overflow
            underflow_o 	 => open,                       -- underflow
            div_zero_o       => open,                       -- division by zero
            inf_o			 => open,                       -- infinity
            zero_o			 => open,                       -- zero
            qnan_o			 => open,                       -- queit Not-a-Number
            snan_o			 => open                        -- signaling Not-a-Number
        );
    end generate PROCESSING_UNITS; 
    
    
    -- FUTURE: ADDER TREE
    -- Sum accumulators (NOW: assumes there are only 2 PUs)
    acc_sum_opa_s <= reg_accumulators_s(0);
    acc_sum_opb_s <= reg_accumulators_s(1);
    
    -- sums accumulator registers
    sum_accs: fp_addsub
    port map(
        clk_i 			=> clk,      
        op_type         => '0',                    -- 0 = add
        opa_i        	=> acc_sum_opa_s,
        opb_i           => acc_sum_opb_s,
        output_o        => acc_sum_out_s,
        -- Exceptions
        ine_o 			=> open,                -- inexact
        overflow_o  	=> open,                -- overflow
        underflow_o 	=> open,                -- underflow
        inf_o			=> open,                -- infinity
        zero_o			=> open,                -- zero
        qnan_o			=> open,                -- queit Not-a-Number
        snan_o			=> open                 -- signaling Not-a-Number
    );
 
 
    -- Single square root unit, computing in 33 cycles
    sqrt: fp_sqrt
    port map(
        clk_i 			=> clk,
        start_i         => sqrt_start_s,
        opa_i        	=> sqrt_op_s,
        output_o        => sqrt_out_s,
        -- Exceptions
        ine_o 			=> open,                            -- inexact
        overflow_o  	=> open,                            -- overflow
        underflow_o 	=> open,                            -- underflow
        inf_o			=> open,                            -- infinity
        zero_o			=> open,                            -- zero
        qnan_o			=> open,                            -- queit Not-a-Number
        snan_o			=> open                             -- signaling Not-a-Number
    );
        
    -- registers that save the PU's results
    --NEW: save outputs in the new states and delete references to the old ones
    process(clk, rst)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                reg_addsub_out_s    <= (others => (others => '0'));
                reg_mul_out_s       <= (others => (others => '0'));
                reg_div_out_s       <= (others => (others => '0'));
                reg_sqrt_out_s      <= (others => '0');
                reg_acc_sum_out_s   <= (others => '0');
            elsif fp_ready_s = '1' then
                -- Multiplier
                if reg_state_s = Sstd_square or reg_state_s = Sdist_square then
                    reg_mul_out_s <= mul_out_s;
                end if;
                -- Subtractor
                --HERE: Por que estados de add tambem nao fazem o reg_addsub_out_s ser escrito?
                -- The x - avg write back during normalization writes directly to shapelet buffers
                if reg_state_s = Sdist_sub then
                    reg_addsub_out_s <= addsub_out_s;
                end if;
                -- The norm write back during operation 0 writes directly to the pivot buffer
                -- Divisor
                if reg_state_s = Savg_div or reg_state_s = Sstd_div or (reg_state_s = Szscore_div and reg_op_s = '1') then
                    reg_div_out_s <= div_out_s;
                end if;
                -- Square root
                if reg_state_s = Sstd_sqrt then
                    reg_sqrt_out_s <= sqrt_out_s;
                end if;
                -- Final acc sum (FUTURE: adder tree)
                -- The distance final sum during operation 1 writes directly to reg_distance_s
                if reg_state_s = Savg_final_acc or reg_state_s = Sstd_final_acc then
                    reg_acc_sum_out_s <= acc_sum_out_s;
                end if;
            end if;
        end if;
    end process;

    -- ACCUMULATOR DRIVER
    -- NEW: Update to new acc writing/reseting states
    -- Reset the accumulator at the start of the FSM and after summing all accumulators to a single value.
    accumulators_rst_s  <= '1' when reg_state_s = Sbegin        or ((reg_state_s = Savg_final_acc   or reg_state_s = Savg_final_acc) and fp_ready_s = '1')  else '0';
    accumulators_wr_s   <= '1' when reg_state_s = Savg_reg_acc  or reg_state_s = Sstd_reg_acc       or reg_state_s = Sdist_reg_acc                          else '0';
    -- Accummulator registers
    acc_regs: process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' or accumulators_rst_s = '1' then
                reg_accumulators_s <= (others => (others => '0'));
            else
                if accumulators_wr_s = '1' then
                    reg_accumulators_s <= addsub_out_s;
                end if;
            end if;
        end if;
    end process;


end behavioral;
