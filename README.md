# android-htop

[htop](https://github.com/htop-dev/htop) cross-compiled for Android, with the
terminfo database compiled into the binary.

Android ships no terminfo database, so a stock ncurses build dies with
`Error opening terminal`. Here ncurses is configured with `--disable-database`
plus a `--with-fallbacks=` list, which bakes the terminal descriptions straight
into `libncursesw.a`; htop then links that statically. The result is a single
executable with no data files and no dependencies beyond bionic.

## Getting a binary

Grab `htop-<version>-arm64` (or `-arm32`) from the
[latest release](../../releases/latest), or download the `htop-arm64` /
`htop-arm32` artifact from any [Actions run](../../actions).

```sh
adb push htop-3.5.3-arm64 /data/local/tmp/htop
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
| `CONFIG_DIR` | `/data/local/tmp/.config` | where htop keeps `htoprc` |
| `ANDROID_NDK_HOME` | *(downloads latest)* | use an existing NDK |
| `NCURSES_VERSION` | *(latest release)* | pin a version |
| `HTOP_VERSION` | *(latest release)* | pin a tag, e.g. `3.5.3` |
| `FALLBACKS` | see `build.sh` | terminals to compile in |

Names in `FALLBACKS` that the ncurses release does not know about are reported
and skipped rather than breaking the build.

## Configuration

htop resolves its config file as `$HOME` + `CONFIG_DIR` + `/htop/htoprc`. An adb
shell runs with `HOME=/`, and upstream's default `CONFIG_DIR` of `/.config`
therefore points at `//.config/htop/htoprc`, which htop cannot create — it runs
fine but complains `Cannot save configuration` on exit and forgets every
setting. So this build passes `--with-config=/data/local/tmp/.config`, giving:

```
/data/local/tmp/.config/htop/htoprc
```

Two things still override it: `$HTOPRC`, which names the file outright, and
`$XDG_CONFIG_HOME`, which replaces the `$HOME`+`CONFIG_DIR` part. Under Termux,
where `$HOME` is a real directory, set one of those (or rebuild with
`CONFIG_DIR=/.config`) — otherwise the path lands under Termux's home.

## CI

`.github/workflows/build.yml` builds both ABIs on every push and uploads them as
artifacts.

Release tags are `v<htop version>-<revision>`, e.g. `v3.5.3-0` for the first
release of htop 3.5.3 and `v3.5.3-1` if something on our side needs a rebuild of
the same upstream version. Pushing one publishes a GitHub Release carrying
`htop-<htop version>-arm64`, `htop-<htop version>-arm32` and the exact
NDK/ncurses/htop versions used.

The tag also pins what gets built: a `v3.5.3-0` tag builds htop 3.5.3 rather
than whatever is newest, so the assets can never disagree with the tag they ship
under. Ordinary pushes still track the latest upstream release, and
`workflow_dispatch` accepts explicit version pins.
