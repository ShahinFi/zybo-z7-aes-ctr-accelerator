# =============================================================================
# TEST 01 — AES-CTR Reset and Idle-State Verification
# =============================================================================


# Locate the common test library relative to this test script.

set TEST_DIRECTORY [file normalize [file dirname [info script]]]
set COMMON_LIBRARY [file normalize [file join $TEST_DIRECTORY .. common aes_ctr_test_lib.do]]

if {![file exists $COMMON_LIBRARY]} {
    error "Could not locate the common AES-CTR test library: $COMMON_LIBRARY"
}

echo "Loading common library: $COMMON_LIBRARY"
source $COMMON_LIBRARY


# =============================================================================
# Test initialization
# =============================================================================

aes_test::begin "Reset and idle-state behavior"
aes_test::initialize_simulation
aes_test::add_basic_waves

set TOP $::aes_test::TOP


# =============================================================================
# CASE 1 — RESET ASSERTION
# =============================================================================

echo ""
echo "CASE 1: Assert synchronous reset"

aes_test::assert_reset 3

aes_test::check_bit \
    ${TOP}/aes_ctr_idle \
    1 \
    "DUT is idle while reset is asserted"

aes_test::check_bit \
    ${TOP}/s_axis_tready \
    0 \
    "Input TREADY is low while reset is asserted"

aes_test::check_bit \
    ${TOP}/m_axis_tvalid \
    0 \
    "Output TVALID is low while reset is asserted"

aes_test::check_bit \
    ${TOP}/m_axis_tlast \
    0 \
    "Output TLAST is low while reset is asserted"


for {set cycle 1} {$cycle <= 3} {incr cycle} {
    aes_test::run_cycles 1

    aes_test::check_bit \
        ${TOP}/aes_ctr_idle \
        1 \
        "DUT remains idle during extended reset cycle $cycle"

    aes_test::check_bit \
        ${TOP}/s_axis_tready \
        0 \
        "Input TREADY remains low during extended reset cycle $cycle"

    aes_test::check_bit \
        ${TOP}/m_axis_tvalid \
        0 \
        "Output TVALID remains low during extended reset cycle $cycle"

    aes_test::check_bit \
        ${TOP}/m_axis_tlast \
        0 \
        "Output TLAST remains low during extended reset cycle $cycle"
}


# =============================================================================
# CASE 2 — RESET RELEASE
# =============================================================================

echo ""
echo "CASE 2: Release reset"

aes_test::release_reset 2

aes_test::check_bit \
    ${TOP}/aes_ctr_idle \
    1 \
    "DUT is idle after reset release"

aes_test::check_bit \
    ${TOP}/s_axis_tready \
    0 \
    "Input TREADY remains low until a transaction starts"

aes_test::check_bit \
    ${TOP}/m_axis_tvalid \
    0 \
    "Output TVALID remains low after reset release"

aes_test::check_bit \
    ${TOP}/m_axis_tlast \
    0 \
    "Output TLAST remains low after reset release"


for {set cycle 1} {$cycle <= 10} {incr cycle} {
    aes_test::run_cycles 1

    aes_test::check_bit \
        ${TOP}/aes_ctr_idle \
        1 \
        "DUT remains idle without START during idle cycle $cycle"

    aes_test::check_bit \
        ${TOP}/s_axis_tready \
        0 \
        "Input TREADY remains low without START during idle cycle $cycle"

    aes_test::check_bit \
        ${TOP}/m_axis_tvalid \
        0 \
        "No output appears without START during idle cycle $cycle"

    aes_test::check_bit \
        ${TOP}/m_axis_tlast \
        0 \
        "No output TLAST appears without START during idle cycle $cycle"
}


# =============================================================================
# CASE 3 — RESET WITH NONZERO INPUTS PRESENT
# =============================================================================

echo ""
echo "CASE 3: Reset with nonzero configuration and stream inputs"

aes_test::configure \
    2B7E151628AED2A6ABF7158809CF4F3C \
    F0F1F2F3F4F5F6F7F8F9FAFB \
    FCFDFEFF

force -freeze ${TOP}/aes_ctr_start 1
force -freeze ${TOP}/s_axis_tdata 16#DEADBEEF
force -freeze ${TOP}/s_axis_tkeep 16#F
force -freeze ${TOP}/s_axis_tvalid 1
force -freeze ${TOP}/s_axis_tlast 1
force -freeze ${TOP}/m_axis_tready 0

force -freeze ${TOP}/reset_n 0

aes_test::run_cycles 3

aes_test::check_bit \
    ${TOP}/aes_ctr_idle \
    1 \
    "Reset overrides asserted START and nonzero stream inputs"

aes_test::check_bit \
    ${TOP}/s_axis_tready \
    0 \
    "Input TREADY stays low during reset with TVALID asserted"

aes_test::check_bit \
    ${TOP}/m_axis_tvalid \
    0 \
    "No output is generated during reset with nonzero inputs"

aes_test::check_bit \
    ${TOP}/m_axis_tlast \
    0 \
    "No output TLAST is generated during reset with nonzero inputs"


force -freeze ${TOP}/aes_ctr_start 0
force -freeze ${TOP}/s_axis_tdata 16#00000000
force -freeze ${TOP}/s_axis_tkeep 16#0
force -freeze ${TOP}/s_axis_tvalid 0
force -freeze ${TOP}/s_axis_tlast 0
force -freeze ${TOP}/m_axis_tready 1

aes_test::release_reset 2

aes_test::check_bit \
    ${TOP}/aes_ctr_idle \
    1 \
    "DUT returns cleanly to idle after reset with nonzero inputs"

aes_test::check_bit \
    ${TOP}/s_axis_tready \
    0 \
    "Input TREADY is low after recovery"

aes_test::check_bit \
    ${TOP}/m_axis_tvalid \
    0 \
    "Output TVALID is low after recovery"

aes_test::check_bit \
    ${TOP}/m_axis_tlast \
    0 \
    "Output TLAST is low after recovery"


# =============================================================================
# CASE 4 — REPEATED RESET WHILE IDLE
# =============================================================================

echo ""
echo "CASE 4: Repeated reset while already idle"

for {set reset_number 1} {$reset_number <= 3} {incr reset_number} {
    aes_test::assert_reset 2

    aes_test::check_bit \
        ${TOP}/aes_ctr_idle \
        1 \
        "Repeated reset $reset_number holds the DUT idle"

    aes_test::check_bit \
        ${TOP}/s_axis_tready \
        0 \
        "Repeated reset $reset_number keeps input TREADY low"

    aes_test::check_bit \
        ${TOP}/m_axis_tvalid \
        0 \
        "Repeated reset $reset_number produces no output"

    aes_test::check_bit \
        ${TOP}/m_axis_tlast \
        0 \
        "Repeated reset $reset_number produces no output TLAST"

    aes_test::release_reset 2

    aes_test::check_bit \
        ${TOP}/aes_ctr_idle \
        1 \
        "DUT returns to idle after repeated reset $reset_number"

    aes_test::check_bit \
        ${TOP}/s_axis_tready \
        0 \
        "Input TREADY is low after repeated reset $reset_number"

    aes_test::check_bit \
        ${TOP}/m_axis_tvalid \
        0 \
        "Output TVALID is low after repeated reset $reset_number"

    aes_test::check_bit \
        ${TOP}/m_axis_tlast \
        0 \
        "Output TLAST is low after repeated reset $reset_number"
}


# =============================================================================
# CASE 5 — FINAL QUIESCENT-STATE CHECK
# =============================================================================

echo ""
echo "CASE 5: Final quiescent-state observation"

for {set cycle 1} {$cycle <= 10} {incr cycle} {
    aes_test::run_cycles 1

    aes_test::check_bit \
        ${TOP}/aes_ctr_idle \
        1 \
        "DUT remains idle during final observation cycle $cycle"

    aes_test::check_bit \
        ${TOP}/s_axis_tready \
        0 \
        "Input TREADY remains low during final observation cycle $cycle"

    aes_test::check_bit \
        ${TOP}/m_axis_tvalid \
        0 \
        "Output TVALID remains low during final observation cycle $cycle"

    aes_test::check_bit \
        ${TOP}/m_axis_tlast \
        0 \
        "Output TLAST remains low during final observation cycle $cycle"
}


# =============================================================================
# Final result
# =============================================================================

set TEST_PASSED [aes_test::finish]

catch {wave zoom full}

if {!$TEST_PASSED} {
    error "test_01_reset.do failed"
}