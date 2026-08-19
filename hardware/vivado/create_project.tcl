# Recreate the Zybo Z7-20 AES-CTR accelerator Vivado project from repository sources.

set script_dir   [file normalize [file dirname [info script]]]
set hardware_dir [file normalize "$script_dir/.."]
set repo_root    [file normalize "$hardware_dir/.."]

set project_name "zybo_z7_20_aes_ctr"
set project_dir  [file normalize "$repo_root/build/vivado/$project_name"]

set aes_hdl_dir  [file normalize "$hardware_dir/hdl_designer/zybo_aes_hdl_lib/hdl"]
set aes_top_file [file normalize "$aes_hdl_dir/aes_ctr_block_128_struct.vhd"]
set ip_repo_dir  [file normalize "$hardware_dir/ip/zybo_accel_ctrl_1_0"]
set ip_component [file normalize "$ip_repo_dir/component.xml"]
set bd_tcl_file  [file normalize "$script_dir/create_block_design.tcl"]

foreach required_path [list $aes_hdl_dir $aes_top_file $ip_repo_dir $ip_component $bd_tcl_file] {
    if {![file exists $required_path]} {
        error "Required repository input not found: $required_path"
    }
}

set aes_hdl_files [lsort [glob -nocomplain "$aes_hdl_dir/*.vhd"]]

if {[llength $aes_hdl_files] == 0} {
    error "No AES VHDL sources found in: $aes_hdl_dir"
}

if {[file exists $project_dir]} {
    error "Vivado project directory already exists: $project_dir"
}

file mkdir $project_dir

create_project $project_name $project_dir -part xc7z020clg400-1
set_property board_part digilentinc.com:zybo-z7-20:part0:1.2 [current_project]

# Load the AES-extended AXI-Lite control IP.
set_property IP_REPO_PATHS [list $ip_repo_dir] [current_fileset]
update_ip_catalog -rebuild

# Add the AES-CTR VHDL sources generated and maintained by the HDL Designer project.
add_files -norecurse $aes_hdl_files
update_compile_order -fileset sources_1

# Recreate the final integrated block design.
source $bd_tcl_file

set bd_designs [get_bd_designs -quiet system]
if {[llength $bd_designs] != 1} {
    error "Expected recreated block design 'system', found [llength $bd_designs]."
}

set bd_design [lindex $bd_designs 0]
set bd_file [get_files -quiet [get_property FILE_NAME $bd_design]]

if {[llength $bd_file] != 1} {
    error "Expected one block-design file for 'system', found [llength $bd_file]."
}

set bd_name [get_property NAME $bd_design]

# Generate block-design outputs and create the top-level HDL wrapper.
generate_target all $bd_file
make_wrapper -files $bd_file -top -import

set_property top "${bd_name}_wrapper" [current_fileset]
update_compile_order -fileset sources_1

puts "Vivado AES-CTR project created successfully:"
puts "  $project_dir"
