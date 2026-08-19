# =============================================================================
# TEST 07 — AES-CTR Counter Management Verification
# =============================================================================
#
# Scope:
#   - initial counter loading on transaction START
#   - correct counter value for the first 128-bit block
#   - counter increments by exactly one between blocks
#   - one counter value is used for all four words of a block
#   - changed initial counter between transactions
#   - initial counter reload on every new transaction
#   - no continuation from a previous transaction
#   - 32-bit counter rollover:
#       FFFFFFFE -> FFFFFFFF -> 00000000
#   - correct ciphertext for every tested counter value
#   - correct TKEEP and TLAST
#   - correct busy and idle behavior
#   - no missing, duplicated or extra output beats
#
# Zero plaintext is used with a zero AES key and zero nonce. Therefore, each
# ciphertext block is exactly AES-128 encryption of:
#
#   000000000000000000000000 || counter32
#
# The expected values were generated independently from AES-128 ECB.
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
# Test configuration
# =============================================================================

set ZERO_KEY \
    00000000000000000000000000000000

set ZERO_NONCE \
    000000000000000000000000

set ZERO_PLAINTEXT_BLOCK {
    00000000
    00000000
    00000000
    00000000
}


# =============================================================================
# Independently generated AES counter-block ciphertext values
# =============================================================================

set COUNTER_00000000_CIPHERTEXT {
    66E94BD4
    EF8A2C3B
    884CFA59
    CA342B2E
}

set COUNTER_00000001_CIPHERTEXT {
    58E2FCCE
    FA7E3061
    367F1D57
    A4E7455A
}

set COUNTER_00000002_CIPHERTEXT {
    0388DACE
    60B6A392
    F328C2B9
    71B2FE78
}

set COUNTER_00000003_CIPHERTEXT {
    F795AAAB
    494B5923
    F7FD89FF
    948BC1E0
}

set COUNTER_00000004_CIPHERTEXT {
    20021121
    4E7394DA
    2089B6AC
    D093ABE0
}

set COUNTER_00000005_CIPHERTEXT {
    C94DA219
    118E297D
    7B7EBCBC
    C9C388F2
}

set COUNTER_00000007_CIPHERTEXT {
    95B84D1B
    96C690FF
    2F2DE30B
    F2EC89E0
}

set COUNTER_FFFFFFFE_CIPHERTEXT {
    2BDCF387
    424732CB
    EF019D2B
    C2C03743
}

set COUNTER_FFFFFFFF_CIPHERTEXT {
    28C16380
    C491088C
    A019F8A7
    6853B1E8
}


# =============================================================================
# Test-specific helper procedures
# =============================================================================

proc process_counter_block {
    expected_ciphertext
    final_block
    description
} {
    set TOP $::aes_test::TOP
    set result 1

    if {![aes_test::send_full_block \
            $::ZERO_PLAINTEXT_BLOCK \
            $final_block]} {
        return 0
    }

    if {![aes_test::check_full_block \
            $expected_ciphertext \
            $final_block \
            $description]} {
        set result 0
    }

    if {!$final_block} {
        if {![aes_test::check_bit \
                ${TOP}/aes_ctr_idle \
                0 \
                "$description DUT remains busy after non-final block"]} {
            set result 0
        }
    }

    return $result
}


proc run_single_counter_transaction {
    initial_counter
    expected_ciphertext
    description
} {
    set TOP $::aes_test::TOP
    set result 1

    aes_test::configure \
        $::ZERO_KEY \
        $::ZERO_NONCE \
        $initial_counter

    force -freeze ${TOP}/m_axis_tready 0

    if {![aes_test::start_transaction]} {
        return 0
    }

    if {![process_counter_block \
            $expected_ciphertext \
            1 \
            $description]} {
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

aes_test::begin "AES-CTR counter management behavior"
aes_test::initialize_simulation
aes_test::add_basic_waves

set TOP $::aes_test::TOP

catch {
    add wave -divider "Internal counter datapath"
    add wave -radix hexadecimal ${TOP}/counter_block_out
}


# =============================================================================
# CASE 1 — INITIAL COUNTER ZERO AND SEQUENTIAL INCREMENT
# =============================================================================

echo ""
echo "CASE 1: Initial counter 00000000 and four-block progression"

aes_test::apply_reset 3 2

aes_test::configure \
    $ZERO_KEY \
    $ZERO_NONCE \
    00000000

force -freeze ${TOP}/m_axis_tready 0

if {[aes_test::start_transaction]} {
    process_counter_block \
        $COUNTER_00000000_CIPHERTEXT \
        0 \
        "Counter 00000000 block"

    process_counter_block \
        $COUNTER_00000001_CIPHERTEXT \
        0 \
        "Counter 00000001 block"

    process_counter_block \
        $COUNTER_00000002_CIPHERTEXT \
        0 \
        "Counter 00000002 block"

    process_counter_block \
        $COUNTER_00000003_CIPHERTEXT \
        1 \
        "Counter 00000003 block"
}

aes_test::check_transaction_complete


# =============================================================================
# CASE 2 — NONZERO INITIAL COUNTER
# =============================================================================

echo ""
echo "CASE 2: Nonzero initial counter 00000004"

aes_test::apply_reset 3 2

aes_test::configure \
    $ZERO_KEY \
    $ZERO_NONCE \
    00000004

force -freeze ${TOP}/m_axis_tready 0

if {[aes_test::start_transaction]} {
    process_counter_block \
        $COUNTER_00000004_CIPHERTEXT \
        0 \
        "Initial counter 00000004 block"

    process_counter_block \
        $COUNTER_00000005_CIPHERTEXT \
        1 \
        "Incremented counter 00000005 block"
}

aes_test::check_transaction_complete


# =============================================================================
# CASE 3 — INITIAL COUNTER RELOAD ON REPEATED TRANSACTIONS
# =============================================================================

echo ""
echo "CASE 3: Reload counter 00000002 on every new transaction"

aes_test::apply_reset 3 2

for {set transaction 1} {$transaction <= 3} {incr transaction} {
    run_single_counter_transaction \
        00000002 \
        $COUNTER_00000002_CIPHERTEXT \
        "Repeated transaction $transaction, counter 00000002"
}


# =============================================================================
# CASE 4 — CHANGED INITIAL COUNTER BETWEEN TRANSACTIONS
# =============================================================================

echo ""
echo "CASE 4: Changed initial counter between transactions"

aes_test::apply_reset 3 2

run_single_counter_transaction \
    00000000 \
    $COUNTER_00000000_CIPHERTEXT \
    "Transaction using initial counter 00000000"

run_single_counter_transaction \
    00000007 \
    $COUNTER_00000007_CIPHERTEXT \
    "Transaction using changed initial counter 00000007"

run_single_counter_transaction \
    00000001 \
    $COUNTER_00000001_CIPHERTEXT \
    "Transaction using changed initial counter 00000001"


# =============================================================================
# CASE 5 — PREVIOUS WORKING COUNTER MUST NOT CONTINUE
# =============================================================================

echo ""
echo "CASE 5: New transaction must not continue previous working counter"

aes_test::apply_reset 3 2

aes_test::configure \
    $ZERO_KEY \
    $ZERO_NONCE \
    00000000

force -freeze ${TOP}/m_axis_tready 0

if {[aes_test::start_transaction]} {
    process_counter_block \
        $COUNTER_00000000_CIPHERTEXT \
        0 \
        "First transaction counter 00000000"

    process_counter_block \
        $COUNTER_00000001_CIPHERTEXT \
        0 \
        "First transaction counter 00000001"

    process_counter_block \
        $COUNTER_00000002_CIPHERTEXT \
        1 \
        "First transaction counter 00000002"
}

aes_test::check_transaction_complete

# Start a new transaction using the same configured initial counter.
# The first block must return to counter 00000000 rather than continue at 3.

force -freeze ${TOP}/m_axis_tready 0

if {[aes_test::start_transaction]} {
    process_counter_block \
        $COUNTER_00000000_CIPHERTEXT \
        1 \
        "Second transaction reloaded counter 00000000"
}

aes_test::check_transaction_complete


# =============================================================================
# CASE 6 — 32-BIT COUNTER ROLLOVER
# =============================================================================

echo ""
echo "CASE 6: Counter rollover FFFFFFFE -> FFFFFFFF -> 00000000"

aes_test::apply_reset 3 2

aes_test::configure \
    $ZERO_KEY \
    $ZERO_NONCE \
    FFFFFFFE

force -freeze ${TOP}/m_axis_tready 0

if {[aes_test::start_transaction]} {
    process_counter_block \
        $COUNTER_FFFFFFFE_CIPHERTEXT \
        0 \
        "Counter FFFFFFFE block"

    process_counter_block \
        $COUNTER_FFFFFFFF_CIPHERTEXT \
        0 \
        "Counter FFFFFFFF block"

    process_counter_block \
        $COUNTER_00000000_CIPHERTEXT \
        1 \
        "Counter 00000000 after rollover"
}

aes_test::check_transaction_complete


# =============================================================================
# CASE 7 — ROLLOVER TRANSACTION RELOAD
# =============================================================================

echo ""
echo "CASE 7: New transaction after rollover reloads FFFFFFFE"

force -freeze ${TOP}/m_axis_tready 0

if {[aes_test::start_transaction]} {
    process_counter_block \
        $COUNTER_FFFFFFFE_CIPHERTEXT \
        1 \
        "Reloaded counter FFFFFFFE after rollover transaction"
}

aes_test::check_transaction_complete


# =============================================================================
# CASE 8 — ONE COUNTER VALUE PER COMPLETE BLOCK
# =============================================================================

echo ""
echo "CASE 8: All four output words use one counter block"

aes_test::apply_reset 3 2

run_single_counter_transaction \
    00000003 \
    $COUNTER_00000003_CIPHERTEXT \
    "Single block using counter 00000003"

run_single_counter_transaction \
    FFFFFFFF \
    $COUNTER_FFFFFFFF_CIPHERTEXT \
    "Single block using counter FFFFFFFF"


# =============================================================================
# Final result
# =============================================================================

set TEST_PASSED [aes_test::finish]

catch {wave zoom full}

if {!$TEST_PASSED} {
    error "test_07_counter.do failed"
}