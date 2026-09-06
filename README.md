# android-htop

[htop](https://github.com/htop-dev/htop) cross-compiled for Android, with the
terminfo database compiled into the binary.

Android ships no terminfo database, so a stock ncurses build dies with
`Error opening terminal`. Here ncurses is configured with `--disable-database`
plus a `--with-fallbacks=` list, which bakes the terminal descriptions straight
into `libncursesw.a`; htop then links that statically. The result is a single
executable with no data files and no dependencies beyond bionic.

## Getting a binary

Grab `htop-<abi>` from the [latest release](../../releases/latest), or download
the `htop-<abi>` artifact from any [Actions run](../../actions).

```sh
adb push htop-arm64-v8a /data/local/tmp/htop
adb shell chmod 755 /data/local/tmp/htop
adb shell -t /data/local/tmp/htop
```

Without root, htop only sees what your shell user is allowed to see. `adb root`
(or running it from a root shell) gives the full process list.

## Building locally

```sh
./build.sh                       # both ABIs into dist/
ABIS=arm64-v8a ./build.sh        # just one
```

Everything is fetched on demand into `build/`: the latest Android NDK, the
latest ncurses release, and the latest htop release. Host `tic` and `infocmp`
are required — they compile the fallback terminfo entries.

| Variable | Default | |
| --- | --- | --- |
| `ABIS` | `arm64-v8a armeabi-v7a` | space separated ABI list |
| `API` | `26` | minimum Android API level; htop needs `nl_langinfo`, added in 26 |
| `ANDROID_NDK_HOME` | *(downloads latest)* | use an existing NDK |
| `NCURSES_VERSION` | *(latest release)* | pin a version |
| `HTOP_VERSION` | *(latest release)* | pin a tag, e.g. `3.5.3` |
| `FALLBACKS` | see `build.sh` | terminals to compile in |

Names in `FALLBACKS` that the ncurses release does not know about are reported
and skipped rather than breaking the build.

## CI

`.github/workflows/build.yml` builds both ABIs on every push and uploads them as
artifacts. Pushing a `v*` tag also publishes a GitHub Release with
`htop-arm64-v8a`, `htop-armeabi-v7a` and the exact NDK/ncurses/htop versions
used. `workflow_dispatch` accepts version pins if you need to reproduce an
older build.
