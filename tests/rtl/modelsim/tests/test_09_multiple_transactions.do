# =============================================================================
# TEST 09 — AES-CTR Multiple-Transaction Isolation Verification
# =============================================================================
#
# Scope:
#   - repeated transactions without reset
#   - repeated transactions using identical configuration
#   - key change between transactions
#   - nonce change between transactions
#   - initial-counter change between transactions
#   - simultaneous key, nonce and counter change
#   - full and partial packets in consecutive transactions
#   - different packet lengths in consecutive transactions
#   - configuration is loaded by the next accepted START
#   - no stale plaintext, ciphertext, TKEEP or TLAST
#   - no stale working counter between transactions
#   - each transaction returns independently to idle
#   - no missing, duplicated or extra output beats
#
# All transactions are executed without resetting the DUT between them unless
# explicitly stated. This verifies transaction-to-transaction isolation rather
# than reset-based recovery.
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
# Common plaintext blocks
# =============================================================================

set PLAINTEXT_BLOCK_1 {
    6BC1BEE2
    2E409F96
    E93D7E11
    7393172A
}

set PLAINTEXT_BLOCK_2 {
    AE2D8A57
    1E03AC9C
    9EB76FAC
    45AF8E51
}


# =============================================================================
# Configuration A — NIST SP 800-38A AES-CTR vector
# =============================================================================

set CONFIG_A_KEY \
    2B7E151628AED2A6ABF7158809CF4F3C

set CONFIG_A_NONCE \
    F0F1F2F3F4F5F6F7F8F9FAFB

set CONFIG_A_COUNTER \
    FCFDFEFF

set CONFIG_A_CIPHERTEXT_BLOCK_1 {
    874D6191
    B620E326
    1BEF6864
    990DB6CE
}

set CONFIG_A_CIPHERTEXT_BLOCK_2 {
    9806F66B
    7970FDFF
    8617187B
    B9FFFDFF
}


# =============================================================================
# Configuration B — changed key only
# =============================================================================

set CONFIG_B_KEY \
    00000000000000000000000000000000

set CONFIG_B_NONCE \
    F0F1F2F3F4F5F6F7F8F9FAFB

set CONFIG_B_COUNTER \
    FCFDFEFF

set CONFIG_B_CIPHERTEXT_BLOCK_1 {
    8A7797DC
    8FDCD169
    D4AF9C2A
    1151550C
}


# =============================================================================
# Configuration C — changed nonce only
# =============================================================================

set CONFIG_C_KEY \
    2B7E151628AED2A6ABF7158809CF4F3C

set CONFIG_C_NONCE \
    000000000000000000000000

set CONFIG_C_COUNTER \
    FCFDFEFF

set CONFIG_C_CIPHERTEXT_BLOCK_1 {
    73741CC3
    C64E866E
    F5EF7E9E
    7F617FB7
}


# =============================================================================
# Configuration D — changed key, nonce and initial counter
# =============================================================================

set CONFIG_D_KEY \
    00112233445566778899AABBCCDDEEFF

set CONFIG_D_NONCE \
    112233445566778899AABBCC

set CONFIG_D_COUNTER \
    01020304

set CONFIG_D_CIPHERTEXT_BLOCK_1 {
    88B026E5
    B8E88490
    A7C43DD6
    5517D56F
}

set CONFIG_D_CIPHERTEXT_BLOCK_2 {
    6D29081F
    79EF5987
    7D32B1D2
    A7AE097A
}


# =============================================================================
# Configuration E — zero key, zero nonce, counter zero
# =============================================================================

set CONFIG_E_KEY \
    00000000000000000000000000000000

set CONFIG_E_NONCE \
    000000000000000000000000

set CONFIG_E_COUNTER \
    00000000

set CONFIG_E_CIPHERTEXT_BLOCK_1 {
    0D28F536
    C1CAB3AD
    61718448
    B9A73C04
}


# =============================================================================
# Test-specific helper procedures
# =============================================================================

proc run_full_transaction {
    key
    nonce
    counter
    plaintext_blocks
    ciphertext_blocks
    description
} {
    set TOP $::aes_test::TOP
    set result 1

    set block_count [llength $plaintext_blocks]

    if {$block_count == 0} {
        aes_test::fail "$description: transaction contains no blocks"
        return 0
    }

    if {$block_count != [llength $ciphertext_blocks]} {
        aes_test::fail \
            "$description: plaintext and ciphertext block counts differ"
        return 0
    }

    aes_test::configure \
        $key \
        $nonce \
        $counter

    force -freeze ${TOP}/m_axis_tready 0

    if {![aes_test::start_transaction]} {
        return 0
    }

    for {set block_index 0} {
        $block_index < $block_count
    } {
        incr block_index
    } {
        set final_block \
            [expr {$block_index == ($block_count - 1)}]

        set plaintext_block \
            [lindex $plaintext_blocks $block_index]

        set ciphertext_block \
            [lindex $ciphertext_blocks $block_index]

        if {![aes_test::send_full_block \
                $plaintext_block \
                $final_block]} {
            set result 0
            break
        }

        if {![aes_test::check_full_block \
                $ciphertext_block \
                $final_block \
                "$description block [expr {$block_index + 1}]"]} {
            set result 0
        }
    }

    if {![aes_test::check_transaction_complete]} {
        set result 0
    }

    return $result
}


proc run_partial_transaction {
    key
    nonce
    counter
    plaintext_words
    expected_words
    final_keep
    description
} {
    set TOP $::aes_test::TOP
    set result 1

    set word_count [llength $plaintext_words]

    if {$word_count < 1 || $word_count > 4} {
        aes_test::fail \
            "$description: partial transaction word count must be 1 to 4"
        return 0
    }

    if {$word_count != [llength $expected_words]} {
        aes_test::fail \
            "$description: plaintext and expected word counts differ"
        return 0
    }

    aes_test::configure \
        $key \
        $nonce \
        $counter

    force -freeze ${TOP}/m_axis_tready 0

    if {![aes_test::start_transaction]} {
        return 0
    }

    for {set word_index 0} {
        $word_index < $word_count
    } {
        incr word_index
    } {
        set final_word \
            [expr {$word_index == ($word_count - 1)}]

        if {$final_word} {
            set input_keep $final_keep
        } else {
            set input_keep F
        }

        if {![aes_test::send_input_word \
                [lindex $plaintext_words $word_index] \
                $input_keep \
                $final_word]} {
            set result 0
            break
        }
    }

    for {set word_index 0} {
        $word_index < $word_count
    } {
        incr word_index
    } {
        set final_word \
            [expr {$word_index == ($word_count - 1)}]

        if {$final_word} {
            set expected_keep $final_keep
        } else {
            set expected_keep F
        }

        if {![aes_test::check_output_word \
                [lindex $expected_words $word_index] \
                $expected_keep \
                $final_word \
                "$description word [expr {$word_index + 1}]"]} {
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

aes_test::begin "AES-CTR multiple transaction isolation behavior"
aes_test::initialize_simulation
aes_test::add_basic_waves

set TOP $::aes_test::TOP

aes_test::apply_reset 3 2


# =============================================================================
# CASE 1 — REPEATED IDENTICAL TRANSACTIONS
# =============================================================================

echo ""
echo "CASE 1: Repeated identical transactions without reset"

for {set transaction 1} {$transaction <= 3} {incr transaction} {
    run_full_transaction \
        $CONFIG_A_KEY \
        $CONFIG_A_NONCE \
        $CONFIG_A_COUNTER \
        [list $PLAINTEXT_BLOCK_1] \
        [list $CONFIG_A_CIPHERTEXT_BLOCK_1] \
        "Repeated Configuration A transaction $transaction"
}


# =============================================================================
# CASE 2 — KEY CHANGE BETWEEN TRANSACTIONS
# =============================================================================

echo ""
echo "CASE 2: Key change between consecutive transactions"

run_full_transaction \
    $CONFIG_A_KEY \
    $CONFIG_A_NONCE \
    $CONFIG_A_COUNTER \
    [list $PLAINTEXT_BLOCK_1] \
    [list $CONFIG_A_CIPHERTEXT_BLOCK_1] \
    "Original key transaction"

run_full_transaction \
    $CONFIG_B_KEY \
    $CONFIG_B_NONCE \
    $CONFIG_B_COUNTER \
    [list $PLAINTEXT_BLOCK_1] \
    [list $CONFIG_B_CIPHERTEXT_BLOCK_1] \
    "Changed key transaction"

run_full_transaction \
    $CONFIG_A_KEY \
    $CONFIG_A_NONCE \
    $CONFIG_A_COUNTER \
    [list $PLAINTEXT_BLOCK_1] \
    [list $CONFIG_A_CIPHERTEXT_BLOCK_1] \
    "Restored original key transaction"


# =============================================================================
# CASE 3 — NONCE CHANGE BETWEEN TRANSACTIONS
# =============================================================================

echo ""
echo "CASE 3: Nonce change between consecutive transactions"

run_full_transaction \
    $CONFIG_A_KEY \
    $CONFIG_A_NONCE \
    $CONFIG_A_COUNTER \
    [list $PLAINTEXT_BLOCK_1] \
    [list $CONFIG_A_CIPHERTEXT_BLOCK_1] \
    "Original nonce transaction"

run_full_transaction \
    $CONFIG_C_KEY \
    $CONFIG_C_NONCE \
    $CONFIG_C_COUNTER \
    [list $PLAINTEXT_BLOCK_1] \
    [list $CONFIG_C_CIPHERTEXT_BLOCK_1] \
    "Changed nonce transaction"

run_full_transaction \
    $CONFIG_A_KEY \
    $CONFIG_A_NONCE \
    $CONFIG_A_COUNTER \
    [list $PLAINTEXT_BLOCK_1] \
    [list $CONFIG_A_CIPHERTEXT_BLOCK_1] \
    "Restored original nonce transaction"


# =============================================================================
# CASE 4 — INITIAL COUNTER CHANGE BETWEEN TRANSACTIONS
# =============================================================================

echo ""
echo "CASE 4: Initial-counter change between consecutive transactions"

run_full_transaction \
    $CONFIG_E_KEY \
    $CONFIG_E_NONCE \
    00000000 \
    [list $PLAINTEXT_BLOCK_1] \
    [list $CONFIG_E_CIPHERTEXT_BLOCK_1] \
    "Zero initial-counter transaction"

run_full_transaction \
    $CONFIG_A_KEY \
    $CONFIG_A_NONCE \
    $CONFIG_A_COUNTER \
    [list $PLAINTEXT_BLOCK_1] \
    [list $CONFIG_A_CIPHERTEXT_BLOCK_1] \
    "NIST initial-counter transaction"

run_full_transaction \
    $CONFIG_E_KEY \
    $CONFIG_E_NONCE \
    00000000 \
    [list $PLAINTEXT_BLOCK_1] \
    [list $CONFIG_E_CIPHERTEXT_BLOCK_1] \
    "Restored zero initial-counter transaction"


# =============================================================================
# CASE 5 — ALL CONFIGURATION FIELDS CHANGE
# =============================================================================

echo ""
echo "CASE 5: Key, nonce and counter all change between transactions"

run_full_transaction \
    $CONFIG_A_KEY \
    $CONFIG_A_NONCE \
    $CONFIG_A_COUNTER \
    [list \
        $PLAINTEXT_BLOCK_1 \
        $PLAINTEXT_BLOCK_2] \
    [list \
        $CONFIG_A_CIPHERTEXT_BLOCK_1 \
        $CONFIG_A_CIPHERTEXT_BLOCK_2] \
    "Two-block Configuration A transaction"

run_full_transaction \
    $CONFIG_D_KEY \
    $CONFIG_D_NONCE \
    $CONFIG_D_COUNTER \
    [list \
        $PLAINTEXT_BLOCK_1 \
        $PLAINTEXT_BLOCK_2] \
    [list \
        $CONFIG_D_CIPHERTEXT_BLOCK_1 \
        $CONFIG_D_CIPHERTEXT_BLOCK_2] \
    "Two-block Configuration D transaction"

run_full_transaction \
    $CONFIG_A_KEY \
    $CONFIG_A_NONCE \
    $CONFIG_A_COUNTER \
    [list \
        $PLAINTEXT_BLOCK_1 \
        $PLAINTEXT_BLOCK_2] \
    [list \
        $CONFIG_A_CIPHERTEXT_BLOCK_1 \
        $CONFIG_A_CIPHERTEXT_BLOCK_2] \
    "Restored two-block Configuration A transaction"


# =============================================================================
# CASE 6 — FULL TRANSACTION FOLLOWED BY PARTIAL TRANSACTION
# =============================================================================

echo ""
echo "CASE 6: Full transaction followed by partial transaction"

run_full_transaction \
    $CONFIG_A_KEY \
    $CONFIG_A_NONCE \
    $CONFIG_A_COUNTER \
    [list $PLAINTEXT_BLOCK_1] \
    [list $CONFIG_A_CIPHERTEXT_BLOCK_1] \
    "Full transaction before partial packet"

run_partial_transaction \
    $CONFIG_D_KEY \
    $CONFIG_D_NONCE \
    $CONFIG_D_COUNTER \
    [list \
        [lindex $PLAINTEXT_BLOCK_1 0] \
        [lindex $PLAINTEXT_BLOCK_1 1]] \
    [list \
        [lindex $CONFIG_D_CIPHERTEXT_BLOCK_1 0] \
        [lindex $CONFIG_D_CIPHERTEXT_BLOCK_1 1]] \
    3 \
    "Two-word partial transaction after full packet"


# =============================================================================
# CASE 7 — PARTIAL TRANSACTION FOLLOWED BY FULL TRANSACTION
# =============================================================================

echo ""
echo "CASE 7: Partial transaction followed by full transaction"

run_partial_transaction \
    $CONFIG_A_KEY \
    $CONFIG_A_NONCE \
    $CONFIG_A_COUNTER \
    [list \
        [lindex $PLAINTEXT_BLOCK_1 0]] \
    [list \
        [lindex $CONFIG_A_CIPHERTEXT_BLOCK_1 0]] \
    7 \
    "One-word partial transaction"

run_full_transaction \
    $CONFIG_B_KEY \
    $CONFIG_B_NONCE \
    $CONFIG_B_COUNTER \
    [list $PLAINTEXT_BLOCK_1] \
    [list $CONFIG_B_CIPHERTEXT_BLOCK_1] \
    "Full transaction after one-word partial packet"


# =============================================================================
# CASE 8 — DIFFERENT PACKET LENGTHS IN SUCCESSION
# =============================================================================

echo ""
echo "CASE 8: Different packet lengths in consecutive transactions"

run_partial_transaction \
    $CONFIG_A_KEY \
    $CONFIG_A_NONCE \
    $CONFIG_A_COUNTER \
    [list \
        [lindex $PLAINTEXT_BLOCK_1 0]] \
    [list \
        [lindex $CONFIG_A_CIPHERTEXT_BLOCK_1 0]] \
    1 \
    "Length-one transaction"

run_partial_transaction \
    $CONFIG_C_KEY \
    $CONFIG_C_NONCE \
    $CONFIG_C_COUNTER \
    [list \
        [lindex $PLAINTEXT_BLOCK_1 0] \
        [lindex $PLAINTEXT_BLOCK_1 1] \
        [lindex $PLAINTEXT_BLOCK_1 2]] \
    [list \
        [lindex $CONFIG_C_CIPHERTEXT_BLOCK_1 0] \
        [lindex $CONFIG_C_CIPHERTEXT_BLOCK_1 1] \
        [lindex $CONFIG_C_CIPHERTEXT_BLOCK_1 2]] \
    F \
    "Length-three transaction"

run_full_transaction \
    $CONFIG_D_KEY \
    $CONFIG_D_NONCE \
    $CONFIG_D_COUNTER \
    [list \
        $PLAINTEXT_BLOCK_1 \
        $PLAINTEXT_BLOCK_2] \
    [list \
        $CONFIG_D_CIPHERTEXT_BLOCK_1 \
        $CONFIG_D_CIPHERTEXT_BLOCK_2] \
    "Length-eight-word transaction"

run_partial_transaction \
    $CONFIG_A_KEY \
    $CONFIG_A_NONCE \
    $CONFIG_A_COUNTER \
    [list \
        [lindex $PLAINTEXT_BLOCK_1 0] \
        [lindex $PLAINTEXT_BLOCK_1 1]] \
    [list \
        [lindex $CONFIG_A_CIPHERTEXT_BLOCK_1 0] \
        [lindex $CONFIG_A_CIPHERTEXT_BLOCK_1 1]] \
    7 \
    "Length-two transaction"


# =============================================================================
# CASE 9 — CONFIGURATION CHANGE BEFORE NEXT START
# =============================================================================

echo ""
echo "CASE 9: New configuration is loaded by the next accepted START"

run_full_transaction \
    $CONFIG_A_KEY \
    $CONFIG_A_NONCE \
    $CONFIG_A_COUNTER \
    [list $PLAINTEXT_BLOCK_1] \
    [list $CONFIG_A_CIPHERTEXT_BLOCK_1] \
    "Transaction before idle configuration change"

# Change configuration while idle and wait before START.
aes_test::configure \
    $CONFIG_D_KEY \
    $CONFIG_D_NONCE \
    $CONFIG_D_COUNTER

aes_test::run_cycles 6

aes_test::check_bit \
    ${TOP}/aes_ctr_idle \
    1 \
    "DUT remains idle after configuration changes without START"

aes_test::check_bit \
    ${TOP}/s_axis_tready \
    0 \
    "Input TREADY remains low before the next START"

aes_test::check_bit \
    ${TOP}/m_axis_tvalid \
    0 \
    "No output appears before the next START"

force -freeze ${TOP}/m_axis_tready 0

if {[aes_test::start_transaction]} {
    if {[aes_test::send_full_block \
            $PLAINTEXT_BLOCK_1 \
            1]} {

        aes_test::check_full_block \
            $CONFIG_D_CIPHERTEXT_BLOCK_1 \
            1 \
            "Next START loads changed idle configuration"
    }
}

aes_test::check_transaction_complete


# =============================================================================
# CASE 10 — LONG ALTERNATING TRANSACTION SEQUENCE
# =============================================================================

echo ""
echo "CASE 10: Alternating configurations over a long transaction sequence"

for {set sequence_index 1} {
    $sequence_index <= 8
} {
    incr sequence_index
} {
    if {[expr {$sequence_index % 4}] == 1} {
        run_full_transaction \
            $CONFIG_A_KEY \
            $CONFIG_A_NONCE \
            $CONFIG_A_COUNTER \
            [list $PLAINTEXT_BLOCK_1] \
            [list $CONFIG_A_CIPHERTEXT_BLOCK_1] \
            "Alternating sequence $sequence_index, Configuration A"

    } elseif {[expr {$sequence_index % 4}] == 2} {
        run_full_transaction \
            $CONFIG_B_KEY \
            $CONFIG_B_NONCE \
            $CONFIG_B_COUNTER \
            [list $PLAINTEXT_BLOCK_1] \
            [list $CONFIG_B_CIPHERTEXT_BLOCK_1] \
            "Alternating sequence $sequence_index, Configuration B"

    } elseif {[expr {$sequence_index % 4}] == 3} {
        run_full_transaction \
            $CONFIG_C_KEY \
            $CONFIG_C_NONCE \
            $CONFIG_C_COUNTER \
            [list $PLAINTEXT_BLOCK_1] \
            [list $CONFIG_C_CIPHERTEXT_BLOCK_1] \
            "Alternating sequence $sequence_index, Configuration C"

    } else {
        run_full_transaction \
            $CONFIG_D_KEY \
            $CONFIG_D_NONCE \
            $CONFIG_D_COUNTER \
            [list $PLAINTEXT_BLOCK_1] \
            [list $CONFIG_D_CIPHERTEXT_BLOCK_1] \
            "Alternating sequence $sequence_index, Configuration D"
    }
}


# =============================================================================
# Final result
# =============================================================================

set TEST_PASSED [aes_test::finish]

catch {wave zoom full}

if {!$TEST_PASSED} {
    error "test_09_multiple_transactions.do failed"
}