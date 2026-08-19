# =============================================================================
# TEST 02 — AES-CTR NIST Known-Answer Vectors
# =============================================================================
#
# Scope:
#   - one-block NIST SP 800-38A AES-CTR known-answer test
#   - four-block NIST SP 800-38A AES-CTR known-answer test
#   - correct 32-bit input and output word ordering
#   - correct ciphertext for each block
#   - correct output TKEEP
#   - correct output TLAST placement
#   - correct multi-block counter progression, verified through ciphertext
#   - correct return to idle after the final output
#   - absence of extra output beats after transaction completion
#
# Run after HDL Designer has loaded aes_ctr_block_128:
#
#   do C:/FPGA_Tools/HDLDesigner/zybo_aes_hdl/zybo_aes_hdl/
#      zybo_aes_hdl_lib/sim/tests/test_02_nist_vectors.do
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
# NIST SP 800-38A AES-CTR vectors
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

set PLAINTEXT_BLOCK_2 {
    AE2D8A57
    1E03AC9C
    9EB76FAC
    45AF8E51
}

set PLAINTEXT_BLOCK_3 {
    30C81C46
    A35CE411
    E5FBC119
    1A0A52EF
}

set PLAINTEXT_BLOCK_4 {
    F69F2445
    DF4F9B17
    AD2B417B
    E66C3710
}


set CIPHERTEXT_BLOCK_1 {
    874D6191
    B620E326
    1BEF6864
    990DB6CE
}

set CIPHERTEXT_BLOCK_2 {
    9806F66B
    7970FDFF
    8617187B
    B9FFFDFF
}

set CIPHERTEXT_BLOCK_3 {
    5AE4DF3E
    DBD5D35E
    5B4F0902
    0DB03EAB
}

set CIPHERTEXT_BLOCK_4 {
    1E031DDA
    2FBE03D1
    792170A0
    F3009CEE
}


# =============================================================================
# Test initialization
# =============================================================================

aes_test::begin "NIST AES-CTR known-answer vectors"
aes_test::initialize_simulation
aes_test::add_basic_waves

set TOP $::aes_test::TOP


# Add relevant internal top-level signals when they are visible.
catch {
    add wave -divider "Internal AES-CTR datapath"
    add wave -radix hexadecimal ${TOP}/counter_block_out
    add wave -radix hexadecimal ${TOP}/keystream
    add wave -radix hexadecimal ${TOP}/block_out
    add wave -radix hexadecimal ${TOP}/ciphertext_block
}


# =============================================================================
# CASE 1 — ONE-BLOCK NIST KNOWN-ANSWER TEST
# =============================================================================

echo ""
echo "CASE 1: One-block NIST AES-CTR known-answer test"

aes_test::apply_reset 3 2

aes_test::configure \
    $NIST_KEY \
    $NIST_NONCE \
    $NIST_INITIAL_COUNTER

force -freeze ${TOP}/m_axis_tready 0

if {[aes_test::start_transaction]} {
    aes_test::check_bit \
        ${TOP}/aes_ctr_idle \
        0 \
        "DUT is busy after the one-block transaction starts"

    if {[aes_test::send_full_block \
            $PLAINTEXT_BLOCK_1 \
            1]} {
        aes_test::check_full_block \
            $CIPHERTEXT_BLOCK_1 \
            1 \
            "One-block NIST ciphertext"
    }
}

aes_test::check_transaction_complete


# =============================================================================
# CASE 2 — FOUR-BLOCK NIST KNOWN-ANSWER TEST
# =============================================================================

echo ""
echo "CASE 2: Four-block NIST AES-CTR known-answer test"

aes_test::apply_reset 3 2

aes_test::configure \
    $NIST_KEY \
    $NIST_NONCE \
    $NIST_INITIAL_COUNTER

force -freeze ${TOP}/m_axis_tready 0

if {[aes_test::start_transaction]} {
    aes_test::check_bit \
        ${TOP}/aes_ctr_idle \
        0 \
        "DUT is busy after the four-block transaction starts"

    # -------------------------------------------------------------------------
    # Block 1
    # Counter block:
    # F0F1F2F3F4F5F6F7F8F9FAFBFCFDFEFF
    # -------------------------------------------------------------------------

    echo ""
    echo "Processing NIST block 1"

    if {[aes_test::send_full_block \
            $PLAINTEXT_BLOCK_1 \
            0]} {
        aes_test::check_full_block \
            $CIPHERTEXT_BLOCK_1 \
            0 \
            "Four-block NIST block 1"
    }

    aes_test::check_bit \
        ${TOP}/aes_ctr_idle \
        0 \
        "DUT remains busy after non-final block 1"

    # -------------------------------------------------------------------------
    # Block 2
    # Counter block:
    # F0F1F2F3F4F5F6F7F8F9FAFBFCFDFF00
    # -------------------------------------------------------------------------

    echo ""
    echo "Processing NIST block 2"

    if {[aes_test::send_full_block \
            $PLAINTEXT_BLOCK_2 \
            0]} {
        aes_test::check_full_block \
            $CIPHERTEXT_BLOCK_2 \
            0 \
            "Four-block NIST block 2"
    }

    aes_test::check_bit \
        ${TOP}/aes_ctr_idle \
        0 \
        "DUT remains busy after non-final block 2"

    # -------------------------------------------------------------------------
    # Block 3
    # Counter block:
    # F0F1F2F3F4F5F6F7F8F9FAFBFCFDFF01
    # -------------------------------------------------------------------------

    echo ""
    echo "Processing NIST block 3"

    if {[aes_test::send_full_block \
            $PLAINTEXT_BLOCK_3 \
            0]} {
        aes_test::check_full_block \
            $CIPHERTEXT_BLOCK_3 \
            0 \
            "Four-block NIST block 3"
    }

    aes_test::check_bit \
        ${TOP}/aes_ctr_idle \
        0 \
        "DUT remains busy after non-final block 3"

    # -------------------------------------------------------------------------
    # Block 4, final block
    # Counter block:
    # F0F1F2F3F4F5F6F7F8F9FAFBFCFDFF02
    # -------------------------------------------------------------------------

    echo ""
    echo "Processing NIST block 4"

    if {[aes_test::send_full_block \
            $PLAINTEXT_BLOCK_4 \
            1]} {
        aes_test::check_full_block \
            $CIPHERTEXT_BLOCK_4 \
            1 \
            "Four-block NIST block 4"
    }
}

aes_test::check_transaction_complete


# =============================================================================
# CASE 3 — REPEATABILITY AFTER RESET
# =============================================================================

echo ""
echo "CASE 3: Repeat one-block vector after reset"

aes_test::apply_reset 3 2

aes_test::configure \
    $NIST_KEY \
    $NIST_NONCE \
    $NIST_INITIAL_COUNTER

force -freeze ${TOP}/m_axis_tready 0

if {[aes_test::start_transaction]} {
    if {[aes_test::send_full_block \
            $PLAINTEXT_BLOCK_1 \
            1]} {
        aes_test::check_full_block \
            $CIPHERTEXT_BLOCK_1 \
            1 \
            "Repeated one-block NIST ciphertext"
    }
}

aes_test::check_transaction_complete


# =============================================================================
# Final result
# =============================================================================

set TEST_PASSED [aes_test::finish]

catch {wave zoom full}

if {!$TEST_PASSED} {
    error "test_02_nist_vectors.do failed"
}
