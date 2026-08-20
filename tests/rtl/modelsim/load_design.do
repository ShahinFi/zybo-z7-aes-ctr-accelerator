# =============================================================================
# AES-CTR standalone ModelSim/Questa design loader
# =============================================================================
# Compiles the repository VHDL sources into zybo_aes_hdl_lib and loads the
# aes_ctr_block_128 top level. run_all.do calls this only when no DUT is loaded.
# =============================================================================

set SIM_DIRECTORY [file normalize [pwd]]
set REPO_ROOT [file normalize [file join $SIM_DIRECTORY .. .. ..]]
set HDL_DIRECTORY [file normalize [file join $REPO_ROOT hardware hdl_designer zybo_aes_hdl_lib hdl]]

if {![file isdirectory $HDL_DIRECTORY]} {
    error "Could not locate AES-CTR VHDL directory: $HDL_DIRECTORY"
}

set VHDL_SOURCES {
    aes_sbox_tbl.vhd
    aes_mul02_struct.vhd
    aes_mul03_struct.vhd
    aes_rcon.vhd
    aes_shift_rows_struct.vhd
    aes_ctr_state_counter_struct.vhd
    aes_ctr_state_decoder_struct.vhd
    aes_rot_sub_word_struct.vhd
    aes_sub_bytes_struct.vhd
    aes_mix_column_struct.vhd
    aes_mix_columns_struct.vhd
    aes_key_expand_round_struct.vhd
    aes_ctr_controller_struct.vhd
    aes_ctr_counter_block_struct.vhd
    aes_ctr_input_collector_struct.vhd
    aes_ctr_output_serializer_struct.vhd
    aes_encrypt_128_struct.vhd
    aes_ctr_block_128_struct.vhd
}

foreach source_file $VHDL_SOURCES {
    set source_path [file normalize [file join $HDL_DIRECTORY $source_file]]
    if {![file exists $source_path]} {
        error "Missing VHDL source: $source_path"
    }
}

set ORIGINAL_DIRECTORY [pwd]
cd $SIM_DIRECTORY

if {[file exists zybo_aes_hdl_lib]} {
    file delete -force zybo_aes_hdl_lib
}

vlib zybo_aes_hdl_lib
vmap zybo_aes_hdl_lib zybo_aes_hdl_lib

foreach source_file $VHDL_SOURCES {
    set source_path [file normalize [file join $HDL_DIRECTORY $source_file]]
    echo "Compiling: $source_file"
    if {[catch {vcom -2008 -work zybo_aes_hdl_lib $source_path} compile_error]} {
        cd $ORIGINAL_DIRECTORY
        error "VHDL compilation failed for $source_file: $compile_error"
    }
}

if {[catch {vsim -t 1ps -voptargs=+acc zybo_aes_hdl_lib.aes_ctr_block_128} load_error]} {
    cd $ORIGINAL_DIRECTORY
    error "Could not load aes_ctr_block_128: $load_error"
}


echo "Standalone AES-CTR DUT loaded successfully."
