# =============================================================================
# TEST 11 — AES-CTR Deterministic Randomized Stress Verification
# =============================================================================
#
# Scope:
#   - deterministic pseudo-random regression with a fixed reported seed
#   - randomized selection among independently verified configurations
#   - randomized transaction lengths
#   - randomized full and partial final words
#   - valid final TKEEP values:
#       1, 3, 7 and F
#   - randomized input TVALID gaps
#   - randomized output TREADY backpressure
#   - bounded consecutive input gaps and output stalls
#   - concurrent source and sink operation
#   - repeated transactions without reset
#   - exact TDATA scoreboard checking
#   - exact TKEEP and TLAST checking
#   - input stability while TVALID = 1 and TREADY = 0
#   - output stability while TVALID = 1 and TREADY = 0
#   - no lost, duplicated, reordered or extra output words
#   - clean idle return after every transaction
#   - timeout protection with transaction and seed reporting
#
# Important:
#   This test does not calculate AES expected values from the DUT or from a
#   copied RTL implementation. It randomly selects subsets of independently
#   verified known-answer vectors already validated by earlier directed tests.
#
# Reproducibility:
#   Keep RANDOM_SEED unchanged to reproduce an exact run. Change it manually
#   to create an additional deterministic regression sequence.
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
# This prevents an unsupported [now] command in an older aes_test::fail
# implementation from hiding the real failure.
# =============================================================================

proc aes_test::fail {message} {
    variable failures

    incr failures

    echo ""
    echo "FAIL"
    echo "  $message"

    return 0
}


# =============================================================================
# Randomized regression controls
# =============================================================================

set RANDOM_SEED 11062026
set RANDOM_TRANSACTION_COUNT 50
set MAXIMUM_TRANSACTION_CYCLES 8000

# Probability percentages.
set INPUT_GAP_PROBABILITY 30
set OUTPUT_STALL_PROBABILITY 35

# Maximum randomized interruption lengths.
set MAXIMUM_INPUT_GAP_CYCLES 4
set MAXIMUM_OUTPUT_STALL_CYCLES 7

# Prevent an unlucky random sequence from blocking progress indefinitely.
set MAXIMUM_CONSECUTIVE_OUTPUT_STALL_CYCLES 12


# =============================================================================
# Configuration A — NIST SP 800-38A, four verified blocks
# =============================================================================

set CONFIG_A_KEY \
    2B7E151628AED2A6ABF7158809CF4F3C

set CONFIG_A_NONCE \
    F0F1F2F3F4F5F6F7F8F9FAFB

set CONFIG_A_COUNTER \
    FCFDFEFF

set CONFIG_A_PLAINTEXT {
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

set CONFIG_A_CIPHERTEXT {
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
# Configuration B — changed key, one verified block
# =============================================================================

set CONFIG_B_KEY \
    00000000000000000000000000000000

set CONFIG_B_NONCE \
    F0F1F2F3F4F5F6F7F8F9FAFB

set CONFIG_B_COUNTER \
    FCFDFEFF

set CONFIG_B_PLAINTEXT {
    6BC1BEE2
    2E409F96
    E93D7E11
    7393172A
}

set CONFIG_B_CIPHERTEXT {
    8A7797DC
    8FDCD169
    D4AF9C2A
    1151550C
}


# =============================================================================
# Configuration C — changed nonce, one verified block
# =============================================================================

set CONFIG_C_KEY \
    2B7E151628AED2A6ABF7158809CF4F3C

set CONFIG_C_NONCE \
    000000000000000000000000

set CONFIG_C_COUNTER \
    FCFDFEFF

set CONFIG_C_PLAINTEXT {
    6BC1BEE2
    2E409F96
    E93D7E11
    7393172A
}

set CONFIG_C_CIPHERTEXT {
    73741CC3
    C64E866E
    F5EF7E9E
    7F617FB7
}


# =============================================================================
# Configuration D — changed key, nonce and counter, two verified blocks
# =============================================================================

set CONFIG_D_KEY \
    00112233445566778899AABBCCDDEEFF

set CONFIG_D_NONCE \
    112233445566778899AABBCC

set CONFIG_D_COUNTER \
    01020304

set CONFIG_D_PLAINTEXT {
    6BC1BEE2
    2E409F96
    E93D7E11
    7393172A

    AE2D8A57
    1E03AC9C
    9EB76FAC
    45AF8E51
}

set CONFIG_D_CIPHERTEXT {
    88B026E5
    B8E88490
    A7C43DD6
    5517D56F

    6D29081F
    79EF5987
    7D32B1D2
    A7AE097A
}


# =============================================================================
# Configuration E — zero key, zero nonce and counter, one verified block
# =============================================================================

set CONFIG_E_KEY \
    00000000000000000000000000000000

set CONFIG_E_NONCE \
    000000000000000000000000

set CONFIG_E_COUNTER \
    00000000

set CONFIG_E_PLAINTEXT {
    6BC1BEE2
    2E409F96
    E93D7E11
    7393172A
}

set CONFIG_E_CIPHERTEXT {
    0D28F536
    C1CAB3AD
    61718448
    B9A73C04
}


# =============================================================================
# Deterministic random helper procedures
# =============================================================================

proc random_integer {minimum maximum} {
    if {$maximum < $minimum} {
        error "random_integer maximum is less than minimum"
    }

    set range [expr {$maximum - $minimum + 1}]

    return [expr {$minimum + int(rand() * $range)}]
}


proc random_probability {percentage} {
    if {$percentage <= 0} {
        return 0
    }

    if {$percentage >= 100} {
        return 1
    }

    return [expr {[random_integer 1 100] <= $percentage}]
}


proc random_list_element {values} {
    set count [llength $values]

    if {$count == 0} {
        error "random_list_element received an empty list"
    }

    return [lindex $values [random_integer 0 [expr {$count - 1}]]]
}


# =============================================================================
# Dataset selection
# =============================================================================

proc get_dataset {dataset_index} {
    switch -- $dataset_index {
        0 {
            return [list \
                "Configuration A" \
                $::CONFIG_A_KEY \
                $::CONFIG_A_NONCE \
                $::CONFIG_A_COUNTER \
                $::CONFIG_A_PLAINTEXT \
                $::CONFIG_A_CIPHERTEXT]
        }

        1 {
            return [list \
                "Configuration B" \
                $::CONFIG_B_KEY \
                $::CONFIG_B_NONCE \
                $::CONFIG_B_COUNTER \
                $::CONFIG_B_PLAINTEXT \
                $::CONFIG_B_CIPHERTEXT]
        }

        2 {
            return [list \
                "Configuration C" \
                $::CONFIG_C_KEY \
                $::CONFIG_C_NONCE \
                $::CONFIG_C_COUNTER \
                $::CONFIG_C_PLAINTEXT \
                $::CONFIG_C_CIPHERTEXT]
        }

        3 {
            return [list \
                "Configuration D" \
                $::CONFIG_D_KEY \
                $::CONFIG_D_NONCE \
                $::CONFIG_D_COUNTER \
                $::CONFIG_D_PLAINTEXT \
                $::CONFIG_D_CIPHERTEXT]
        }

        4 {
            return [list \
                "Configuration E" \
                $::CONFIG_E_KEY \
                $::CONFIG_E_NONCE \
                $::CONFIG_E_COUNTER \
                $::CONFIG_E_PLAINTEXT \
                $::CONFIG_E_CIPHERTEXT]
        }

        default {
            error "Unknown randomized dataset index $dataset_index"
        }
    }
}


# =============================================================================
# Randomized concurrent transaction driver and scoreboard
# =============================================================================

proc run_randomized_transaction {
    transaction_number
    dataset_name
    key
    nonce
    counter
    plaintext_words
    expected_words
    transaction_word_count
    final_keep
} {
    set TOP $::aes_test::TOP
    set result 1

    set description \
        "Random transaction $transaction_number, $dataset_name"

    set plaintext_words \
        [lrange $plaintext_words 0 [expr {$transaction_word_count - 1}]]

    set expected_words \
        [lrange $expected_words 0 [expr {$transaction_word_count - 1}]]

    aes_test::configure \
        $key \
        $nonce \
        $counter

    # Random idle delay before START.
    set pre_start_delay [random_integer 0 5]

    if {$pre_start_delay > 0} {
        aes_test::run_cycles $pre_start_delay
    }

    force -freeze ${TOP}/m_axis_tready 0

    if {![aes_test::start_transaction]} {
        aes_test::fail \
            "$description: START was not accepted, seed $::RANDOM_SEED"

        return 0
    }

    set input_index 0
    set output_index 0

    set input_gap_remaining 0
    set output_stall_remaining 0
    set consecutive_output_stall_cycles 0

    set held_output_valid 0
    set held_output_data 00000000
    set held_output_keep 0
    set held_output_last 0

    set cycle_count 0

    while {
        $input_index < $transaction_word_count ||
        $output_index < $transaction_word_count
    } {
        incr cycle_count

        if {$cycle_count > $::MAXIMUM_TRANSACTION_CYCLES} {
            aes_test::fail \
                "$description: timeout at input index $input_index, output index $output_index, seed $::RANDOM_SEED"

            set result 0
            break
        }


        # =====================================================================
        # Drive randomized input behavior
        # =====================================================================

        set input_active 0
        set current_input_data 00000000
        set current_input_keep 0
        set current_input_last 0

        if {
            $input_index < $transaction_word_count &&
            $input_gap_remaining == 0
        } {
            set input_active 1

            set current_input_data \
                [lindex $plaintext_words $input_index]

            set current_input_last \
                [expr {$input_index == ($transaction_word_count - 1)}]

            if {$current_input_last} {
                set current_input_keep $final_keep
            } else {
                set current_input_keep F
            }

            force -freeze ${TOP}/s_axis_tvalid 1
            force -freeze ${TOP}/s_axis_tdata 16#$current_input_data
            force -freeze ${TOP}/s_axis_tkeep 16#$current_input_keep
            force -freeze ${TOP}/s_axis_tlast $current_input_last
        } else {
            force -freeze ${TOP}/s_axis_tvalid 0
            force -freeze ${TOP}/s_axis_tdata 16#00000000
            force -freeze ${TOP}/s_axis_tkeep 16#0
            force -freeze ${TOP}/s_axis_tlast 0
        }


        # =====================================================================
        # Create randomized output backpressure
        # =====================================================================

        set current_output_valid \
            [aes_test::read_bit ${TOP}/m_axis_tvalid]

        if {$output_stall_remaining > 0} {
            set output_ready 0
        } elseif {
            $current_output_valid == 1 &&
            $consecutive_output_stall_cycles <
                $::MAXIMUM_CONSECUTIVE_OUTPUT_STALL_CYCLES &&
            [random_probability $::OUTPUT_STALL_PROBABILITY]
        } {
            set output_stall_remaining \
                [random_integer 1 $::MAXIMUM_OUTPUT_STALL_CYCLES]

            set output_ready 0
        } else {
            set output_ready 1
        }

        force -freeze ${TOP}/m_axis_tready $output_ready


        # =====================================================================
        # Verify source stability and current input values
        # =====================================================================

        if {$input_active} {
            if {![aes_test::check_bit \
                    ${TOP}/s_axis_tvalid \
                    1 \
                    "$description input word [expr {$input_index + 1}] TVALID"]} {
                set result 0
            }

            if {![aes_test::check_hex \
                    ${TOP}/s_axis_tdata \
                    $current_input_data \
                    8 \
                    "$description input word [expr {$input_index + 1}] TDATA"]} {
                set result 0
            }

            if {![aes_test::check_hex \
                    ${TOP}/s_axis_tkeep \
                    $current_input_keep \
                    1 \
                    "$description input word [expr {$input_index + 1}] TKEEP"]} {
                set result 0
            }

            if {![aes_test::check_bit \
                    ${TOP}/s_axis_tlast \
                    $current_input_last \
                    "$description input word [expr {$input_index + 1}] TLAST"]} {
                set result 0
            }
        }


        # =====================================================================
        # Scoreboard the current output
        # =====================================================================

        set current_output_valid \
            [aes_test::read_bit ${TOP}/m_axis_tvalid]

        if {$current_output_valid == 1} {
            if {$output_index >= $transaction_word_count} {
                aes_test::fail \
                    "$description: unexpected extra output word, seed $::RANDOM_SEED"

                set result 0
            } else {
                set expected_data \
                    [lindex $expected_words $output_index]

                set expected_last \
                    [expr {$output_index == ($transaction_word_count - 1)}]

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
            }
        }


        # =====================================================================
        # Check output stability during backpressure
        # =====================================================================

        if {
            $current_output_valid == 1 &&
            $output_ready == 0
        } {
            set current_data \
                [aes_test::read_hex ${TOP}/m_axis_tdata 8]

            set current_keep \
                [aes_test::read_hex ${TOP}/m_axis_tkeep 1]

            set current_last \
                [aes_test::read_bit ${TOP}/m_axis_tlast]

            if {$held_output_valid} {
                if {![aes_test::check_hex \
                        ${TOP}/m_axis_tdata \
                        $held_output_data \
                        8 \
                        "$description stalled output TDATA stability"]} {
                    set result 0
                }

                if {![aes_test::check_hex \
                        ${TOP}/m_axis_tkeep \
                        $held_output_keep \
                        1 \
                        "$description stalled output TKEEP stability"]} {
                    set result 0
                }

                if {![aes_test::check_bit \
                        ${TOP}/m_axis_tlast \
                        $held_output_last \
                        "$description stalled output TLAST stability"]} {
                    set result 0
                }
            } else {
                set held_output_valid 1
                set held_output_data $current_data
                set held_output_keep $current_keep
                set held_output_last $current_last
            }
        } else {
            set held_output_valid 0
        }


        # =====================================================================
        # Determine handshakes before advancing the clock
        # =====================================================================

        set input_ready \
            [aes_test::read_bit ${TOP}/s_axis_tready]

        set input_handshake \
            [expr {$input_active && $input_ready == 1}]

        set output_handshake \
            [expr {$current_output_valid == 1 && $output_ready == 1}]


        # =====================================================================
        # Advance one clock
        # =====================================================================

        aes_test::run_cycles 1


        # =====================================================================
        # Update randomized input progress
        # =====================================================================

        if {$input_gap_remaining > 0} {
            incr input_gap_remaining -1
        }

        if {$input_handshake} {
            incr input_index

            if {
                $input_index < $transaction_word_count &&
                [random_probability $::INPUT_GAP_PROBABILITY]
            } {
                set input_gap_remaining \
                    [random_integer 1 $::MAXIMUM_INPUT_GAP_CYCLES]
            }
        }


        # =====================================================================
        # Update randomized output progress
        # =====================================================================

        if {$output_ready == 0 && $current_output_valid == 1} {
            incr consecutive_output_stall_cycles
        } else {
            set consecutive_output_stall_cycles 0
        }

        if {$output_stall_remaining > 0} {
            incr output_stall_remaining -1
        }

        if {$output_handshake} {
            incr output_index
            set held_output_valid 0
            set consecutive_output_stall_cycles 0
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

    if {$input_index != $transaction_word_count} {
        aes_test::fail \
            "$description: accepted $input_index of $transaction_word_count input words, seed $::RANDOM_SEED"

        set result 0
    }

    if {$output_index != $transaction_word_count} {
        aes_test::fail \
            "$description: accepted $output_index of $transaction_word_count output words, seed $::RANDOM_SEED"

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

aes_test::begin "AES-CTR deterministic randomized stress behavior"
aes_test::initialize_simulation
aes_test::add_basic_waves

set TOP $::aes_test::TOP

# Initialize Tcl's pseudo-random generator and discard its returned value.
expr {srand($RANDOM_SEED)}

echo ""
echo "Randomized stress configuration:"
echo "  Seed:                    $RANDOM_SEED"
echo "  Transactions:            $RANDOM_TRANSACTION_COUNT"
echo "  Input gap probability:   $INPUT_GAP_PROBABILITY percent"
echo "  Output stall probability:$OUTPUT_STALL_PROBABILITY percent"
echo ""

aes_test::apply_reset 3 2


# =============================================================================
# Directed randomized-parameter coverage
# =============================================================================
#
# These first cases guarantee every dataset and every supported final TKEEP
# appears at least once before the fully randomized loop.
# =============================================================================

echo ""
echo "PHASE 1: Guaranteed dataset and final-TKEEP coverage"

set GUARANTEED_FINAL_KEEPS {1 3 7 F}

for {set dataset_index 0} {$dataset_index < 5} {incr dataset_index} {
    set dataset [get_dataset $dataset_index]

    set dataset_name \
        [lindex $dataset 0]

    set key \
        [lindex $dataset 1]

    set nonce \
        [lindex $dataset 2]

    set counter \
        [lindex $dataset 3]

    set plaintext_words \
        [lindex $dataset 4]

    set expected_words \
        [lindex $dataset 5]

    set maximum_words \
        [llength $plaintext_words]

    for {set keep_index 0} {
        $keep_index < [llength $GUARANTEED_FINAL_KEEPS]
    } {
        incr keep_index
    } {
        set final_keep \
            [lindex $GUARANTEED_FINAL_KEEPS $keep_index]

        set word_count \
            [expr {1 + (($dataset_index + $keep_index) % $maximum_words)}]

        set guaranteed_transaction_number \
            [expr {($dataset_index * 4) + $keep_index + 1}]

        run_randomized_transaction \
            $guaranteed_transaction_number \
            $dataset_name \
            $key \
            $nonce \
            $counter \
            $plaintext_words \
            $expected_words \
            $word_count \
            $final_keep
    }
}


# =============================================================================
# Fully randomized transaction sequence
# =============================================================================

echo ""
echo "PHASE 2: Fully randomized transaction sequence"

for {set random_transaction 1} {
    $random_transaction <= $RANDOM_TRANSACTION_COUNT
} {
    incr random_transaction
} {
    set dataset_index \
        [random_integer 0 4]

    set dataset \
        [get_dataset $dataset_index]

    set dataset_name \
        [lindex $dataset 0]

    set key \
        [lindex $dataset 1]

    set nonce \
        [lindex $dataset 2]

    set counter \
        [lindex $dataset 3]

    set plaintext_words \
        [lindex $dataset 4]

    set expected_words \
        [lindex $dataset 5]

    set maximum_words \
        [llength $plaintext_words]

    set transaction_word_count \
        [random_integer 1 $maximum_words]

    set final_keep \
        [random_list_element {1 3 7 F}]

    set displayed_transaction_number \
        [expr {20 + $random_transaction}]

    echo ""
    echo "Random transaction $random_transaction of $RANDOM_TRANSACTION_COUNT"
    echo "  Dataset:    $dataset_name"
    echo "  Word count: $transaction_word_count"
    echo "  Final keep: $final_keep"
    echo "  Seed:       $RANDOM_SEED"

    run_randomized_transaction \
        $displayed_transaction_number \
        $dataset_name \
        $key \
        $nonce \
        $counter \
        $plaintext_words \
        $expected_words \
        $transaction_word_count \
        $final_keep
}


# =============================================================================
# Final deterministic recovery transaction
# =============================================================================
#
# This confirms the DUT still operates correctly after the full randomized
# sequence and that no hidden transaction state remains.
# =============================================================================

echo ""
echo "PHASE 3: Final deterministic recovery transaction"

run_randomized_transaction \
    999 \
    "Final NIST recovery" \
    $CONFIG_A_KEY \
    $CONFIG_A_NONCE \
    $CONFIG_A_COUNTER \
    $CONFIG_A_PLAINTEXT \
    $CONFIG_A_CIPHERTEXT \
    16 \
    F


# =============================================================================
# Final result
# =============================================================================

echo ""
echo "Randomized seed used: $RANDOM_SEED"

set TEST_PASSED [aes_test::finish]

catch {wave zoom full}

if {!$TEST_PASSED} {
    error \
        "test_11_randomized_stress.do failed with seed $RANDOM_SEED"
}
