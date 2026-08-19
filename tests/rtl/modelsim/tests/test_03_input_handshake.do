# =============================================================================
# TEST 03 — AES-CTR Input Handshake Verification
# =============================================================================
#
# Scope:
#   - TVALID asserted before TREADY
#   - source stability while waiting for TREADY
#   - exactly one accepted word after handshake
#   - input gaps between every word position
#   - four back-to-back input words
#   - TLAST accepted on input words 1, 2, 3 and 4
#   - correct input word ordering
#   - no lost, duplicated or reordered words
#   - correct ciphertext for every traffic pattern
#   - correct output TKEEP and TLAST
#   - correct return to idle
#   - no extra output beats
#
# This test intentionally checks AXI-Stream source behavior where TVALID may
# be asserted before TREADY. If the DUT consumes TVALID without TREADY, the
# known-answer comparison will fail.
# =============================================================================


# =============================================================================
# Locate and load the common test library
# =============================================================================

set COMMON_LIBRARY ""
set SEARCH_DIRECTORY [file normalize [pwd]]

for {set level 0} {$level < 8} {incr level} {
    set candidate [file normalize \
        [file join \
            $SEARCH_DIRECTORY \
            sim \
            common \
            aes_ctr_test_lib.do]]

    if {[file exists $candidate]} {
        set COMMON_LIBRARY $candidate
        break
    }

    set parent [file dirname $SEARCH_DIRECTORY]

    if {$parent eq $SEARCH_DIRECTORY} {
        break
    }

    set SEARCH_DIRECTORY $parent
}

if {$COMMON_LIBRARY eq ""} {
    error "Could not locate sim/common/aes_ctr_test_lib.do from [pwd]"
}

echo "Loading common library: $COMMON_LIBRARY"
source $COMMON_LIBRARY


# =============================================================================
# NIST test configuration
# =============================================================================

set NIST_KEY \
    2B7E151628AED2A6ABF7158809CF4F3C

set NIST_NONCE \
    F0F1F2F3F4F5F6F7F8F9FAFB

set NIST_INITIAL_COUNTER \
    FCFDFEFF

set PLAINTEXT_BLOCK {
    6BC1BEE2
    2E409F96
    E93D7E11
    7393172A
}

set CIPHERTEXT_BLOCK {
    874D6191
    B620E326
    1BEF6864
    990DB6CE
}


# =============================================================================
# Test-specific helper procedures
# =============================================================================

proc send_first_word_valid_before_ready {
    data
    keep
    last
    idle_wait_cycles
} {
    set TOP $::aes_test::TOP

    aes_test::check_bit \
        ${TOP}/aes_ctr_idle \
        1 \
        "DUT is idle before TVALID-before-TREADY test"

    aes_test::check_bit \
        ${TOP}/s_axis_tready \
        0 \
        "Input TREADY is low before START"

    force -freeze ${TOP}/s_axis_tdata 16#$data
    force -freeze ${TOP}/s_axis_tkeep 16#$keep
    force -freeze ${TOP}/s_axis_tlast $last
    force -freeze ${TOP}/s_axis_tvalid 1

    set held_data [aes_test::read_hex ${TOP}/s_axis_tdata 8]
    set held_keep [aes_test::read_hex ${TOP}/s_axis_tkeep 1]
    set held_last [aes_test::read_bit ${TOP}/s_axis_tlast]

    for {set cycle 1} {$cycle <= $idle_wait_cycles} {incr cycle} {
        aes_test::run_cycles 1

        aes_test::check_bit \
            ${TOP}/s_axis_tvalid \
            1 \
            "TVALID remains asserted before TREADY, cycle $cycle"

        aes_test::check_hex \
            ${TOP}/s_axis_tdata \
            $held_data \
            8 \
            "TDATA remains stable before TREADY, cycle $cycle"

        aes_test::check_hex \
            ${TOP}/s_axis_tkeep \
            $held_keep \
            1 \
            "TKEEP remains stable before TREADY, cycle $cycle"

        aes_test::check_bit \
            ${TOP}/s_axis_tlast \
            $held_last \
            "TLAST remains stable before TREADY, cycle $cycle"

        aes_test::check_bit \
            ${TOP}/s_axis_tready \
            0 \
            "TREADY remains low before START, cycle $cycle"
    }

    force -freeze ${TOP}/aes_ctr_start 1
    aes_test::run_cycles 1
    force -freeze ${TOP}/aes_ctr_start 0

    if {![aes_test::wait_for_bit \
            ${TOP}/s_axis_tready \
            1 \
            20 \
            "input TREADY after START while TVALID is already asserted"]} {
        force -freeze ${TOP}/s_axis_tvalid 0
        return 0
    }

    aes_test::check_bit \
        ${TOP}/aes_ctr_idle \
        0 \
        "DUT is busy when the held input word is accepted"

    aes_test::check_bit \
        ${TOP}/s_axis_tvalid \
        1 \
        "TVALID remains asserted until the handshake"

    aes_test::check_hex \
        ${TOP}/s_axis_tdata \
        $held_data \
        8 \
        "TDATA is unchanged at the handshake"

    aes_test::check_hex \
        ${TOP}/s_axis_tkeep \
        $held_keep \
        1 \
        "TKEEP is unchanged at the handshake"

    aes_test::check_bit \
        ${TOP}/s_axis_tlast \
        $held_last \
        "TLAST is unchanged at the handshake"

    # Complete exactly one TVALID/TREADY transfer.
    aes_test::run_cycles 1

    force -freeze ${TOP}/s_axis_tvalid 0
    force -freeze ${TOP}/s_axis_tlast 0
    force -freeze ${TOP}/s_axis_tkeep 16#0
    force -freeze ${TOP}/s_axis_tdata 16#00000000

    return 1
}


proc send_full_block_back_to_back {
    words
    final_block
} {
    set TOP $::aes_test::TOP

    if {[llength $words] != 4} {
        aes_test::fail \
            "send_full_block_back_to_back requires exactly four words"
        return 0
    }

    if {![aes_test::wait_for_bit \
            ${TOP}/s_axis_tready \
            1 \
            200 \
            "input TREADY before back-to-back transfer"]} {
        return 0
    }

    force -freeze ${TOP}/s_axis_tvalid 1
    force -freeze ${TOP}/s_axis_tkeep 16#F

    for {set index 0} {$index < 4} {incr index} {
        set last 0

        if {$final_block && $index == 3} {
            set last 1
        }

        force -freeze \
            ${TOP}/s_axis_tdata \
            16#[lindex $words $index]

        force -freeze ${TOP}/s_axis_tlast $last

        aes_test::check_bit \
            ${TOP}/s_axis_tready \
            1 \
            "TREADY is high for back-to-back word [expr {$index + 1}]"

        aes_test::check_bit \
            ${TOP}/s_axis_tvalid \
            1 \
            "TVALID is continuously high for back-to-back word [expr {$index + 1}]"

        aes_test::check_hex \
            ${TOP}/s_axis_tdata \
            [lindex $words $index] \
            8 \
            "Back-to-back word [expr {$index + 1}] has correct TDATA"

        aes_test::check_hex \
            ${TOP}/s_axis_tkeep \
            F \
            1 \
            "Back-to-back word [expr {$index + 1}] has correct TKEEP"

        aes_test::check_bit \
            ${TOP}/s_axis_tlast \
            $last \
            "Back-to-back word [expr {$index + 1}] has correct TLAST"

        aes_test::run_cycles 1
    }

    force -freeze ${TOP}/s_axis_tvalid 0
    force -freeze ${TOP}/s_axis_tlast 0
    force -freeze ${TOP}/s_axis_tkeep 16#0
    force -freeze ${TOP}/s_axis_tdata 16#00000000

    return 1
}


proc send_block_with_gaps {
    words
    gaps
    final_block
} {
    if {[llength $words] != 4} {
        aes_test::fail "send_block_with_gaps requires four input words"
        return 0
    }

    if {[llength $gaps] != 4} {
        aes_test::fail "send_block_with_gaps requires four gap values"
        return 0
    }

    for {set index 0} {$index < 4} {incr index} {
        set gap_cycles [lindex $gaps $index]

        if {$gap_cycles > 0} {
            aes_test::run_cycles $gap_cycles
        }

        set last 0

        if {$final_block && $index == 3} {
            set last 1
        }

        if {![aes_test::send_input_word \
                [lindex $words $index] \
                F \
                $last]} {
            return 0
        }
    }

    return 1
}


# =============================================================================
# Test initialization
# =============================================================================

aes_test::begin "AES-CTR input handshake behavior"
aes_test::initialize_simulation
aes_test::add_basic_waves

set TOP $::aes_test::TOP


# =============================================================================
# CASE 1 — TVALID ASSERTED BEFORE TREADY
# =============================================================================

echo ""
echo "CASE 1: TVALID asserted before TREADY"

aes_test::apply_reset 3 2

aes_test::configure \
    $NIST_KEY \
    $NIST_NONCE \
    $NIST_INITIAL_COUNTER

force -freeze ${TOP}/m_axis_tready 0

if {[send_first_word_valid_before_ready \
        [lindex $PLAINTEXT_BLOCK 0] \
        F \
        0 \
        4]} {

    aes_test::send_input_word \
        [lindex $PLAINTEXT_BLOCK 1] \
        F \
        0

    aes_test::send_input_word \
        [lindex $PLAINTEXT_BLOCK 2] \
        F \
        0

    aes_test::send_input_word \
        [lindex $PLAINTEXT_BLOCK 3] \
        F \
        1

    aes_test::check_full_block \
        $CIPHERTEXT_BLOCK \
        1 \
        "TVALID-before-TREADY ciphertext"
}

aes_test::check_transaction_complete


# =============================================================================
# CASE 2 — INPUT GAPS AT EVERY WORD BOUNDARY
# =============================================================================

echo ""
echo "CASE 2: Input TVALID gaps"

aes_test::apply_reset 3 2

aes_test::configure \
    $NIST_KEY \
    $NIST_NONCE \
    $NIST_INITIAL_COUNTER

force -freeze ${TOP}/m_axis_tready 0

if {[aes_test::start_transaction]} {
    if {[send_block_with_gaps \
            $PLAINTEXT_BLOCK \
            {3 1 5 2} \
            1]} {

        aes_test::check_full_block \
            $CIPHERTEXT_BLOCK \
            1 \
            "Input-gap ciphertext"
    }
}

aes_test::check_transaction_complete


# =============================================================================
# CASE 3 — FOUR BACK-TO-BACK INPUT WORDS
# =============================================================================

echo ""
echo "CASE 3: Four back-to-back input words"

aes_test::apply_reset 3 2

aes_test::configure \
    $NIST_KEY \
    $NIST_NONCE \
    $NIST_INITIAL_COUNTER

force -freeze ${TOP}/m_axis_tready 0

if {[aes_test::start_transaction]} {
    if {[send_full_block_back_to_back \
            $PLAINTEXT_BLOCK \
            1]} {

        aes_test::check_full_block \
            $CIPHERTEXT_BLOCK \
            1 \
            "Back-to-back ciphertext"
    }
}

aes_test::check_transaction_complete


# =============================================================================
# CASE 4 — TLAST ON INPUT WORD 1
# =============================================================================

echo ""
echo "CASE 4: TLAST accepted on input word 1"

aes_test::apply_reset 3 2

aes_test::configure \
    $NIST_KEY \
    $NIST_NONCE \
    $NIST_INITIAL_COUNTER

force -freeze ${TOP}/m_axis_tready 0

if {[aes_test::start_transaction]} {
    aes_test::send_input_word \
        [lindex $PLAINTEXT_BLOCK 0] \
        F \
        1

    aes_test::check_output_word \
        [lindex $CIPHERTEXT_BLOCK 0] \
        F \
        1 \
        "TLAST-on-word-1 output"
}

aes_test::check_transaction_complete


# =============================================================================
# CASE 5 — TLAST ON INPUT WORD 2
# =============================================================================

echo ""
echo "CASE 5: TLAST accepted on input word 2"

aes_test::apply_reset 3 2

aes_test::configure \
    $NIST_KEY \
    $NIST_NONCE \
    $NIST_INITIAL_COUNTER

force -freeze ${TOP}/m_axis_tready 0

if {[aes_test::start_transaction]} {
    aes_test::send_input_word \
        [lindex $PLAINTEXT_BLOCK 0] \
        F \
        0

    aes_test::send_input_word \
        [lindex $PLAINTEXT_BLOCK 1] \
        F \
        1

    aes_test::check_output_word \
        [lindex $CIPHERTEXT_BLOCK 0] \
        F \
        0 \
        "TLAST-on-word-2 output word 1"

    aes_test::check_output_word \
        [lindex $CIPHERTEXT_BLOCK 1] \
        F \
        1 \
        "TLAST-on-word-2 output word 2"
}

aes_test::check_transaction_complete


# =============================================================================
# CASE 6 — TLAST ON INPUT WORD 3
# =============================================================================

echo ""
echo "CASE 6: TLAST accepted on input word 3"

aes_test::apply_reset 3 2

aes_test::configure \
    $NIST_KEY \
    $NIST_NONCE \
    $NIST_INITIAL_COUNTER

force -freeze ${TOP}/m_axis_tready 0

if {[aes_test::start_transaction]} {
    aes_test::send_input_word \
        [lindex $PLAINTEXT_BLOCK 0] \
        F \
        0

    aes_test::send_input_word \
        [lindex $PLAINTEXT_BLOCK 1] \
        F \
        0

    aes_test::send_input_word \
        [lindex $PLAINTEXT_BLOCK 2] \
        F \
        1

    aes_test::check_output_word \
        [lindex $CIPHERTEXT_BLOCK 0] \
        F \
        0 \
        "TLAST-on-word-3 output word 1"

    aes_test::check_output_word \
        [lindex $CIPHERTEXT_BLOCK 1] \
        F \
        0 \
        "TLAST-on-word-3 output word 2"

    aes_test::check_output_word \
        [lindex $CIPHERTEXT_BLOCK 2] \
        F \
        1 \
        "TLAST-on-word-3 output word 3"
}

aes_test::check_transaction_complete


# =============================================================================
# CASE 7 — TLAST ON INPUT WORD 4
# =============================================================================

echo ""
echo "CASE 7: TLAST accepted on input word 4"

aes_test::apply_reset 3 2

aes_test::configure \
    $NIST_KEY \
    $NIST_NONCE \
    $NIST_INITIAL_COUNTER

force -freeze ${TOP}/m_axis_tready 0

if {[aes_test::start_transaction]} {
    aes_test::send_full_block \
        $PLAINTEXT_BLOCK \
        1

    aes_test::check_full_block \
        $CIPHERTEXT_BLOCK \
        1 \
        "TLAST-on-word-4 output"
}

aes_test::check_transaction_complete


# =============================================================================
# Final result
# =============================================================================

set TEST_PASSED [aes_test::finish]

catch {wave zoom full}

if {!$TEST_PASSED} {
    error "test_03_input_handshake.do failed"
}
