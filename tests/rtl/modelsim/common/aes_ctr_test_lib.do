# =============================================================================
# AES-CTR ModelSim Regression Common Library
# =============================================================================
#
# Shared procedures used by the AES-CTR regression tests.
#
# DUT:
#   sim:/aes_ctr_block_128
#
# Clock:
#   10 ns period
#
# Reset:
#   active-low and synchronous
#
# This file defines reusable procedures. It does not run a test by itself.
# =============================================================================


# =============================================================================
# Global test state
# =============================================================================

namespace eval aes_test {
    variable TOP "sim:/aes_ctr_block_128"

    variable CLOCK_PERIOD_NS 10
    variable HALF_PERIOD_NS 5

    variable current_test ""
    variable checks 0
    variable failures 0
}


# =============================================================================
# Value conversion helpers
# =============================================================================

proc aes_test::normalize_bit {value} {
    set value [string trim $value]
    set value [string toupper $value]

    set value [string map {
        "\"" ""
        "'"  ""
        " "  ""
        "2#" ""
        "0B" ""
    } $value]

    if {[string first "#" $value] >= 0} {
        set fields [split $value "#"]
        set value [lindex $fields end]
    }

    if {[string length $value] > 1} {
        set value [string index $value end]
    }

    return $value
}


proc aes_test::normalize_hex {value width} {
    set value [string trim $value]
    set value [string toupper $value]

    set value [string map {
        "\"" ""
        "'"  ""
        "_"  ""
        " "  ""
        "16#" ""
        "0X"  ""
    } $value]

    if {[string first "#" $value] >= 0} {
        set fields [split $value "#"]
        set value [lindex $fields end]
    }

    if {![regexp {[UXZWLH-]} $value]} {
        while {[string length $value] < $width} {
            set value "0$value"
        }
    }

    return $value
}


proc aes_test::read_bit {signal} {
    return [normalize_bit \
        [examine -radix binary $signal]]
}


proc aes_test::read_hex {signal width} {
    return [normalize_hex \
        [examine -radix hexadecimal $signal] \
        $width]
}


# =============================================================================
# Reporting and checks
# =============================================================================

proc aes_test::begin {test_name} {
    variable current_test
    variable checks
    variable failures

    set current_test $test_name
    set checks 0
    set failures 0

    echo ""
    echo "======================================================================"
    echo "TEST: $current_test"
    echo "======================================================================"
}


proc aes_test::fail {message} {
    variable current_test
    variable failures

    incr failures

    echo ""
    echo "FAIL"
    echo "  Test: $current_test"
    echo "  Time: [now]"
    echo "  $message"
}


proc aes_test::check_bit {signal expected description} {
    variable checks

    incr checks

    set observed [read_bit $signal]
    set expected [normalize_bit $expected]

    if {$observed ne $expected} {
        fail $description
        echo "  Signal:   $signal"
        echo "  Expected: $expected"
        echo "  Observed: $observed"
        return 0
    }

    echo "PASS: $description"
    return 1
}


proc aes_test::check_hex {signal expected width description} {
    variable checks

    incr checks

    set observed [read_hex $signal $width]
    set expected [normalize_hex $expected $width]

    if {$observed ne $expected} {
        fail $description
        echo "  Signal:   $signal"
        echo "  Expected: $expected"
        echo "  Observed: $observed"
        return 0
    }

    echo "PASS: $description"
    return 1
}


proc aes_test::finish {} {
    variable current_test
    variable checks
    variable failures

    echo ""
    echo "======================================================================"
    echo "TEST SUMMARY"
    echo "======================================================================"
    echo "Test:     $current_test"
    echo "Checks:   $checks"
    echo "Failures: $failures"
    echo "======================================================================"

    if {$failures == 0} {
        echo ""
        echo "TEST PASSED: $current_test"
        echo ""
        return 1
    }

    echo ""
    echo "TEST FAILED: $current_test"
    echo ""

    return 0
}


# =============================================================================
# Simulation timing and timeout helpers
# =============================================================================

proc aes_test::run_cycles {count} {
    variable CLOCK_PERIOD_NS

    for {set cycle 0} {$cycle < $count} {incr cycle} {
        run ${CLOCK_PERIOD_NS}ns
    }
}


proc aes_test::wait_for_bit {
    signal
    expected
    maximum_cycles
    description
} {
    set expected [normalize_bit $expected]

    for {set cycle 0} {$cycle < $maximum_cycles} {incr cycle} {
        set observed [read_bit $signal]

        if {$observed eq $expected} {
            return 1
        }

        run_cycles 1
    }

    fail "Timeout waiting for $description"
    echo "  Signal:         $signal"
    echo "  Expected:       $expected"
    echo "  Observed:       [read_bit $signal]"
    echo "  Timeout cycles: $maximum_cycles"

    return 0
}


# =============================================================================
# DUT initialization and basic driving
# =============================================================================

proc aes_test::start_clock {} {
    variable TOP
    variable CLOCK_PERIOD_NS
    variable HALF_PERIOD_NS

    force -freeze \
        ${TOP}/clk \
        0 0ns, 1 ${HALF_PERIOD_NS}ns \
        -repeat ${CLOCK_PERIOD_NS}ns
}


proc aes_test::drive_safe_inputs {} {
    variable TOP

    force -freeze ${TOP}/reset_n 1
    force -freeze ${TOP}/aes_ctr_start 0

    force -freeze \
        ${TOP}/key_in \
        16#00000000000000000000000000000000

    force -freeze \
        ${TOP}/nonce_in \
        16#000000000000000000000000

    force -freeze \
        ${TOP}/initial_counter_in \
        16#00000000

    force -freeze ${TOP}/s_axis_tdata 16#00000000
    force -freeze ${TOP}/s_axis_tkeep 16#0
    force -freeze ${TOP}/s_axis_tvalid 0
    force -freeze ${TOP}/s_axis_tlast 0

    force -freeze ${TOP}/m_axis_tready 1
}


proc aes_test::initialize_simulation {} {
    restart -f

    start_clock
    drive_safe_inputs

    run 1ns
}


proc aes_test::assert_reset {{cycles 3}} {
    variable TOP

    force -freeze ${TOP}/aes_ctr_start 0

    force -freeze ${TOP}/s_axis_tvalid 0
    force -freeze ${TOP}/s_axis_tlast 0
    force -freeze ${TOP}/s_axis_tkeep 16#0
    force -freeze ${TOP}/s_axis_tdata 16#00000000

    force -freeze ${TOP}/m_axis_tready 1

    force -freeze ${TOP}/reset_n 0

    run_cycles $cycles
}


proc aes_test::release_reset {{settle_cycles 2}} {
    variable TOP

    force -freeze ${TOP}/reset_n 1

    run_cycles $settle_cycles
}


proc aes_test::apply_reset {
    {asserted_cycles 3}
    {release_cycles 2}
} {
    assert_reset $asserted_cycles
    release_reset $release_cycles
}


proc aes_test::configure {
    key
    nonce
    initial_counter
} {
    variable TOP

    force -freeze ${TOP}/key_in 16#$key
    force -freeze ${TOP}/nonce_in 16#$nonce
    force -freeze ${TOP}/initial_counter_in 16#$initial_counter
}


proc aes_test::pulse_start {} {
    variable TOP

    force -freeze ${TOP}/aes_ctr_start 1
    run_cycles 1
    force -freeze ${TOP}/aes_ctr_start 0
}


# =============================================================================
# Waveform helpers
# =============================================================================

proc aes_test::add_basic_waves {} {
    variable TOP

    catch {delete wave *}
    quietly WaveActivateNextPane {} 0

    add wave -divider "Clock and reset"
    add wave ${TOP}/clk
    add wave ${TOP}/reset_n

    add wave -divider "Control"
    add wave ${TOP}/aes_ctr_start
    add wave ${TOP}/aes_ctr_idle

    add wave -divider "Configuration"
    add wave -radix hexadecimal ${TOP}/key_in
    add wave -radix hexadecimal ${TOP}/nonce_in
    add wave -radix hexadecimal ${TOP}/initial_counter_in

    add wave -divider "Input AXI-Stream"
    add wave -radix hexadecimal ${TOP}/s_axis_tdata
    add wave -radix hexadecimal ${TOP}/s_axis_tkeep
    add wave ${TOP}/s_axis_tvalid
    add wave ${TOP}/s_axis_tready
    add wave ${TOP}/s_axis_tlast

    add wave -divider "Output AXI-Stream"
    add wave -radix hexadecimal ${TOP}/m_axis_tdata
    add wave -radix hexadecimal ${TOP}/m_axis_tkeep
    add wave ${TOP}/m_axis_tvalid
    add wave ${TOP}/m_axis_tready
    add wave ${TOP}/m_axis_tlast
}


# =============================================================================
# Transaction and AXI-Stream helpers
# =============================================================================

proc aes_test::start_transaction {} {
    variable TOP

    if {![wait_for_bit \
            ${TOP}/aes_ctr_idle \
            1 \
            50 \
            "DUT to become idle before START"]} {
        return 0
    }

    force -freeze ${TOP}/aes_ctr_start 1
    run_cycles 1
    force -freeze ${TOP}/aes_ctr_start 0

    if {![wait_for_bit \
            ${TOP}/aes_ctr_idle \
            0 \
            20 \
            "DUT to leave idle after START"]} {
        return 0
    }

    return 1
}


proc aes_test::send_input_word {
    data
    keep
    last
} {
    variable TOP

    # This helper waits for TREADY before asserting TVALID.
    # TVALID-before-TREADY behavior is tested separately.
    if {![wait_for_bit \
            ${TOP}/s_axis_tready \
            1 \
            200 \
            "input TREADY before sending word"]} {
        return 0
    }

    force -freeze ${TOP}/s_axis_tdata 16#$data
    force -freeze ${TOP}/s_axis_tkeep 16#$keep
    force -freeze ${TOP}/s_axis_tlast $last
    force -freeze ${TOP}/s_axis_tvalid 1

    # Hold the input signals across one rising clock edge.
    run_cycles 1

    force -freeze ${TOP}/s_axis_tvalid 0
    force -freeze ${TOP}/s_axis_tlast 0
    force -freeze ${TOP}/s_axis_tkeep 16#0
    force -freeze ${TOP}/s_axis_tdata 16#00000000

    return 1
}


proc aes_test::send_full_block {
    words
    final_block
} {
    if {[llength $words] != 4} {
        fail "send_full_block requires exactly four 32-bit words"
        return 0
    }

    for {set index 0} {$index < 4} {incr index} {
        set last 0

        if {$final_block && $index == 3} {
            set last 1
        }

        if {![send_input_word \
                [lindex $words $index] \
                F \
                $last]} {
            return 0
        }
    }

    return 1
}


proc aes_test::check_output_word {
    expected_data
    expected_keep
    expected_last
    description
} {
    variable TOP

    # Stall the output until the expected beat becomes visible.
    force -freeze ${TOP}/m_axis_tready 0

    if {![wait_for_bit \
            ${TOP}/m_axis_tvalid \
            1 \
            300 \
            "$description output TVALID"]} {
        return 0
    }

    set data_ok [check_hex \
        ${TOP}/m_axis_tdata \
        $expected_data \
        8 \
        "$description TDATA"]

    set keep_ok [check_hex \
        ${TOP}/m_axis_tkeep \
        $expected_keep \
        1 \
        "$description TKEEP"]

    set last_ok [check_bit \
        ${TOP}/m_axis_tlast \
        $expected_last \
        "$description TLAST"]

    # Accept exactly one output beat.
    force -freeze ${TOP}/m_axis_tready 1
    run_cycles 1
    force -freeze ${TOP}/m_axis_tready 0

    if {!$data_ok || !$keep_ok || !$last_ok} {
        return 0
    }

    return 1
}


proc aes_test::check_full_block {
    expected_words
    final_block
    description
} {
    if {[llength $expected_words] != 4} {
        fail "check_full_block requires exactly four expected words"
        return 0
    }

    set result 1

    for {set index 0} {$index < 4} {incr index} {
        set last 0

        if {$final_block && $index == 3} {
            set last 1
        }

        if {![check_output_word \
                [lindex $expected_words $index] \
                F \
                $last \
                "$description word [expr {$index + 1}]"]} {
            set result 0
        }
    }

    return $result
}


proc aes_test::check_transaction_complete {} {
    variable TOP

    force -freeze ${TOP}/m_axis_tready 0

    if {![wait_for_bit \
            ${TOP}/aes_ctr_idle \
            1 \
            100 \
            "DUT to return to idle after final output"]} {
        return 0
    }

    set result 1

    if {![check_bit \
            ${TOP}/m_axis_tvalid \
            0 \
            "Output TVALID is low after transaction completion"]} {
        set result 0
    }

    if {![check_bit \
            ${TOP}/s_axis_tready \
            0 \
            "Input TREADY is low after transaction completion"]} {
        set result 0
    }

    # Observe additional cycles to detect delayed or extra output beats.
    for {set cycle 1} {$cycle <= 5} {incr cycle} {
        run_cycles 1

        if {![check_bit \
                ${TOP}/m_axis_tvalid \
                0 \
                "No extra output beat appears after completion, cycle $cycle"]} {
            set result 0
        }

        if {![check_bit \
                ${TOP}/m_axis_tlast \
                0 \
                "No extra output TLAST appears after completion, cycle $cycle"]} {
            set result 0
        }

        if {![check_bit \
                ${TOP}/aes_ctr_idle \
                1 \
                "DUT remains idle after completion, cycle $cycle"]} {
            set result 0
        }
    }

    force -freeze ${TOP}/m_axis_tready 1

    return $result
}
