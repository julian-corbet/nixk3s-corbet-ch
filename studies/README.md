# Studies

Written investigations that motivate design decisions — comparisons, failed
approaches, upstream research. Cross-linked from experiments/ where a study
led to a runnable experiment.

| File | Finding |
|---|---|
| `what-forces-this-option.md` | An option's type is checked only where something evaluates it, and "all its read sites are messages" is only one of the ways that fails. A value discarded by an `mkIf`, an `if/else` branch or a short-circuit is equally unchecked, and a whole validation layer behind `config = lib.mkIf cfg.enable` leaves every option it governs unchecked for anyone who has not switched the feature on. Produced the assertions that force `replicas` and `hostPathType`, the split of `addressing` into an unconditional grammar block and a gated policy block, the three controls in the fail-closed check, and the ill-typed cases run in both states of `enable`. |
