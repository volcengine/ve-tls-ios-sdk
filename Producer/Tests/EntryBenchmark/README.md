# Swift / Objective-C entry benchmark

This benchmark compares the Swift and Objective-C public entry points. It is
not included in the SDK library. One mixed-language Xcode project has two targets:

- `EntryBenchmark-macCLI`: a macOS command-line executable that exits after
  close/drain and writes the JSON artifact to `~/Documents` by default.
- `EntryBenchmark-iOS`: an iOS application with a normal `UIApplicationMain`
  entry. It writes `Documents/entry-benchmark.json` when the run finishes.

The scheduler, fixed event, URLProtocol, callback queue, close/drain boundary,
and Mach/getrusage sampler are shared. The only measured entry call is the
actual public API:

- Objective-C: `-[TLSProducer addLog:mode:error:]` in
  `EntryBenchmarkObjCEntry.m`.
- Swift: `Producer.add(_:mode:)` in `EntryBenchmarkSwiftEntry.swift`.

The four string fields (1052 UTF-8 key/value bytes in total) and a current integral-second timestamp are constructed
once per run and reused for every call. The measured add latency is taken inside each entry's
same `@autoreleasepool` boundary, excluding the shared scheduler's
cross-language dispatch. There is no per-log await. `EBImmediateURLProtocol`
returns HTTP 200 immediately, increments only a request count, and never reads
or stores request bodies; this is not a network-throughput benchmark.

## Generate

Requirements are Xcode 14.3.1 or later and Ruby with the `xcodeproj` gem.
The benchmark uses Swift 5 language mode, matching the package's minimum toolchain.

```bash
cd Producer/Tests/EntryBenchmark
ruby generate_entry_benchmark_project.rb
```

The generator refuses to replace an existing project unless it contains its
own exact `.entry-benchmark-generated` marker.

The generated project references the local package at `../../../` and links
the `VolcengineTLSProducer` product directly. No CocoaPods or network
resolution is used.

## macOS smoke / run

Use a short explicit warm-up for a smoke run:

```bash
xcodebuild -project EntryBenchmark.xcodeproj \
  -scheme EntryBenchmark-macCLI -configuration Release \
  -sdk macosx -derivedDataPath /tmp/entry-benchmark-derived \
  CODE_SIGNING_ALLOWED=NO build

/tmp/entry-benchmark-derived/Build/Products/Release/EntryBenchmark-macCLI \
  --run-id smoke-objc --entry objc --persistence memory \
  --rate 100 --duration 2 --warmup 0 \
  --output /tmp/entry-benchmark-objc.json

/tmp/entry-benchmark-derived/Build/Products/Release/EntryBenchmark-macCLI \
  --run-id smoke-swift --entry swift --persistence memory \
  --rate 100 --duration 2 --warmup 0 \
  --output /tmp/entry-benchmark-swift.json
```

The CLI accepts `--entry swift|objc`, `--persistence memory|buffered`,
`--rate 100|500`, `--duration SEC`, `--warmup SEC`, `--run-id ID`, and
`--output PATH`. Defaults are `swift`, `memory`, `100`, `300`, and `60`; the
measurement window is `duration - warmup` and is reported using an actual
monotonic start/end interval. `--output` is intentionally a macOS CLI
override; iOS always uses its app Documents path.

For a signed iOS device build, override signing settings at the xcodebuild
boundary, for example:

```bash
xcodebuild -project EntryBenchmark.xcodeproj -scheme EntryBenchmark-iOS \
  -sdk iphoneos -configuration Release \
  PRODUCT_BUNDLE_IDENTIFIER=com.example.entrybenchmark \
  DEVELOPMENT_TEAM=TEAMID CODE_SIGN_IDENTITY="Apple Development" \
  PROVISIONING_PROFILE_SPECIFIER="PROFILE_NAME" \
  CODE_SIGNING_ALLOWED=YES build
```

For an unsigned simulator build, use `-sdk iphonesimulator
CODE_SIGNING_ALLOWED=NO`. Pass launch arguments in Xcode's scheme or with the
simulator launch tool, for example `--run-id ios-objc --entry objc --rate 500`.

## JSON and markers

At run start stdout prints `ENTRY_BENCHMARK_START run_id=...`; completion prints
`ENTRY_BENCHMARK_JSON run_id=... path=... status=...`. The JSON contains the
run ID, entry, rate, persistence, requested and actual timing, accepted and
rejected admission counts, terminal success/failure batch callback counts,
successful terminal raw/compressed bytes, URLProtocol request count, UTF-8
accepted-payload throughput, add-latency P50/P99, and RSS/CPU samples.

The existing iOS artifact is removed at the beginning of a run and the final
JSON is written atomically. Consumers must validate `run_id` and the requested
parameters/timestamps; file existence alone is not evidence that a new case
completed. Buffered persistence's close/drain result is reported explicitly;
the SDK does not promise that every admitted buffered item has a terminal
success callback at close.

Run both entries with the same arguments and compare their absolute values.
Alternate Swift-first and Objective-C-first ordering, use a unique `--run-id`,
and report variation across repeated runs. CPU and RSS include the entire test
process; they are not the SDK's exclusive resource usage.
