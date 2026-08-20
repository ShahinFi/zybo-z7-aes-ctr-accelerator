# =============================================================================
# TEST 06 — AES-CTR START-While-Busy Verification
# =============================================================================
#
# Scope:
#   - START pulse during input collection
#   - START pulse after input collection and before output availability
#   - START pulse during active output serialization
#   - START pulse while an output word is stalled by TREADY = 0
#   - repeated START pulses during one active transaction
#   - configuration changes combined with an invalid busy START pulse
#   - active transaction must not restart
#   - active key, nonce and counter must not be reloaded
#   - no input or output word may be lost, duplicated or reordered
#   - ciphertext must remain correct after every busy START pulse
#   - TLAST and TKEEP must remain correct
#   - DUT must remain busy until the original final output is accepted
#   - DUT must return to idle normally
#   - a new START must work normally after the DUT returns to idle
#   - no extra output beats may appear
#
# This is a black-box top-level test. A busy START is considered correctly
# ignored when the original transaction completes with its original expected
# ciphertext and no additional or restarted transaction appears.
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
# Test vectors
# =============================================================================

set NIST_KEY \
    2B7E151628AED2A6ABF7158809CF4F3C

set NIST_NONCE \
    F0F1F2F3F4F5F6F7F8F9FAFB

set NIST_INITIAL_COUNTER \
    FCFDFEFF

set NIST_PLAINTEXT {
    6BC1BEE2
    2E409F96
    E93D7E11
    7393172A
}

set NIST_CIPHERTEXT {
    874D6191
    B620E326
    1BEF6864
    990DB6CE
}


# Independent replacement configuration used to detect accidental reload.

set REPLACEMENT_KEY \
    00000000000000000000000000000000

set REPLACEMENT_NONCE \
    000000000000000000000000

set REPLACEMENT_COUNTER \
    00000000

set ZERO_PLAINTEXT {
    00000000
    00000000
    00000000
    00000000
}

set ZERO_CIPHERTEXT_COUNTER_0 {
    66E94BD4
    EF8A2C3B
    884CFA59
    CA342B2E
}


# =============================================================================
# Test-specific helper procedures
# =============================================================================

proc pulse_start_while_busy {description} {
    set TOP $::aes_test::TOP
    set result 1

    if {![aes_test::check_bit \
            ${TOP}/aes_ctr_idle \
            0 \
            "$description: DUT is busy before START pulse"]} {
        set result 0
    }

    force -freeze ${TOP}/aes_ctr_start 1

    if {![aes_test::check_bit \
            ${TOP}/aes_ctr_start \
            1 \
            "$description: START is asserted"]} {
        set result 0
    }

    aes_test::run_cycles 1

    force -freeze ${TOP}/aes_ctr_start 0

    if {![aes_test::check_bit \
            ${TOP}/aes_ctr_idle \
            0 \
            "$description: DUT remains busy after START pulse"]} {
        set result 0
    }

    return $result
}


proc pulse_start_repeatedly_while_busy {pulse_count gap_cycles description} {
    set result 1

    for {set pulse_index 1} {
        $pulse_index <= $pulse_count
    } {
        incr pulse_index
    } {
        if {![pulse_start_while_busy \
                "$description pulse $pulse_index"]} {
            set result 0
        }

        if {$gap_cycles > 0 && $pulse_index < $pulse_count} {
            aes_test::run_cycles $gap_cycles
        }
    }

    return $result
}


proc check_and_accept_word_with_busy_start {
    expected_data
    expected_keep
    expected_last
    description
} {
    set TOP $::aes_test::TOP
    set result 1

    force -freeze ${TOP}/m_axis_tready 0

    if {![aes_test::wait_for_bit \
            ${TOP}/m_axis_tvalid \
            1 \
            300 \
            "$description output TVALID"]} {
        return 0
    }

    if {![aes_test::check_hex \
            ${TOP}/m_axis_tdata \
            $expected_data \
            8 \
            "$description TDATA before acceptance"]} {
        set result 0
    }

    if {![aes_test::check_hex \
            ${TOP}/m_axis_tkeep \
            $expected_keep \
            1 \
            "$description TKEEP before acceptance"]} {
        set result 0
    }

    if {![aes_test::check_bit \
            ${TOP}/m_axis_tlast \
            $expected_last \
            "$description TLAST before acceptance"]} {
        set result 0
    }

    if {![aes_test::check_bit \
            ${TOP}/aes_ctr_idle \
            0 \
            "$description DUT is busy before output acceptance"]} {
        set result 0
    }

    # Assert START during the same cycle in which this output beat is accepted.
    force -freeze ${TOP}/aes_ctr_start 1
    force -freeze ${TOP}/m_axis_tready 1

    if {![aes_test::check_bit \
            ${TOP}/m_axis_tvalid \
            1 \
            "$description TVALID is high at acceptance"]} {
        set result 0
    }

    if {![aes_test::check_bit \
            ${TOP}/m_axis_tready \
            1 \
            "$description TREADY is high at acceptance"]} {
        set result 0
    }

    if {![aes_test::check_bit \
            ${TOP}/aes_ctr_start \
            1 \
            "$description START is high during output acceptance"]} {
        set result 0
    }

    aes_test::run_cycles 1

    force -freeze ${TOP}/aes_ctr_start 0
    force -freeze ${TOP}/m_axis_tready 0

    return $result
}


proc check_stalled_word_with_busy_start {
    expected_data
    expected_keep
    expected_last
    stall_cycles
    start_pulse_cycle
    description
} {
    set TOP $::aes_test::TOP
    set result 1

    force -freeze ${TOP}/m_axis_tready 0

    if {![aes_test::wait_for_bit \
            ${TOP}/m_axis_tvalid \
            1 \
            300 \
            "$description output TVALID"]} {
        return 0
    }

    set held_data [aes_test::read_hex ${TOP}/m_axis_tdata 8]
    set held_keep [aes_test::read_hex ${TOP}/m_axis_tkeep 1]
    set held_last [aes_test::read_bit ${TOP}/m_axis_tlast]

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

    for {set cycle 1} {$cycle <= $stall_cycles} {incr cycle} {
        if {$cycle == $start_pulse_cycle} {
            force -freeze ${TOP}/aes_ctr_start 1
        } else {
            force -freeze ${TOP}/aes_ctr_start 0
        }

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

        if {![aes_test::check_bit \
                ${TOP}/aes_ctr_idle \
                0 \
                "$description DUT remains busy during stall cycle $cycle"]} {
            set result 0
        }
    }

    force -freeze ${TOP}/aes_ctr_start 0

    # Accept exactly this output beat.
    force -freeze ${TOP}/m_axis_tready 1
    aes_test::run_cycles 1
    force -freeze ${TOP}/m_axis_tready 0

    return $result
}


# =============================================================================
# Test initialization
# =============================================================================

aes_test::begin "AES-CTR START while busy behavior"
aes_test::initialize_simulation
aes_test::add_basic_waves

set TOP $::aes_test::TOP


# =============================================================================
# CASE 1 — START DURING INPUT COLLECTION
# =============================================================================

echo ""
echo "CASE 1: START pulse during input collection"

aes_test::apply_reset 3 2

aes_test::configure \
    $NIST_KEY \
    $NIST_NONCE \
    $NIST_INITIAL_COUNTER

force -freeze ${TOP}/m_axis_tready 0

if {[aes_test::start_transaction]} {
    aes_test::send_input_word \
        [lindex $NIST_PLAINTEXT 0] \
        F \
        0

    pulse_start_while_busy \
        "Collection-phase busy START"

    aes_test::send_input_word \
        [lindex $NIST_PLAINTEXT 1] \
        F \
        0

    aes_test::send_input_word \
        [lindex $NIST_PLAINTEXT 2] \
        F \
        0

    aes_test::send_input_word \
        [lindex $NIST_PLAINTEXT 3] \
        F \
        1

    aes_test::check_full_block \
        $NIST_CIPHERTEXT \
        1 \
        "Collection-phase busy START ciphertext"
}

aes_test::check_transaction_complete


# =============================================================================
# CASE 2 — START AFTER COLLECTION, BEFORE OUTPUT
# =============================================================================

echo ""
echo "CASE 2: START pulse after input collection and before output availability"

aes_test::apply_reset 3 2

aes_test::configure \
    $NIST_KEY \
    $NIST_NONCE \
    $NIST_INITIAL_COUNTER

force -freeze ${TOP}/m_axis_tready 0

if {[aes_test::start_transaction]} {
    if {[aes_test::send_full_block \
            $NIST_PLAINTEXT \
            1]} {

        aes_test::check_bit \
            ${TOP}/aes_ctr_idle \
            0 \
            "DUT remains busy after input block collection"

        aes_test::check_bit \
            ${TOP}/m_axis_tvalid \
            0 \
            "Output is not yet valid immediately after collection"

        pulse_start_while_busy \
            "Post-collection busy START"

        aes_test::check_full_block \
            $NIST_CIPHERTEXT \
            1 \
            "Post-collection busy START ciphertext"
    }
}

aes_test::check_transaction_complete


# =============================================================================
# CASE 3 — START DURING ACTIVE OUTPUT SERIALIZATION
# =============================================================================

echo ""
echo "CASE 3: START pulse during active output serialization"

aes_test::apply_reset 3 2

aes_test::configure \
    $NIST_KEY \
    $NIST_NONCE \
    $NIST_INITIAL_COUNTER

force -freeze ${TOP}/m_axis_tready 0

if {[aes_test::start_transaction]} {
    if {[aes_test::send_full_block \
            $NIST_PLAINTEXT \
            1]} {

        check_and_accept_word_with_busy_start \
            [lindex $NIST_CIPHERTEXT 0] \
            F \
            0 \
            "Serialization busy START word 1"

        aes_test::check_output_word \
            [lindex $NIST_CIPHERTEXT 1] \
            F \
            0 \
            "Serialization busy START word 2"

        aes_test::check_output_word \
            [lindex $NIST_CIPHERTEXT 2] \
            F \
            0 \
            "Serialization busy START word 3"

        aes_test::check_output_word \
            [lindex $NIST_CIPHERTEXT 3] \
            F \
            1 \
            "Serialization busy START word 4"
    }
}

aes_test::check_transaction_complete


# =============================================================================
# CASE 4 — START DURING OUTPUT BACKPRESSURE STALL
# =============================================================================

echo ""
echo "CASE 4: START pulse while an output word is stalled"

aes_test::apply_reset 3 2

aes_test::configure \
    $NIST_KEY \
    $NIST_NONCE \
    $NIST_INITIAL_COUNTER

force -freeze ${TOP}/m_axis_tready 0

if {[aes_test::start_transaction]} {
    if {[aes_test::send_full_block \
            $NIST_PLAINTEXT \
            1]} {

        check_stalled_word_with_busy_start \
            [lindex $NIST_CIPHERTEXT 0] \
            F \
            0 \
            8 \
            4 \
            "Output-stall busy START word 1"

        aes_test::check_output_word \
            [lindex $NIST_CIPHERTEXT 1] \
            F \
            0 \
            "Output-stall busy START word 2"

        aes_test::check_output_word \
            [lindex $NIST_CIPHERTEXT 2] \
            F \
            0 \
            "Output-stall busy START word 3"

        aes_test::check_output_word \
            [lindex $NIST_CIPHERTEXT 3] \
            F \
            1 \
            "Output-stall busy START word 4"
    }
}

aes_test::check_transaction_complete


# =============================================================================
# CASE 5 — REPEATED START PULSES DURING ONE TRANSACTION
# =============================================================================

echo ""
echo "CASE 5: Repeated START pulses during one active transaction"

aes_test::apply_reset 3 2

aes_test::configure \
    $NIST_KEY \
    $NIST_NONCE \
    $NIST_INITIAL_COUNTER

force -freeze ${TOP}/m_axis_tready 0

if {[aes_test::start_transaction]} {
    aes_test::send_input_word \
        [lindex $NIST_PLAINTEXT 0] \
        F \
        0

    pulse_start_repeatedly_while_busy \
        3 \
        1 \
        "Repeated collection-phase START"

    aes_test::send_input_word \
        [lindex $NIST_PLAINTEXT 1] \
        F \
        0

    aes_test::send_input_word \
        [lindex $NIST_PLAINTEXT 2] \
        F \
        0

    pulse_start_repeatedly_while_busy \
        2 \
        0 \
        "Repeated late-collection START"

    aes_test::send_input_word \
        [lindex $NIST_PLAINTEXT 3] \
        F \
        1

    pulse_start_repeatedly_while_busy \
        3 \
        1 \
        "Repeated post-collection START"

    aes_test::check_full_block \
        $NIST_CIPHERTEXT \
        1 \
        "Repeated busy START ciphertext"
}

aes_test::check_transaction_complete


# =============================================================================
# CASE 6 — CONFIGURATION CHANGE PLUS BUSY START
# =============================================================================

echo ""
echo "CASE 6: Configuration changes while busy must not affect active transaction"

aes_test::apply_reset 3 2

aes_test::configure \
    $NIST_KEY \
    $NIST_NONCE \
    $NIST_INITIAL_COUNTER

force -freeze ${TOP}/m_axis_tready 0

if {[aes_test::start_transaction]} {
    aes_test::send_input_word \
        [lindex $NIST_PLAINTEXT 0] \
        F \
        0

    # Change all configuration inputs while the transaction is active.
    aes_test::configure \
        $REPLACEMENT_KEY \
        $REPLACEMENT_NONCE \
        $REPLACEMENT_COUNTER

    pulse_start_while_busy \
        "Changed-configuration busy START"

    aes_test::send_input_word \
        [lindex $NIST_PLAINTEXT 1] \
        F \
        0

    aes_test::send_input_word \
        [lindex $NIST_PLAINTEXT 2] \
        F \
        0

    aes_test::send_input_word \
        [lindex $NIST_PLAINTEXT 3] \
        F \
        1

    # The active transaction must still use the original NIST configuration.
    aes_test::check_full_block \
        $NIST_CIPHERTEXT \
        1 \
        "Original transaction after changed-configuration busy START"
}

aes_test::check_transaction_complete


# =============================================================================
# CASE 7 — NEW START AFTER RETURN TO IDLE
# =============================================================================

echo ""
echo "CASE 7: START is accepted normally after DUT returns to idle"

# The replacement configuration from Case 6 remains driven.
force -freeze ${TOP}/m_axis_tready 0

if {[aes_test::start_transaction]} {
    if {[aes_test::send_full_block \
            $ZERO_PLAINTEXT \
            1]} {

        aes_test::check_full_block \
            $ZERO_CIPHERTEXT_COUNTER_0 \
            1 \
            "New idle START with replacement configuration"
    }
}

aes_test::check_transaction_complete


# =============================================================================
# CASE 8 — BUSY START DURING FINAL OUTPUT STALL
# =============================================================================

echo ""
echo "CASE 8: START pulse while final TLAST word is stalled"

aes_test::apply_reset 3 2

aes_test::configure \
    $NIST_KEY \
    $NIST_NONCE \
    $NIST_INITIAL_COUNTER

force -freeze ${TOP}/m_axis_tready 0

if {[aes_test::start_transaction]} {
    if {[aes_test::send_full_block \
            $NIST_PLAINTEXT \
            1]} {

        aes_test::check_output_word \
            [lindex $NIST_CIPHERTEXT 0] \
            F \
            0 \
            "Final-stall setup word 1"

        aes_test::check_output_word \
            [lindex $NIST_CIPHERTEXT 1] \
            F \
            0 \
            "Final-stall setup word 2"

        aes_test::check_output_word \
            [lindex $NIST_CIPHERTEXT 2] \
            F \
            0 \
            "Final-stall setup word 3"

        check_stalled_word_with_busy_start \
            [lindex $NIST_CIPHERTEXT 3] \
            F \
            1 \
            10 \
            5 \
            "Final TLAST stall busy START"
    }
}

aes_test::check_transaction_complete


# =============================================================================
# Final result
# =============================================================================

set TEST_PASSED [aes_test::finish]

catch {wave zoom full}

if {!$TEST_PASSED} {
    error "test_06_busy_start.do failed"
}