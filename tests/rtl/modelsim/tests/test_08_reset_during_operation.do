# =============================================================================
# TEST 08 — AES-CTR Reset During Operation Verification
# =============================================================================
#
# Scope:
#   - synchronous reset during input collection
#   - synchronous reset after input collection and during AES processing
#   - synchronous reset during normal output serialization
#   - synchronous reset during output backpressure
#   - synchronous reset while the final TLAST word is stalled
#   - interrupted transaction is discarded
#   - pending output TVALID and TLAST are cleared
#   - input TREADY returns low
#   - DUT returns to idle
#   - no delayed output appears after reset release
#   - configuration can be reloaded after reset
#   - a complete known-answer transaction succeeds after every interruption
#
# Reset is active-low and synchronous. Every reset assertion is therefore held
# across active clock edges before reset-state outputs are checked.
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


# =============================================================================
# Test-specific helper procedures
# =============================================================================

proc clear_stream_inputs {} {
    set TOP $::aes_test::TOP

    force -freeze ${TOP}/aes_ctr_start 0
    force -freeze ${TOP}/s_axis_tdata 16#00000000
    force -freeze ${TOP}/s_axis_tkeep 16#0
    force -freeze ${TOP}/s_axis_tvalid 0
    force -freeze ${TOP}/s_axis_tlast 0
}


proc check_reset_state {description} {
    set TOP $::aes_test::TOP
    set result 1

    if {![aes_test::check_bit \
            ${TOP}/aes_ctr_idle \
            1 \
            "$description: DUT is idle"]} {
        set result 0
    }

    if {![aes_test::check_bit \
            ${TOP}/s_axis_tready \
            0 \
            "$description: input TREADY is low"]} {
        set result 0
    }

    if {![aes_test::check_bit \
            ${TOP}/m_axis_tvalid \
            0 \
            "$description: output TVALID is low"]} {
        set result 0
    }

    if {![aes_test::check_bit \
            ${TOP}/m_axis_tlast \
            0 \
            "$description: output TLAST is low"]} {
        set result 0
    }

    return $result
}


proc reset_interrupted_transaction {description} {
    set TOP $::aes_test::TOP
    set result 1

    echo ""
    echo "Applying synchronous reset: $description"

    force -freeze ${TOP}/reset_n 0

    # Cross the first active clock edge with reset asserted.
    aes_test::run_cycles 1

    if {![check_reset_state \
            "$description after first reset edge"]} {
        set result 0
    }

    # Hold reset for additional clock edges and verify stable reset behavior.
    for {set cycle 1} {$cycle <= 2} {incr cycle} {
        aes_test::run_cycles 1

        if {![check_reset_state \
                "$description held-reset cycle $cycle"]} {
            set result 0
        }
    }

    clear_stream_inputs

    # Keep the output blocked during reset release so any erroneous delayed
    # output cannot be consumed unnoticed.
    force -freeze ${TOP}/m_axis_tready 0
    force -freeze ${TOP}/reset_n 1

    aes_test::run_cycles 2

    if {![check_reset_state \
            "$description after reset release"]} {
        set result 0
    }

    # The interrupted transaction must not resume or emit delayed output.
    for {set cycle 1} {$cycle <= 8} {incr cycle} {
        aes_test::run_cycles 1

        if {![aes_test::check_bit \
                ${TOP}/aes_ctr_idle \
                1 \
                "$description: DUT remains idle after release, cycle $cycle"]} {
            set result 0
        }

        if {![aes_test::check_bit \
                ${TOP}/s_axis_tready \
                0 \
                "$description: TREADY remains low after release, cycle $cycle"]} {
            set result 0
        }

        if {![aes_test::check_bit \
                ${TOP}/m_axis_tvalid \
                0 \
                "$description: no delayed output appears, cycle $cycle"]} {
            set result 0
        }

        if {![aes_test::check_bit \
                ${TOP}/m_axis_tlast \
                0 \
                "$description: no delayed TLAST appears, cycle $cycle"]} {
            set result 0
        }
    }

    return $result
}


proc run_recovery_transaction {description} {
    set TOP $::aes_test::TOP
    set result 1

    echo ""
    echo "Running recovery transaction: $description"

    aes_test::configure \
        $::NIST_KEY \
        $::NIST_NONCE \
        $::NIST_INITIAL_COUNTER

    force -freeze ${TOP}/m_axis_tready 0

    if {![aes_test::start_transaction]} {
        return 0
    }

    if {![aes_test::send_full_block \
            $::NIST_PLAINTEXT \
            1]} {
        return 0
    }

    if {![aes_test::check_full_block \
            $::NIST_CIPHERTEXT \
            1 \
            "$description ciphertext"]} {
        set result 0
    }

    if {![aes_test::check_transaction_complete]} {
        set result 0
    }

    return $result
}


proc prepare_transaction {} {
    set TOP $::aes_test::TOP

    aes_test::apply_reset 3 2

    aes_test::configure \
        $::NIST_KEY \
        $::NIST_NONCE \
        $::NIST_INITIAL_COUNTER

    force -freeze ${TOP}/m_axis_tready 0

    return [aes_test::start_transaction]
}


# =============================================================================
# Test initialization
# =============================================================================

aes_test::begin "AES-CTR reset during operation behavior"
aes_test::initialize_simulation
aes_test::add_basic_waves

set TOP $::aes_test::TOP


# =============================================================================
# CASE 1 — RESET DURING INPUT COLLECTION
# =============================================================================

echo ""
echo "CASE 1: Reset during input collection"

if {[prepare_transaction]} {
    aes_test::send_input_word \
        [lindex $NIST_PLAINTEXT 0] \
        F \
        0

    aes_test::send_input_word \
        [lindex $NIST_PLAINTEXT 1] \
        F \
        0

    aes_test::check_bit \
        ${TOP}/aes_ctr_idle \
        0 \
        "Collection-reset case: DUT is busy before reset"

    aes_test::check_bit \
        ${TOP}/s_axis_tready \
        1 \
        "Collection-reset case: collector is ready before reset"

    reset_interrupted_transaction \
        "Reset during input collection"
}

run_recovery_transaction \
    "Recovery after input-collection reset"


# =============================================================================
# CASE 2 — RESET DURING POST-COLLECTION AES PROCESSING
# =============================================================================

echo ""
echo "CASE 2: Reset after collection while AES processing is active"

if {[prepare_transaction]} {
    aes_test::send_full_block \
        $NIST_PLAINTEXT \
        1

    aes_test::check_bit \
        ${TOP}/aes_ctr_idle \
        0 \
        "AES-reset case: DUT remains busy after input collection"

    aes_test::check_bit \
        ${TOP}/m_axis_tvalid \
        0 \
        "AES-reset case: output is not yet valid immediately after collection"

    reset_interrupted_transaction \
        "Reset during post-collection AES processing"
}

run_recovery_transaction \
    "Recovery after AES-processing reset"


# =============================================================================
# CASE 3 — RESET DURING NORMAL OUTPUT SERIALIZATION
# =============================================================================

echo ""
echo "CASE 3: Reset during normal output serialization"

if {[prepare_transaction]} {
    aes_test::send_full_block \
        $NIST_PLAINTEXT \
        1

    force -freeze ${TOP}/m_axis_tready 0

    if {[aes_test::wait_for_bit \
            ${TOP}/m_axis_tvalid \
            1 \
            300 \
            "first output word before serialization reset"]} {

        aes_test::check_hex \
            ${TOP}/m_axis_tdata \
            [lindex $NIST_CIPHERTEXT 0] \
            8 \
            "Serialization-reset case: first output word is correct"

        aes_test::check_bit \
            ${TOP}/m_axis_tlast \
            0 \
            "Serialization-reset case: first output word is not final"

        # Accept the first output word normally.
        force -freeze ${TOP}/m_axis_tready 1
        aes_test::run_cycles 1

        # The serializer has advanced and remains active. Assert reset before
        # the next active clock edge.
        aes_test::check_bit \
            ${TOP}/aes_ctr_idle \
            0 \
            "Serialization-reset case: DUT remains busy after word 1"

        reset_interrupted_transaction \
            "Reset during normal output serialization"
    }
}

run_recovery_transaction \
    "Recovery after normal-serialization reset"


# =============================================================================
# CASE 4 — RESET DURING OUTPUT BACKPRESSURE
# =============================================================================

echo ""
echo "CASE 4: Reset while output word 1 is stalled"

if {[prepare_transaction]} {
    aes_test::send_full_block \
        $NIST_PLAINTEXT \
        1

    force -freeze ${TOP}/m_axis_tready 0

    if {[aes_test::wait_for_bit \
            ${TOP}/m_axis_tvalid \
            1 \
            300 \
            "stalled first output word before reset"]} {

        set held_data [aes_test::read_hex ${TOP}/m_axis_tdata 8]
        set held_keep [aes_test::read_hex ${TOP}/m_axis_tkeep 1]
        set held_last [aes_test::read_bit ${TOP}/m_axis_tlast]

        aes_test::check_hex \
            ${TOP}/m_axis_tdata \
            [lindex $NIST_CIPHERTEXT 0] \
            8 \
            "Backpressure-reset case: stalled word has correct TDATA"

        for {set cycle 1} {$cycle <= 6} {incr cycle} {
            aes_test::run_cycles 1

            aes_test::check_bit \
                ${TOP}/m_axis_tvalid \
                1 \
                "Backpressure-reset case: TVALID remains high, cycle $cycle"

            aes_test::check_hex \
                ${TOP}/m_axis_tdata \
                $held_data \
                8 \
                "Backpressure-reset case: TDATA remains stable, cycle $cycle"

            aes_test::check_hex \
                ${TOP}/m_axis_tkeep \
                $held_keep \
                1 \
                "Backpressure-reset case: TKEEP remains stable, cycle $cycle"

            aes_test::check_bit \
                ${TOP}/m_axis_tlast \
                $held_last \
                "Backpressure-reset case: TLAST remains stable, cycle $cycle"
        }

        reset_interrupted_transaction \
            "Reset during output backpressure"
    }
}

run_recovery_transaction \
    "Recovery after output-backpressure reset"


# =============================================================================
# CASE 5 — RESET WHILE FINAL TLAST WORD IS STALLED
# =============================================================================

echo ""
echo "CASE 5: Reset while final TLAST output word is stalled"

if {[prepare_transaction]} {
    aes_test::send_full_block \
        $NIST_PLAINTEXT \
        1

    aes_test::check_output_word \
        [lindex $NIST_CIPHERTEXT 0] \
        F \
        0 \
        "Final-reset setup word 1"

    aes_test::check_output_word \
        [lindex $NIST_CIPHERTEXT 1] \
        F \
        0 \
        "Final-reset setup word 2"

    aes_test::check_output_word \
        [lindex $NIST_CIPHERTEXT 2] \
        F \
        0 \
        "Final-reset setup word 3"

    force -freeze ${TOP}/m_axis_tready 0

    if {[aes_test::wait_for_bit \
            ${TOP}/m_axis_tvalid \
            1 \
            300 \
            "final TLAST word before reset"]} {

        aes_test::check_hex \
            ${TOP}/m_axis_tdata \
            [lindex $NIST_CIPHERTEXT 3] \
            8 \
            "Final-reset case: final output word is correct"

        aes_test::check_hex \
            ${TOP}/m_axis_tkeep \
            F \
            1 \
            "Final-reset case: final output TKEEP is correct"

        aes_test::check_bit \
            ${TOP}/m_axis_tlast \
            1 \
            "Final-reset case: final output asserts TLAST"

        aes_test::check_bit \
            ${TOP}/aes_ctr_idle \
            0 \
            "Final-reset case: DUT remains busy while TLAST is stalled"

        for {set cycle 1} {$cycle <= 5} {incr cycle} {
            aes_test::run_cycles 1

            aes_test::check_bit \
                ${TOP}/m_axis_tvalid \
                1 \
                "Final-reset case: TVALID remains high, cycle $cycle"

            aes_test::check_hex \
                ${TOP}/m_axis_tdata \
                [lindex $NIST_CIPHERTEXT 3] \
                8 \
                "Final-reset case: TDATA remains stable, cycle $cycle"

            aes_test::check_hex \
                ${TOP}/m_axis_tkeep \
                F \
                1 \
                "Final-reset case: TKEEP remains stable, cycle $cycle"

            aes_test::check_bit \
                ${TOP}/m_axis_tlast \
                1 \
                "Final-reset case: TLAST remains high, cycle $cycle"
        }

        reset_interrupted_transaction \
            "Reset while final TLAST word is stalled"
    }
}

run_recovery_transaction \
    "Recovery after final-TLAST reset"


# =============================================================================
# CASE 6 — REPEATED OPERATIONAL RESET AND RECOVERY
# =============================================================================

echo ""
echo "CASE 6: Repeated reset and recovery cycles"

for {set reset_number 1} {$reset_number <= 3} {incr reset_number} {
    if {[prepare_transaction]} {
        aes_test::send_input_word \
            [lindex $NIST_PLAINTEXT 0] \
            F \
            0

        reset_interrupted_transaction \
            "Repeated operational reset $reset_number"
    }

    run_recovery_transaction \
        "Recovery transaction $reset_number"
}


# =============================================================================
# Final result
# =============================================================================

set TEST_PASSED [aes_test::finish]

catch {wave zoom full}

if {!$TEST_PASSED} {
    error "test_08_reset_during_operation.do failed"
}