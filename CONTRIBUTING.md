# Contributing

Small bug reports and focused fixes are welcome. Include the macOS version, Apple Silicon model, app version, the action you took, and the visible result. Use a public music link only if needed; remove account identifiers and private paths.

Never attach account cookies, tokens, passwords, downloaded music, or your complete application data directory. Synthetic fixtures should use clearly fake credential values.

Before proposing a change, run `./scripts/test.sh` and `./build.sh` on an Apple Silicon Mac. For authentication changes, distinguish tests with fake credentials from an actual sign-in; do not claim a first-time MFA flow passed if only an existing session was restored. Keep account data out of screenshots and logs.
