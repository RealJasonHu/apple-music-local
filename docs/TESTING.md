# Validation

## Automated checks

The v2.0 implementation passed:

- 18 backend integration tests: subscription/search responses, region/pagination, URL and credential handling, synthetic conversion, partial results, and real process-group cancellation.
- 38 synthetic Swift storage/navigation checks: expiry, cookie scope, atomic writes, file permissions, logout revocation, and filesystem failure handling.
- 7 model-state regression tests: stale callbacks, logout/start races, account changes, pagination region changes, and per-result download scope.
- Swift link-parser checks for batching, deduplication, tracking cleanup, unsupported URLs, and credential-paste rejection.

Run `./scripts/test.sh`. These checks do not require a real Apple account. Compiler availability and network access for dependency bootstrap are separate prerequisites.

## Manual service checks — 2026-09-25

With an existing authorized subscription, the native v2.0 app successfully:

- restored the account session after quit/relaunch and verified the subscription online;
- restored the signed-in official Apple web page, including account/library controls;
- searched songs, albums, and playlists, and expanded a result list from 25 to 50 items;
- added two selected results to the queue;
- downloaded a full song as WAV and MP3, both approximately 6 minutes 10 seconds, and decoded each file completely with exit status 0;
- preserved prior history, output-folder and format preferences.

WAV output was 24-bit PCM at 44.1 kHz stereo; MP3 output was 320 kbps at 44.1 kHz stereo. Both came from lossy web AAC. Music files, account details, private local paths, and credential data are excluded from this repository and release.

## Boundaries

A fresh Apple password/MFA challenge was not completed during those tests. The real account was not deliberately signed out; logout race/error behavior was checked with synthetic data. Apple's authentication lifetime and content availability remain service-controlled. A passing build or unit test alone does not establish a successful authenticated media download.
