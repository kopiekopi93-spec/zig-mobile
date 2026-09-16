<div align="center">

![ZIG](https://ziglang.org/img/zig-logo-dynamic.svg)

# zig-mobile

**Unofficial fork of [Zig](https://ziglang.org) with Android (Bionic) and iOS cross-compilation support**

![platform](https://img.shields.io/badge/platform-android%20%7C%20ios-3776ab?style=flat-square)
![zig version](https://img.shields.io/badge/zig-0.17.0--dev-f7a41d?style=flat-square&logo=zig&logoColor=white)
![license](https://img.shields.io/badge/license-MIT-informational?style=flat-square)
![status](https://img.shields.io/badge/android-verified%20on%20real%20device-4c9a2a?style=flat-square)
![status](https://img.shields.io/badge/ios-compile--verified%20only-orange?style=flat-square)

</div>

---

Upstream: `codeberg.org/ziglang/zig`, mirrored here from a `0.17.0-dev` snapshot (`872800c0`,
2026-09-14). Zig itself doesn't cross-compile to Android or iOS out of the box — no bundled libc
data for Bionic, no bundled iOS SDK headers. **This fork adds both.**

## What's added on top of upstream Zig

| Addition | Where | What it does |
|---|---|---|
| **Android/Bionic libc provider** | `src/libs/bionic.zig` | Mirrors the existing `glibc.zig` architecture — symbol-version resolution from a generated abilists file, stub `.so` generation, CRT object handling. `aarch64-linux-android`, `x86_64-linux-android`, `arm-linux-androideabi`, `x86-linux-android`, API 21–37. |
| **Bionic data generator** | `tools/update_bionic_libc.zig` + `tools/bionic/` | Deterministic: produces headers, CRT objects, symbol/version abilists from an official NDK archive. Bundled data generated from `android-ndk-r30-linux.zip` (sha1 `5107f898313790e449e87eee2183d9a20602dee9`). |
| **Android ELF page-size fix** | `src/link/Elf.zig`, `src/link/Lld.zig` | Matches Clang's driver for Android: 16 KB pages on aarch64/x86_64 (Android 15+ requirement), 4 KB on 32-bit ARM, LLD's own default on 32-bit x86. |
| **iOS target registration** | `lib/std/zig/target.zig`, `lib/libc/darwin/libSystem.tbd` | `aarch64-ios` (device), `aarch64-ios-simulator`, `x86_64-ios-simulator` registered in `available_libcs`, via the existing Darwin linker path. |
| **iOS SDK header tool** | `tools/fetch_them_macos_headers.zig` | `--os ios`, `--simulator`, `--simulator-only` flags to pull iOS device/simulator headers, not just macOS. **Not verified against a real SDK** (no Mac available) — compiles and type-checks, that's it. |

## What's verified, and how

- ✅ **All four Android targets** (`aarch64`, `x86_64`, `arm`, `x86`) build real `.so` files with a
  patched `ReleaseFast` / `-Denable-llvm` build of this compiler.
- ✅ **Real device test**: a ~1.2 MB native engine library and a synthetic thread-spawning TLS test
  library, both built for `aarch64-linux-android`, pushed to a physical **Android 15 (API 35)**
  device via `adb`, `dlopen()`'d and called successfully from a native harness — not just
  `readelf` inspection.
- ⚠️ **iOS**: compile-time only — `build-lib` produces a real Mach-O `.dylib` with correct
  `LC_BUILD_VERSION platform=2` and linkage to `libSystem.B.dylib`. No simulator/device run.

## Why this exists as a separate fork

This work was submitted upstream as three focused pull requests plus a data point comment on an
existing TLS-alignment issue. All three PRs were removed from the upstream repository without
public explanation. The code and the real-device verification above are genuine; this fork exists
so the work isn't lost, and is usable directly by anyone who needs Zig-based Android/iOS
cross-compilation today.

## Everything else

This is Zig — see **[README-upstream.md](README-upstream.md)** for the original project README
(build instructions, language overview, community links), unchanged from upstream.

## License

Same as upstream Zig — MIT. See [`LICENSE`](LICENSE).

---

<div align="center">

Working, used in production for cross-compiling a game engine to Android.
Not affiliated with or endorsed by the Zig Software Foundation.

</div>
