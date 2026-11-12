# Vendored dependencies

Copied in as ordinary files, never as git submodules, so the build needs no network and its inputs cannot change between review and launch.

| Dependency | Source | Commit | Why it is here |
| --- | --- | --- | --- |
| `judge` (`Judged.sol`, `JudgedTest.sol`) | https://github.com/gtmcknight/judge | `5a1d2f434fabe014b4ea1da7e6425fd5eed51e83` | The Judge oracle client the market inherits, and its free stand-in for `forge test`. MIT, see `lib/judge/LICENSE`. Unchanged. |
| `forge-std` | https://github.com/foundry-rs/forge-std | `8e40513d678f392f398620b3ef2b418648b33e89` (v1.11.0) | Tests only. Nothing in `src/` imports it. Copied from the judge repository's stripped vendored copy. |

Updating one of these is a deliberate change with its own review.
