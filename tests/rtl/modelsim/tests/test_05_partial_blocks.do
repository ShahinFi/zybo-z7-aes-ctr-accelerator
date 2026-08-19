# =============================================================================
# TEST 05 — AES-CTR Partial Final Block Verification
# =============================================================================
#
# Scope:
#   - TLAST accepted on input word positions 1, 2, 3 and 4
#   - contiguous final-word TKEEP values:
#       0001, 0011, 0111 and 1111
#   - exact TKEEP propagation from input to output
#   - correct TLAST placement on the final output word
#   - non-final output words always use TKEEP = 1111
#   - correct ciphertext data for all partial packet lengths
#   - one-block partial transactions
#   - multi-block transactions ending in a partial final block
#   - correct counter progression into the partial second block
#   - correct return to idle after every partial transaction
#   - no missing, duplicated or extra output words
#
# The valid final TKEEP patterns tested here are the contiguous byte masks
# normally produced by a 32-bit AXI DMA stream:
#
#   0001 = 1 valid byte
#   0011 = 2 valid bytes
#   0111 = 3 valid bytes
#   1111 = 4 valid bytes
#
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


set PLAINTEXT_BLOCK_1 {
    6BC1BEE2
    2E409F96
    E93D7E11
    7393172A
}

set CIPHERTEXT_BLOCK_1 {
    874D6191
    B620E326
    1BEF6864
    990DB6CE
}


set PLAINTEXT_BLOCK_2 {
    AE2D8A57
    1E03AC9C
    9EB76FAC
    45AF8E51
}

set CIPHERTEXT_BLOCK_2 {
    9806F66B
    7970FDFF
    8617187B
    B9FFFDFF
}


set VALID_FINAL_KEEPS {
    1
    3
    7
    F
}


# =============================================================================
# Test-specific helper procedures
# =============================================================================

proc run_single_block_partial_case {
    plaintext_words
    ciphertext_words
    final_word_index
    final_keep
    description
} {
    set TOP $::aes_test::TOP

    if {$final_word_index < 0 || $final_word_index > 3} {
        aes_test::fail \
            "$description has invalid final word index $final_word_index"
        return 0
    }

    set result 1

    aes_test::apply_reset 3 2

    aes_test::configure \
        $::NIST_KEY \
        $::NIST_NONCE \
        $::NIST_INITIAL_COUNTER

    force -freeze ${TOP}/m_axis_tready 0

    if {![aes_test::start_transaction]} {
        return 0
    }

    # Send only the words belonging to this partial final block.
    for {set word_index 0} {
        $word_index <= $final_word_index
    } {
        incr word_index
    } {
        set is_final [expr {$word_index == $final_word_index}]
        set input_keep F

        if {$is_final} {
            set input_keep $final_keep
        }

        if {![aes_test::send_input_word \
                [lindex $plaintext_words $word_index] \
                $input_keep \
                $is_final]} {
            set result 0
            break
        }
    }

    # Check that exactly the same number of output words appears.
    for {set word_index 0} {
        $word_index <= $final_word_index
    } {
        incr word_index
    } {
        set is_final [expr {$word_index == $final_word_index}]
        set expected_keep F

        if {$is_final} {
            set expected_keep $final_keep
        }

        if {![aes_test::check_output_word \
                [lindex $ciphertext_words $word_index] \
                $expected_keep \
                $is_final \
                "$description output word [expr {$word_index + 1}]"]} {
            set result 0
        }
    }

    if {![aes_test::check_transaction_complete]} {
        set result 0
    }

    return $result
}


proc run_two_block_partial_case {
    plaintext_block_1
    ciphertext_block_1
    plaintext_block_2
    ciphertext_block_2
    final_word_index
    final_keep
    description
} {
    set TOP $::aes_test::TOP

    if {$final_word_index < 0 || $final_word_index > 3} {
        aes_test::fail \
            "$description has invalid final word index $final_word_index"
        return 0
    }

    set result 1

    aes_test::apply_reset 3 2

    aes_test::configure \
        $::NIST_KEY \
        $::NIST_NONCE \
        $::NIST_INITIAL_COUNTER

    force -freeze ${TOP}/m_axis_tready 0

    if {![aes_test::start_transaction]} {
        return 0
    }

    # First block is complete but is not the final transaction block.
    if {![aes_test::send_full_block \
            $plaintext_block_1 \
            0]} {
        return 0
    }

    if {![aes_test::check_full_block \
            $ciphertext_block_1 \
            0 \
            "$description full block 1"]} {
        set result 0
    }

    if {![aes_test::check_bit \
            ${TOP}/aes_ctr_idle \
            0 \
            "$description DUT remains busy after non-final block 1"]} {
        set result 0
    }

    # Second block ends at the selected word position.
    for {set word_index 0} {
        $word_index <= $final_word_index
    } {
        incr word_index
    } {
        set is_final [expr {$word_index == $final_word_index}]
        set input_keep F

        if {$is_final} {
            set input_keep $final_keep
        }

        if {![aes_test::send_input_word \
                [lindex $plaintext_block_2 $word_index] \
                $input_keep \
                $is_final]} {
            set result 0
            break
        }
    }

    for {set word_index 0} {
        $word_index <= $final_word_index
    } {
        incr word_index
    } {
        set is_final [expr {$word_index == $final_word_index}]
        set expected_keep F

        if {$is_final} {
            set expected_keep $final_keep
        }

        if {![aes_test::check_output_word \
                [lindex $ciphertext_block_2 $word_index] \
                $expected_keep \
                $is_final \
                "$description partial block 2 word [expr {$word_index + 1}]"]} {
            set result 0
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

aes_test::begin "AES-CTR partial final block behavior"
aes_test::initialize_simulation
aes_test::add_basic_waves

set TOP $::aes_test::TOP


# =============================================================================
# CASE 1 — SINGLE-BLOCK PARTIAL TRANSACTIONS
# =============================================================================

echo ""
echo "CASE 1: Exhaustive single-block partial final transactions"

for {set final_word_index 0} {
    $final_word_index < 4
} {
    incr final_word_index
} {
    foreach final_keep $VALID_FINAL_KEEPS {
        echo ""
        echo "Single-block case:"
        echo "  Final word position: [expr {$final_word_index + 1}]"
        echo "  Final TKEEP:         $final_keep"

        run_single_block_partial_case \
            $PLAINTEXT_BLOCK_1 \
            $CIPHERTEXT_BLOCK_1 \
            $final_word_index \
            $final_keep \
            "Single block, TLAST word [expr {$final_word_index + 1}], TKEEP=$final_keep"
    }
}


# =============================================================================
# CASE 2 — TWO-BLOCK TRANSACTIONS WITH PARTIAL FINAL BLOCK
# =============================================================================

echo ""
echo "CASE 2: Two-block transactions ending in a partial second block"

for {set final_word_index 0} {
    $final_word_index < 4
} {
    incr final_word_index
} {
    foreach final_keep $VALID_FINAL_KEEPS {
        echo ""
        echo "Two-block case:"
        echo "  Final word position in block 2: [expr {$final_word_index + 1}]"
        echo "  Final TKEEP:                    $final_keep"

        run_two_block_partial_case \
            $PLAINTEXT_BLOCK_1 \
            $CIPHERTEXT_BLOCK_1 \
            $PLAINTEXT_BLOCK_2 \
            $CIPHERTEXT_BLOCK_2 \
            $final_word_index \
            $final_keep \
            "Two blocks, TLAST block 2 word [expr {$final_word_index + 1}], TKEEP=$final_keep"
    }
}


# =============================================================================
# CASE 3 — FINAL TKEEP MUST NOT AFFECT CIPHERTEXT WORD VALUE
# =============================================================================

echo ""
echo "CASE 3: Same data word with every valid final TKEEP"

foreach final_keep $VALID_FINAL_KEEPS {
    echo ""
    echo "Final word 4 with TKEEP=$final_keep"

    run_single_block_partial_case \
        $PLAINTEXT_BLOCK_1 \
        $CIPHERTEXT_BLOCK_1 \
        3 \
        $final_keep \
        "Full four-word block with final TKEEP=$final_keep"
}


# =============================================================================
# CASE 4 — SHORTEST AND LONGEST PARTIAL PACKETS
# =============================================================================

echo ""
echo "CASE 4: Boundary packet lengths"

run_single_block_partial_case \
    $PLAINTEXT_BLOCK_1 \
    $CIPHERTEXT_BLOCK_1 \
    0 \
    1 \
    "Shortest packet: one word with one valid byte"

run_single_block_partial_case \
    $PLAINTEXT_BLOCK_1 \
    $CIPHERTEXT_BLOCK_1 \
    3 \
    F \
    "Longest single-block packet: four complete words"

run_two_block_partial_case \
    $PLAINTEXT_BLOCK_1 \
    $CIPHERTEXT_BLOCK_1 \
    $PLAINTEXT_BLOCK_2 \
    $CIPHERTEXT_BLOCK_2 \
    0 \
    1 \
    "Full block followed by one-byte partial final word"

run_two_block_partial_case \
    $PLAINTEXT_BLOCK_1 \
    $CIPHERTEXT_BLOCK_1 \
    $PLAINTEXT_BLOCK_2 \
    $CIPHERTEXT_BLOCK_2 \
    3 \
    F \
    "Two complete blocks with TLAST on final word"


# =============================================================================
# Final result
# =============================================================================

set TEST_PASSED [aes_test::finish]

catch {wave zoom full}

if {!$TEST_PASSED} {
    error "test_05_partial_blocks.do failed"
}
