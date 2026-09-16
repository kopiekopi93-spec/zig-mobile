# zig-mobile

Unofficial fork of [Zig](https://ziglang.org) (upstream: `codeberg.org/ziglang/zig`, mirrored here
from a `0.17.0-dev` snapshot) with Android (Bionic) and iOS cross-compilation support added.

Zig itself doesn't support cross-compiling to Android or iOS out of the box (no bundled libc data
for Bionic, no bundled iOS SDK headers). This fork adds both.

## What's added on top of upstream Zig

- **Android/Bionic libc provider** (`src/libs/bionic.zig`): mirrors the existing `glibc.zig`
  architecture — symbol-version resolution from a generated abilists file, stub `.so` generation,
  CRT object handling. Supports `aarch64-linux-android`, `x86_64-linux-android`,
  `arm-linux-androideabi`, `x86-linux-android`, API levels 21 through 37.
- **`tools/update_bionic_libc.zig`** (+ helpers in `tools/bionic/`): deterministic generator that
  produces the Bionic libc data (headers, CRT objects, symbol/version abilists) from an official
  Android NDK release archive. Data currently bundled here was generated from
  `android-ndk-r30-linux.zip` (sha1 `5107f898313790e449e87eee2183d9a20602dee9`).
- **Android ELF page-size fix**: `src/link/Elf.zig` / `src/link/Lld.zig` match what Clang's driver
  passes for Android — 16 KB pages on aarch64/x86_64 (required for Android 15+), 4 KB on 32-bit ARM,
  LLD's own default on 32-bit x86.
- **iOS target registration**: `aarch64-ios` (device), `aarch64-ios-simulator`,
  `x86_64-ios-simulator` registered in `available_libcs`, using the existing Darwin/`libSystem.tbd`
  linker path.
- **`tools/fetch_them_macos_headers.zig`**: extended with `--os ios`, `--simulator`,
  `--simulator-only` to pull iOS device/simulator SDK headers, not just macOS. **Not verified against
  a real iOS SDK** (no Mac available at the time of writing) — compiles and type-checks, that's it.

## What's verified, and how

- All four Android targets (`aarch64`, `x86_64`, `arm`, `x86`) build real `.so` files with a
  patched build of this compiler (`ReleaseFast`, `-Denable-llvm`).
- A real ~1.2 MB native engine library and a synthetic thread-spawning TLS test library were both
  built for `aarch64-linux-android`, pushed to a physical Android 15 (API 35) device via `adb`, and
  `dlopen()`'d + called successfully from a small native harness executable — real device, not just
  `readelf` inspection.
- iOS: only compile-time verified (`build-lib` producing a real Mach-O `.dylib` with correct
  `LC_BUILD_VERSION platform=2` and linkage to `libSystem.B.dylib`) — no simulator/device run.

## Why this exists as a separate fork

This work was originally submitted upstream as three separate, focused pull requests plus a data
point comment on an existing TLS-alignment issue. All three PRs were removed from the upstream
repository without public explanation. The code and the real-device verification described above
are genuine; this fork exists so the work isn't lost, and so it's usable directly for projects that
need Zig-based Android/iOS cross-compilation today.

## License

Same as upstream Zig — MIT. See `LICENSE`.

## Status

Working, used in production for cross-compiling a game engine to Android. iOS support is
compile-verified only, not run-tested. Not affiliated with or endorsed by the Zig Software
Foundation.
