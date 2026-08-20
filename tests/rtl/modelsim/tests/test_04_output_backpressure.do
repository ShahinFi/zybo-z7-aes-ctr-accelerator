# =============================================================================
# TEST 04 — AES-CTR Output Backpressure Verification
# =============================================================================
#
# Scope:
#   - output stalled before the first ciphertext word
#   - independent stalls on output words 1, 2, 3 and 4
#   - TVALID remains asserted while TREADY is low
#   - TDATA remains stable while TREADY is low
#   - TKEEP remains stable while TREADY is low
#   - TLAST remains stable while TREADY is low
#   - no output beat is consumed while TREADY is low
#   - exactly one beat is consumed when TREADY is asserted
#   - correct output progression after each accepted beat
#   - final TLAST remains asserted during a prolonged stall
#   - DUT remains busy while the final output beat is stalled
#   - variable and repeated output stalls
#   - correct return to idle
#   - no extra output beats after completion
# =============================================================================


# =============================================================================
# Locate and load the common test library
# =============================================================================

set TEST_DIRECTORY [file normalize [file dirname [info script]]]
set COMMON_LIBRARY [file normalize [file join $TEST_DIRECTORY .. common aes_ctr_test_lib.do]]

if {![file exists $COMMON_LIBRARY]} {
    error "Could not locate the common AES-CTR test library: $COMMON_LIBRARY"
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

proc check_stalled_output_word {
    expected_data
    expected_keep
    expected_last
    stall_cycles
    description
} {
    set TOP $::aes_test::TOP

    force -freeze ${TOP}/m_axis_tready 0

    if {![aes_test::wait_for_bit \
            ${TOP}/m_axis_tvalid \
            1 \
            300 \
            "$description output TVALID"]} {
        return 0
    }

    set result 1

    if {![aes_test::check_hex \
            ${TOP}/m_axis_tdata \
            $expected_data \
            8 \
            "$description initial TDATA"]} {
        set result 0
    }

    if {![aes_test::check_hex \
            ${TOP}/m_axis_tkeep \
            $expected_keep \
            1 \
            "$description initial TKEEP"]} {
        set result 0
    }

    if {![aes_test::check_bit \
            ${TOP}/m_axis_tlast \
            $expected_last \
            "$description initial TLAST"]} {
        set result 0
    }

    if {![aes_test::check_bit \
            ${TOP}/m_axis_tready \
            0 \
            "$description TREADY is low before stall observation"]} {
        set result 0
    }

    set held_data [aes_test::read_hex ${TOP}/m_axis_tdata 8]
    set held_keep [aes_test::read_hex ${TOP}/m_axis_tkeep 1]
    set held_last [aes_test::read_bit ${TOP}/m_axis_tlast]

    for {set cycle 1} {$cycle <= $stall_cycles} {incr cycle} {
        aes_test::run_cycles 1

        if {![aes_test::check_bit \
                ${TOP}/m_axis_tready \
                0 \
                "$description TREADY remains low during stall cycle $cycle"]} {
            set result 0
        }

        if {![aes_test::check_bit \
                ${TOP}/m_axis_tvalid \
                1 \
                "$description TVALID remains high during stall cycle $cycle"]} {
            set result 0
        }

        if {![aes_test::check_hex \
                ${TOP}/m_axis_tdata \
                $held_data \
                8 \
                "$description TDATA remains stable during stall cycle $cycle"]} {
            set result 0
        }

        if {![aes_test::check_hex \
                ${TOP}/m_axis_tkeep \
                $held_keep \
                1 \
                "$description TKEEP remains stable during stall cycle $cycle"]} {
            set result 0
        }

        if {![aes_test::check_bit \
                ${TOP}/m_axis_tlast \
                $held_last \
                "$description TLAST remains stable during stall cycle $cycle"]} {
            set result 0
        }
    }

    force -freeze ${TOP}/m_axis_tready 1

    if {![aes_test::check_bit \
            ${TOP}/m_axis_tvalid \
            1 \
            "$description TVALID is high when TREADY is asserted"]} {
        set result 0
    }

    if {![aes_test::check_hex \
            ${TOP}/m_axis_tdata \
            $held_data \
            8 \
            "$description TDATA is unchanged at acceptance"]} {
        set result 0
    }

    if {![aes_test::check_hex \
            ${TOP}/m_axis_tkeep \
            $held_keep \
            1 \
            "$description TKEEP is unchanged at acceptance"]} {
        set result 0
    }

    if {![aes_test::check_bit \
            ${TOP}/m_axis_tlast \
            $held_last \
            "$description TLAST is unchanged at acceptance"]} {
        set result 0
    }

    aes_test::run_cycles 1

    force -freeze ${TOP}/m_axis_tready 0

    return $result
}


proc run_stall_pattern {
    plaintext_words
    ciphertext_words
    stall_lengths
    description
} {
    set TOP $::aes_test::TOP

    if {[llength $plaintext_words] != 4} {
        aes_test::fail "$description requires four plaintext words"
        return 0
    }

    if {[llength $ciphertext_words] != 4} {
        aes_test::fail "$description requires four ciphertext words"
        return 0
    }

    if {[llength $stall_lengths] != 4} {
        aes_test::fail "$description requires four stall lengths"
        return 0
    }

    set result 1

    force -freeze ${TOP}/m_axis_tready 0

    if {![aes_test::start_transaction]} {
        return 0
    }

    if {![aes_test::send_full_block \
            $plaintext_words \
            1]} {
        return 0
    }

    for {set index 0} {$index < 4} {incr index} {
        set expected_last [expr {$index == 3}]
        set stall_cycles [lindex $stall_lengths $index]

        if {![check_stalled_output_word \
                [lindex $ciphertext_words $index] \
                F \
                $expected_last \
                $stall_cycles \
                "$description word [expr {$index + 1}]"]} {
            set result 0
        }

        if {$index < 3} {
            if {![aes_test::check_bit \
                    ${TOP}/aes_ctr_idle \
                    0 \
                    "$description DUT remains busy after output word [expr {$index + 1}]"]} {
                set result 0
            }
        }
    }

    if {![aes_test::check_transaction_complete]} {
        set result 0
    }

    return $result
}


# =============================================================================
# Test initialization
# =============================================================================

aes_test::begin "AES-CTR output backpressure behavior"
aes_test::initialize_simulation
aes_test::add_basic_waves

set TOP $::aes_test::TOP


# =============================================================================
# CASE 1 — VARIABLE STALL ON EVERY OUTPUT WORD
# =============================================================================

echo ""
echo "CASE 1: Variable stall length on every output word"

aes_test::apply_reset 3 2

aes_test::configure \
    $NIST_KEY \
    $NIST_NONCE \
    $NIST_INITIAL_COUNTER

run_stall_pattern \
    $PLAINTEXT_BLOCK \
    $CIPHERTEXT_BLOCK \
    {2 4 3 6} \
    "Variable-stall transaction"


# =============================================================================
# CASE 2 — PROLONGED STALL ON FIRST OUTPUT WORD
# =============================================================================

echo ""
echo "CASE 2: Prolonged stall before accepting output word 1"

aes_test::apply_reset 3 2

aes_test::configure \
    $NIST_KEY \
    $NIST_NONCE \
    $NIST_INITIAL_COUNTER

force -freeze ${TOP}/m_axis_tready 0

if {[aes_test::start_transaction]} {
    if {[aes_test::send_full_block \
            $PLAINTEXT_BLOCK \
            1]} {

        check_stalled_output_word \
            [lindex $CIPHERTEXT_BLOCK 0] \
            F \
            0 \
            20 \
            "Prolonged first-word stall"

        check_stalled_output_word \
            [lindex $CIPHERTEXT_BLOCK 1] \
            F \
            0 \
            1 \
            "Post-first-stall word 2"

        check_stalled_output_word \
            [lindex $CIPHERTEXT_BLOCK 2] \
            F \
            0 \
            1 \
            "Post-first-stall word 3"

        check_stalled_output_word \
            [lindex $CIPHERTEXT_BLOCK 3] \
            F \
            1 \
            1 \
            "Post-first-stall word 4"
    }
}

aes_test::check_transaction_complete


# =============================================================================
# CASE 3 — PROLONGED STALL ON FINAL TLAST WORD
# =============================================================================

echo ""
echo "CASE 3: Prolonged stall on final TLAST output word"

aes_test::apply_reset 3 2

aes_test::configure \
    $NIST_KEY \
    $NIST_NONCE \
    $NIST_INITIAL_COUNTER

force -freeze ${TOP}/m_axis_tready 0

if {[aes_test::start_transaction]} {
    if {[aes_test::send_full_block \
            $PLAINTEXT_BLOCK \
            1]} {

        check_stalled_output_word \
            [lindex $CIPHERTEXT_BLOCK 0] \
            F \
            0 \
            1 \
            "Final-stall setup word 1"

        check_stalled_output_word \
            [lindex $CIPHERTEXT_BLOCK 1] \
            F \
            0 \
            1 \
            "Final-stall setup word 2"

        check_stalled_output_word \
            [lindex $CIPHERTEXT_BLOCK 2] \
            F \
            0 \
            1 \
            "Final-stall setup word 3"

        force -freeze ${TOP}/m_axis_tready 0

        if {[aes_test::wait_for_bit \
                ${TOP}/m_axis_tvalid \
                1 \
                300 \
                "final TLAST word to become valid"]} {

            aes_test::check_hex \
                ${TOP}/m_axis_tdata \
                [lindex $CIPHERTEXT_BLOCK 3] \
                8 \
                "Final stalled word has correct TDATA"

            aes_test::check_hex \
                ${TOP}/m_axis_tkeep \
                F \
                1 \
                "Final stalled word has correct TKEEP"

            aes_test::check_bit \
                ${TOP}/m_axis_tlast \
                1 \
                "Final stalled word asserts TLAST"

            for {set cycle 1} {$cycle <= 20} {incr cycle} {
                aes_test::run_cycles 1

                aes_test::check_bit \
                    ${TOP}/aes_ctr_idle \
                    0 \
                    "DUT remains busy while final word is stalled, cycle $cycle"

                aes_test::check_bit \
                    ${TOP}/m_axis_tvalid \
                    1 \
                    "Final TVALID remains high during stall cycle $cycle"

                aes_test::check_hex \
                    ${TOP}/m_axis_tdata \
                    [lindex $CIPHERTEXT_BLOCK 3] \
                    8 \
                    "Final TDATA remains stable during stall cycle $cycle"

                aes_test::check_hex \
                    ${TOP}/m_axis_tkeep \
                    F \
                    1 \
                    "Final TKEEP remains stable during stall cycle $cycle"

                aes_test::check_bit \
                    ${TOP}/m_axis_tlast \
                    1 \
                    "Final TLAST remains high during stall cycle $cycle"
            }

            force -freeze ${TOP}/m_axis_tready 1

            aes_test::check_bit \
                ${TOP}/m_axis_tvalid \
                1 \
                "Final TVALID is high when final beat is accepted"

            aes_test::check_bit \
                ${TOP}/m_axis_tlast \
                1 \
                "Final TLAST is high when final beat is accepted"

            aes_test::run_cycles 1
            force -freeze ${TOP}/m_axis_tready 0
        }
    }
}

aes_test::check_transaction_complete


# =============================================================================
# CASE 4 — REPEATED SHORT READY/NOT-READY PATTERN
# =============================================================================

echo ""
echo "CASE 4: Repeated short stalls on consecutive output words"

aes_test::apply_reset 3 2

aes_test::configure \
    $NIST_KEY \
    $NIST_NONCE \
    $NIST_INITIAL_COUNTER

run_stall_pattern \
    $PLAINTEXT_BLOCK \
    $CIPHERTEXT_BLOCK \
    {1 2 1 2} \
    "Repeated-short-stall transaction"


# =============================================================================
# CASE 5 — ZERO-LENGTH AND MIXED STALLS
# =============================================================================

echo ""
echo "CASE 5: Mixed immediate acceptance and stalled acceptance"

aes_test::apply_reset 3 2

aes_test::configure \
    $NIST_KEY \
    $NIST_NONCE \
    $NIST_INITIAL_COUNTER

run_stall_pattern \
    $PLAINTEXT_BLOCK \
    $CIPHERTEXT_BLOCK \
    {0 5 0 3} \
    "Mixed-stall transaction"


# =============================================================================
# Final result
# =============================================================================

set TEST_PASSED [aes_test::finish]

catch {wave zoom full}

if {!$TEST_PASSED} {
    error "test_04_output_backpressure.do failed"
}