# uncom

Tool for automatic decompression of common archives.

## Supported formats

**Archives:**
- `.zip`
- `.7z`, `.rar`
- `.tar`
- `.tar.gz`, `.tgz`
- `.tar.bz2`, `.tbz2`
- `.tar.xz`, `.txz`
- `.tar.lzma`
- `.tar.zst`, `.tzst`

**Single-file compression:**
- `.gz`
- `.bz2`
- `.xz`
- `.lzma`
- `.zst`
- `.lz4`

## Usage

```
uncom [PATH] [OPTIONS]
```

One or more `PATH`s may be given; each is processed in turn.

| Flag | Long | Description |
|------|------|-------------|
| `-r` | `--remove` | Remove archive when finished |
| `-f` | `--force` | Force override output directory |
| `-q` | `--quiet` | Minimize displayed info |
| `-l` | `--local` | Unpack all files to this directory |

By default archives are extracted into a directory named after the archive (minus its extension). Options apply to every path given.
