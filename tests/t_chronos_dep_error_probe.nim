## tests/t_chronos_dep_error_probe.nim
##
## Probe target for `tests/test_chronos_dep_error.sh`: imports
## `lockfree/chronos` directly (unlike `tests/t_chronos.nim`, which gates
## its own import behind a chronos-availability probe). When built with
## `-d:lockfreeChronos` and chronos NOT installed, this file must fail
## to compile with the actionable error from `src/lockfree/chronos.nim`
## referencing `docs/api/chronos.md` and `nimble install chronos`.
##
## This file should never be invoked by the regular `nimble test` task;
## it exists solely as a compile-failure probe for the dep-error shell
## test.
import lockfree/chronos
