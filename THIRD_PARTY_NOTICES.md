# Third-party notices for Stage M1

The existing Flutter/Rust dependency licenses remain applicable. Stage M1 adds these upstream rule references at fixed revisions:

- **Win-CodexBar**, commit `0eae1ea5c65c35bf184f116b41c131550b22d2cb`, MIT. The local session validator adapts rules from `rust/src/codex_workspaces/turn_performance.rs` and `rust/src/codex_costs/identified_requests.rs`: terminal and timestamp bounds, response identity ownership, validated counters, request/turn usage agreement, and checked weighted aggregation. This project implements these rules in its own Rust log collector; it does not run or embed the upstream application. Full upstream license: `licenses/Win-CodexBar-MIT.txt`. Source: https://github.com/nesszer/Win-CodexBar/tree/0eae1ea5c65c35bf184f116b41c131550b22d2cb
- **ccusage**, commit `f9c9154f9e8cdce4bedd5119dc7a41ec490f96b8`, MIT. Its `rust/adapters/codex/src/parser.rs` informed the conservative handling of cumulative snapshots, compaction and legacy `token_count` records. No parser implementation was copied; this reference does not establish support for all ccusage schemas. Full upstream license is included for attribution: `licenses/ccusage-MIT.txt`. Source: https://github.com/ccusage/ccusage/tree/f9c9154f9e8cdce4bedd5119dc7a41ec490f96b8

AIPerf is design research for later M2/M3 work. Stage M1 contains no AIPerf code, benchmark request runtime or migrated streaming metric implementation.
