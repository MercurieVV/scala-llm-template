#!/bin/sh
# Outlives the DSH_STOP_BUDGET=20 s this case sets (its cap is the whole budget, since DSH_TESTS_CAP
# is unset and its own default of 300 s is not the binding one) -- so the Stop hook's budget is nearly
# spent by the time turnEndTests hands off to the vericoding stage, and that stage must still behave
# sanely (its own "not started" note under its existing rule) rather than error or run anyway. The
# budget carries a wide margin over 10 s at the loop's own gate check (whatever this machine's own
# overhead is before turnEndTests even starts) precisely so it is the CAP that fires here, not the
# "budget already too low to start" branch -- a fixture that fires the wrong branch under load proves
# nothing about the scenario it names.
sleep 25
exit 0
