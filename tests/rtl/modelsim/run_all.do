# =============================================================================
# AES-CTR COMPLETE REGRESSION RUNNER
# =============================================================================
#
# Runs the complete self-checking AES-CTR RTL regression suite:
#
#   test_01_reset.do
#   test_02_nist_vectors.do
#   test_03_input_handshake.do
#   test_04_output_backpressure.do
#   test_05_partial_blocks.do
#   test_06_busy_start.do
#   test_07_counter.do
#   test_08_reset_during_operation.do
#   test_09_multiple_transactions.do
#   test_10_continuous_streaming.do
#   test_11_randomized_stress.do
#
# Behavior:
#   - uses the current ModelSim directory as the regression directory
#   - loads the DUT from repository VHDL when it is not already loaded
#   - verifies that every required test file exists before starting
#   - runs every test in numerical order
#   - catches individual test errors so later tests can still run
#   - records PASS or FAIL for every test
#   - prints one final regression summary
#   - returns a Tcl error when one or more tests fail
#
# Test 12 is intentionally omitted because malformed-input rejection is not
# part of the current RTL specification.
# =============================================================================


# =============================================================================
# Locate this regression directory
# =============================================================================

set SIM_DIRECTORY [file normalize [pwd]]
set REGRESSION_TEST_DIRECTORY [file normalize [file join $SIM_DIRECTORY tests]]

if {![file isdirectory $REGRESSION_TEST_DIRECTORY]} {
    error "Could not locate the regression test directory: $REGRESSION_TEST_DIRECTORY"
}

# =============================================================================
# Ensure the AES-CTR DUT is loaded
# =============================================================================

set DUT_LOADED 0
if {![catch {examine sim:/aes_ctr_block_128/aes_ctr_idle}]} {
    set DUT_LOADED 1
}

if {!$DUT_LOADED} {
    set loader [file normalize [file join $SIM_DIRECTORY load_design.do]]
    if {![file exists $loader]} {
        error "DUT is not loaded and standalone loader is missing: $loader"
    }
    echo "AES-CTR DUT is not loaded; compiling repository VHDL sources."
    do $loader
}


# =============================================================================
# Regression test list
# =============================================================================

set REGRESSION_TESTS {
    test_01_reset.do
    test_02_nist_vectors.do
    test_03_input_handshake.do
    test_04_output_backpressure.do
    test_05_partial_blocks.do
    test_06_busy_start.do
    test_07_counter.do
    test_08_reset_during_operation.do
    test_09_multiple_transactions.do
    test_10_continuous_streaming.do
    test_11_randomized_stress.do
}


# =============================================================================
# Verify all required files before starting
# =============================================================================

set MISSING_TESTS {}

foreach test_file $REGRESSION_TESTS {
    set test_path [file normalize \
        [file join \
            $REGRESSION_TEST_DIRECTORY \
            $test_file]]

    if {![file exists $test_path]} {
        lappend MISSING_TESTS $test_path
    }
}

if {[llength $MISSING_TESTS] > 0} {
    echo ""
    echo "REGRESSION CANNOT START"
    echo "The following required test files are missing:"

    foreach missing_test $MISSING_TESTS {
        echo "  $missing_test"
    }

    error "One or more regression test files are missing"
}


# =============================================================================
# Regression initialization
# =============================================================================

set REGRESSION_START_TIME [clock seconds]

set PASSED_TESTS {}
set FAILED_TESTS {}
set TEST_RESULTS {}

set TEST_NUMBER 0
set TEST_COUNT [llength $REGRESSION_TESTS]

echo ""
echo "======================================================================"
echo "AES-CTR COMPLETE RTL REGRESSION"
echo "======================================================================"
echo "Simulation directory: $SIM_DIRECTORY"
echo "Test directory:       $REGRESSION_TEST_DIRECTORY"
echo "Number of tests:      $TEST_COUNT"
echo "======================================================================"
echo ""


# =============================================================================
# Run every test
# =============================================================================

foreach test_file $REGRESSION_TESTS {
    incr TEST_NUMBER

    set test_path [file normalize \
        [file join \
            $REGRESSION_TEST_DIRECTORY \
            $test_file]]

    echo ""
    echo "======================================================================"
    echo "RUNNING TEST $TEST_NUMBER OF $TEST_COUNT"
    echo "File: $test_file"
    echo "Path: $test_path"
    echo "======================================================================"
    echo ""

    set TEST_START_TIME [clock seconds]

    set return_code [catch {
        source $test_path
    } return_message return_options]

    set TEST_END_TIME [clock seconds]
    set TEST_DURATION [expr {$TEST_END_TIME - $TEST_START_TIME}]

    if {$return_code == 0} {
        lappend PASSED_TESTS $test_file

        lappend TEST_RESULTS \
            [list \
                $test_file \
                PASS \
                $TEST_DURATION \
                ""]

        echo ""
        echo "----------------------------------------------------------------------"
        echo "REGRESSION RESULT: PASS"
        echo "Test:     $test_file"
        echo "Duration: $TEST_DURATION seconds"
        echo "----------------------------------------------------------------------"
    } else {
        lappend FAILED_TESTS $test_file

        lappend TEST_RESULTS \
            [list \
                $test_file \
                FAIL \
                $TEST_DURATION \
                $return_message]

        echo ""
        echo "----------------------------------------------------------------------"
        echo "REGRESSION RESULT: FAIL"
        echo "Test:     $test_file"
        echo "Duration: $TEST_DURATION seconds"
        echo "Reason:   $return_message"
        echo "----------------------------------------------------------------------"

        if {[dict exists $return_options -errorinfo]} {
            echo ""
            echo "Error information:"
            echo [dict get $return_options -errorinfo]
        }
    }
}


# =============================================================================
# Final regression summary
# =============================================================================

set REGRESSION_END_TIME [clock seconds]
set REGRESSION_DURATION \
    [expr {$REGRESSION_END_TIME - $REGRESSION_START_TIME}]

set PASS_COUNT [llength $PASSED_TESTS]
set FAIL_COUNT [llength $FAILED_TESTS]

echo ""
echo ""
echo "======================================================================"
echo "AES-CTR COMPLETE REGRESSION SUMMARY"
echo "======================================================================"
echo [format "%-42s %-8s %s" "Test file" "Result" "Duration"]
echo "----------------------------------------------------------------------"

foreach test_result $TEST_RESULTS {
    set result_file \
        [lindex $test_result 0]

    set result_status \
        [lindex $test_result 1]

    set result_duration \
        [lindex $test_result 2]

    echo [format \
        "%-42s %-8s %d s" \
        $result_file \
        $result_status \
        $result_duration]
}

echo "----------------------------------------------------------------------"
echo "Tests run:     $TEST_COUNT"
echo "Tests passed:  $PASS_COUNT"
echo "Tests failed:  $FAIL_COUNT"
echo "Total time:    $REGRESSION_DURATION seconds"
echo "======================================================================"
echo ""

if {$FAIL_COUNT == 0} {
    echo "COMPLETE REGRESSION PASSED"
    echo ""

    set REGRESSION_PASSED 1
} else {
    echo "COMPLETE REGRESSION FAILED"
    echo ""
    echo "Failed tests:"

    foreach failed_test $FAILED_TESTS {
        echo "  $failed_test"
    }

    echo ""

    set REGRESSION_PASSED 0
}

catch {wave zoom full}

if {!$REGRESSION_PASSED} {
    error "$FAIL_COUNT of $TEST_COUNT AES-CTR regression tests failed"
}