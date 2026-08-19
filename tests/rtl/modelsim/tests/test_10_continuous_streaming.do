# =============================================================================
# TEST 10 — AES-CTR Continuous Streaming Verification
# =============================================================================
#
# Scope:
#   - back-to-back input words with TVALID held continuously high
#   - input words remain stable until accepted
#   - input and output operate concurrently
#   - immediate delivery of the next word whenever TREADY permits
#   - consecutive full blocks within one transaction
#   - continuous output readiness
#   - deterministic output backpressure during streaming
#   - output stability throughout backpressure
#   - immediate continuation after backpressure is removed
#   - deterministic input gaps during an otherwise continuous transaction
#   - long four-block transactions
#   - partial final blocks following full blocks
#   - repeated transactions without reset
#   - exact ciphertext ordering
#   - correct counter progression
#   - correct TKEEP and TLAST
#   - no lost, duplicated, reordered or extra words
#   - clean return to idle
#
# The DUT processes one collected 128-bit block before accepting the next
# block. The source and sink are therefore driven concurrently so output from
# one block can be consumed while the source waits for the next TREADY window.
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
# Safe failure-reporting override
# =============================================================================
#
# This avoids the unsupported [now] command present in the earlier version of
# aes_test::fail. The common library should also be corrected permanently.
# =============================================================================

proc aes_test::fail {message} {
    variable failures

    incr failures

    echo ""
    echo "FAIL"
    echo "  Test: $message"

    return 0
}


# =============================================================================
# NIST SP 800-38A AES-CTR vectors
# =============================================================================

set NIST_KEY \
    2B7E151628AED2A6ABF7158809CF4F3C

set NIST_NONCE \
    F0F1F2F3F4F5F6F7F8F9FAFB

set NIST_INITIAL_COUNTER \
    FCFDFEFF

set NIST_PLAINTEXT_WORDS {
    6BC1BEE2
    2E409F96
    E93D7E11
    7393172A

    AE2D8A57
    1E03AC9C
    9EB76FAC
    45AF8E51

    30C81C46
    A35CE411
    E5FBC119
    1A0A52EF

    F69F2445
    DF4F9B17
    AD2B417B
    E66C3710
}

set NIST_CIPHERTEXT_WORDS {
    874D6191
    B620E326
    1BEF6864
    990DB6CE

    9806F66B
    7970FDFF
    8617187B
    B9FFFDFF

    5AE4DF3E
    DBD5D35E
    5B4F0902
    0DB03EAB

    1E031DDA
    2FBE03D1
    792170A0
    F3009CEE
}


# =============================================================================
# Test-specific helper procedures
# =============================================================================

proc list_contains {value values} {
    return [expr {[lsearch -exact $values $value] >= 0}]
}


proc run_stream_transaction {
    plaintext_words
    expected_words
    final_keep
    output_stall_indices
    output_stall_cycles
    input_gap_indices
    input_gap_cycles
    description
} {
    set TOP $::aes_test::TOP
    set result 1

    set input_count [llength $plaintext_words]
    set output_count [llength $expected_words]

    if {$input_count == 0} {
        aes_test::fail "$description: no input words supplied"
        return 0
    }

    if {$input_count != $output_count} {
        aes_test::fail \
            "$description: input and expected-output word counts differ"
        return 0
    }

    if {$final_keep ni {1 3 7 F}} {
        aes_test::fail \
            "$description: unsupported final TKEEP $final_keep"
        return 0
    }

    aes_test::configure \
        $::NIST_KEY \
        $::NIST_NONCE \
        $::NIST_INITIAL_COUNTER

    force -freeze ${TOP}/m_axis_tready 0

    if {![aes_test::start_transaction]} {
        return 0
    }

    set input_index 0
    set output_index 0

    set input_gap_remaining 0
    set output_stall_remaining 0
    set completed_output_stalls {}

    set cycle_count 0
    set maximum_cycles 6000

    while {
        $input_index < $input_count ||
        $output_index < $output_count
    } {
        incr cycle_count

        if {$cycle_count > $maximum_cycles} {
            aes_test::fail \
                "$description: transaction timeout after $maximum_cycles cycles"

            set result 0
            break
        }


        # =====================================================================
        # Drive the current input word
        # =====================================================================

        set input_active 0

        if {
            $input_index < $input_count &&
            $input_gap_remaining == 0
        } {
            set input_active 1

            set input_data \
                [lindex $plaintext_words $input_index]

            set input_last \
                [expr {$input_index == ($input_count - 1)}]

            if {$input_last} {
                set input_keep $final_keep
            } else {
                set input_keep F
            }

            force -freeze ${TOP}/s_axis_tvalid 1
            force -freeze ${TOP}/s_axis_tdata 16#$input_data
            force -freeze ${TOP}/s_axis_tkeep 16#$input_keep
            force -freeze ${TOP}/s_axis_tlast $input_last

            if {![aes_test::check_bit \
                    ${TOP}/s_axis_tvalid \
                    1 \
                    "$description input word [expr {$input_index + 1}] TVALID"]} {
                set result 0
            }

            if {![aes_test::check_hex \
                    ${TOP}/s_axis_tdata \
                    $input_data \
                    8 \
                    "$description input word [expr {$input_index + 1}] TDATA"]} {
                set result 0
            }

            if {![aes_test::check_hex \
                    ${TOP}/s_axis_tkeep \
                    $input_keep \
                    1 \
                    "$description input word [expr {$input_index + 1}] TKEEP"]} {
                set result 0
            }

            if {![aes_test::check_bit \
                    ${TOP}/s_axis_tlast \
                    $input_last \
                    "$description input word [expr {$input_index + 1}] TLAST"]} {
                set result 0
            }
        } else {
            force -freeze ${TOP}/s_axis_tvalid 0
            force -freeze ${TOP}/s_axis_tdata 16#00000000
            force -freeze ${TOP}/s_axis_tkeep 16#0
            force -freeze ${TOP}/s_axis_tlast 0
        }


        # =====================================================================
        # Determine whether a scheduled output stall begins
        # =====================================================================

        set current_output_valid \
            [aes_test::read_bit ${TOP}/m_axis_tvalid]

        if {
            $output_stall_remaining == 0 &&
            $current_output_valid == 1 &&
            $output_index < $output_count &&
            [list_contains $output_index $output_stall_indices] &&
            ![list_contains $output_index $completed_output_stalls]
        } {
            set output_stall_remaining $output_stall_cycles

            lappend completed_output_stalls $output_index
        }


        # =====================================================================
        # Drive output readiness
        # =====================================================================

        if {$output_stall_remaining > 0} {
            set output_ready 0
        } else {
            set output_ready 1
        }

        force -freeze ${TOP}/m_axis_tready $output_ready


        # =====================================================================
        # Check the current output whenever TVALID is asserted
        # =====================================================================

        set current_output_valid \
            [aes_test::read_bit ${TOP}/m_axis_tvalid]

        if {$current_output_valid == 1} {
            if {$output_index >= $output_count} {
                aes_test::fail \
                    "$description: unexpected extra output word"

                set result 0
            } else {
                set expected_data \
                    [lindex $expected_words $output_index]

                set expected_last \
                    [expr {$output_index == ($output_count - 1)}]

                if {$expected_last} {
                    set expected_keep $final_keep
                } else {
                    set expected_keep F
                }

                if {![aes_test::check_hex \
                        ${TOP}/m_axis_tdata \
                        $expected_data \
                        8 \
                        "$description output word [expr {$output_index + 1}] TDATA"]} {
                    set result 0
                }

                if {![aes_test::check_hex \
                        ${TOP}/m_axis_tkeep \
                        $expected_keep \
                        1 \
                        "$description output word [expr {$output_index + 1}] TKEEP"]} {
                    set result 0
                }

                if {![aes_test::check_bit \
                        ${TOP}/m_axis_tlast \
                        $expected_last \
                        "$description output word [expr {$output_index + 1}] TLAST"]} {
                    set result 0
                }

                if {$output_stall_remaining > 0} {
                    if {![aes_test::check_bit \
                            ${TOP}/m_axis_tready \
                            0 \
                            "$description output word [expr {$output_index + 1}] stalled TREADY"]} {
                        set result 0
                    }
                }
            }
        }


        # =====================================================================
        # Determine handshakes at the next rising edge
        # =====================================================================

        set input_ready \
            [aes_test::read_bit ${TOP}/s_axis_tready]

        set input_handshake \
            [expr {$input_active && $input_ready == 1}]

        set output_handshake \
            [expr {$current_output_valid == 1 && $output_ready == 1}]


        # =====================================================================
        # Advance one clock cycle
        # =====================================================================

        aes_test::run_cycles 1


        # =====================================================================
        # Update input progress
        # =====================================================================

        if {$input_gap_remaining > 0} {
            incr input_gap_remaining -1
        }

        if {$input_handshake} {
            set accepted_input_index $input_index
            incr input_index

            if {
                [list_contains \
                    $accepted_input_index \
                    $input_gap_indices]
            } {
                set input_gap_remaining $input_gap_cycles
            }
        }


        # =====================================================================
        # Update output progress
        # =====================================================================

        if {$output_stall_remaining > 0} {
            incr output_stall_remaining -1
        }

        if {$output_handshake} {
            incr output_index
        }
    }


    # =========================================================================
    # Return stream controls to safe values
    # =========================================================================

    force -freeze ${TOP}/s_axis_tvalid 0
    force -freeze ${TOP}/s_axis_tdata 16#00000000
    force -freeze ${TOP}/s_axis_tkeep 16#0
    force -freeze ${TOP}/s_axis_tlast 0
    force -freeze ${TOP}/m_axis_tready 0

    if {$input_index != $input_count} {
        aes_test::fail \
            "$description: not all input words were accepted"

        set result 0
    }

    if {$output_index != $output_count} {
        aes_test::fail \
            "$description: not all expected output words were accepted"

        set result 0
    }

    if {![aes_test::check_transaction_complete]} {
        set result 0
    }

    return $result
}


# =============================================================================
# Test initialization
# =============================================================================

aes_test::begin "AES-CTR continuous streaming behavior"
aes_test::initialize_simulation
aes_test::add_basic_waves

set TOP $::aes_test::TOP


# =============================================================================
# CASE 1 — SINGLE FULL BLOCK, CONTINUOUS SOURCE AND SINK
# =============================================================================

echo ""
echo "CASE 1: Single full block with continuous source and sink"

aes_test::apply_reset 3 2

run_stream_transaction \
    [lrange $NIST_PLAINTEXT_WORDS 0 3] \
    [lrange $NIST_CIPHERTEXT_WORDS 0 3] \
    F \
    {} \
    0 \
    {} \
    0 \
    "Single-block continuous transaction"


# =============================================================================
# CASE 2 — FOUR FULL BLOCKS, CONTINUOUS SOURCE AND SINK
# =============================================================================

echo ""
echo "CASE 2: Four full blocks at maximum permitted streaming rate"

aes_test::apply_reset 3 2

run_stream_transaction \
    $NIST_PLAINTEXT_WORDS \
    $NIST_CIPHERTEXT_WORDS \
    F \
    {} \
    0 \
    {} \
    0 \
    "Four-block continuous transaction"


# =============================================================================
# CASE 3 — FOUR BLOCKS WITH PERIODIC OUTPUT BACKPRESSURE
# =============================================================================

echo ""
echo "CASE 3: Four-block transaction with periodic output stalls"

aes_test::apply_reset 3 2

run_stream_transaction \
    $NIST_PLAINTEXT_WORDS \
    $NIST_CIPHERTEXT_WORDS \
    F \
    {0 5 10 15} \
    4 \
    {} \
    0 \
    "Four-block transaction with output stalls"


# =============================================================================
# CASE 4 — INPUT GAPS DURING MULTI-BLOCK TRANSACTION
# =============================================================================

echo ""
echo "CASE 4: Multi-block transaction with deterministic input gaps"

aes_test::apply_reset 3 2

run_stream_transaction \
    [lrange $NIST_PLAINTEXT_WORDS 0 11] \
    [lrange $NIST_CIPHERTEXT_WORDS 0 11] \
    F \
    {} \
    0 \
    {1 4 8} \
    3 \
    "Three-block transaction with input gaps"


# =============================================================================
# CASE 5 — INPUT GAPS AND OUTPUT STALLS TOGETHER
# =============================================================================

echo ""
echo "CASE 5: Concurrent input gaps and output backpressure"

aes_test::apply_reset 3 2

run_stream_transaction \
    $NIST_PLAINTEXT_WORDS \
    $NIST_CIPHERTEXT_WORDS \
    F \
    {2 7 11 15} \
    5 \
    {0 6 12} \
    2 \
    "Four-block mixed streaming transaction"


# =============================================================================
# CASE 6 — FULL BLOCKS FOLLOWED BY ONE-WORD PARTIAL BLOCK
# =============================================================================

echo ""
echo "CASE 6: Three full blocks followed by one-word partial block"

aes_test::apply_reset 3 2

run_stream_transaction \
    [lrange $NIST_PLAINTEXT_WORDS 0 12] \
    [lrange $NIST_CIPHERTEXT_WORDS 0 12] \
    1 \
    {} \
    0 \
    {} \
    0 \
    "Three full blocks plus one-word partial block"


# =============================================================================
# CASE 7 — FULL BLOCKS FOLLOWED BY THREE-WORD PARTIAL BLOCK
# =============================================================================

echo ""
echo "CASE 7: Three full blocks followed by three-word partial block"

aes_test::apply_reset 3 2

run_stream_transaction \
    [lrange $NIST_PLAINTEXT_WORDS 0 14] \
    [lrange $NIST_CIPHERTEXT_WORDS 0 14] \
    7 \
    {3 8 14} \
    3 \
    {} \
    0 \
    "Three full blocks plus three-word partial block"


# =============================================================================
# CASE 8 — REPEATED CONTINUOUS TRANSACTIONS WITHOUT RESET
# =============================================================================

echo ""
echo "CASE 8: Repeated continuous transactions without reset"

aes_test::apply_reset 3 2

for {set transaction 1} {$transaction <= 5} {incr transaction} {
    run_stream_transaction \
        [lrange $NIST_PLAINTEXT_WORDS 0 7] \
        [lrange $NIST_CIPHERTEXT_WORDS 0 7] \
        F \
        {} \
        0 \
        {} \
        0 \
        "Repeated continuous transaction $transaction"
}


# =============================================================================
# CASE 9 — ALTERNATING CONTINUOUS AND STALLED TRANSACTIONS
# =============================================================================

echo ""
echo "CASE 9: Alternating continuous and backpressured transactions"

aes_test::apply_reset 3 2

for {set transaction 1} {$transaction <= 6} {incr transaction} {
    if {[expr {$transaction % 2}] == 1} {
        run_stream_transaction \
            [lrange $NIST_PLAINTEXT_WORDS 0 7] \
            [lrange $NIST_CIPHERTEXT_WORDS 0 7] \
            F \
            {} \
            0 \
            {} \
            0 \
            "Alternating continuous transaction $transaction"
    } else {
        run_stream_transaction \
            [lrange $NIST_PLAINTEXT_WORDS 0 7] \
            [lrange $NIST_CIPHERTEXT_WORDS 0 7] \
            F \
            {1 4 7} \
            4 \
            {2 5} \
            2 \
            "Alternating stalled transaction $transaction"
    }
}


# =============================================================================
# CASE 10 — FINAL TLAST WORD UNDER BACKPRESSURE
# =============================================================================

echo ""
echo "CASE 10: Final TLAST word stalled before acceptance"

aes_test::apply_reset 3 2

run_stream_transaction \
    [lrange $NIST_PLAINTEXT_WORDS 0 3] \
    [lrange $NIST_CIPHERTEXT_WORDS 0 3] \
    F \
    {3} \
    8 \
    {} \
    0 \
    "Final-TLAST backpressure transaction"


# =============================================================================
# Final result
# =============================================================================

set TEST_PASSED [aes_test::finish]

catch {wave zoom full}

if {!$TEST_PASSED} {
    error "test_10_continuous_streaming.do failed"
}