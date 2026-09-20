# cs-scripts

Build/utility scripts for the **napp-it cs** project family — the OmniOS/illumos
and Solaris build scripts for the Rust/Go cs-tools, plus the standalone
**Ollama library parser** used by the napp-it CS Tools Download page.

Project: napp-it / csweb-gui | Maintained by: gea-napp-it | AI-assisted by:
Claude (Anthropic)

## Repository layout

```
illumos/
  rustfs_omnios_1.0_release.sh # RustFS build on OmniOS/illumos (canonical;
                               # renamed from rustfs_omnios_1a.sh, 2026-09-20; history of the 2a5..2a12 line in its header)
  cs-imageindex_omnios_1a.sh   # cs-imageindex build on OmniOS/illumos
  build_llamacpp_omnios.sh     # llama.cpp llama-server on OmniOS -- OpenAI-
                               # compatible local LLM (10 illumos patches,
                               # verified on r151058)
  build.rc.sh                  # cargo install rustfs-cli + ipadm buffer fix
  needed_ip_modification_for_rustfs.txt
  build_restic_omnios.txt      # manual restic build notes (Go) on OmniOS
solaris/
  build_rclone_solaris.sh      # rclone from source on Solaris 11.4
  build_restic_solaris.sh      # restic from source on Solaris 11.4
ollama/
  ollama-library.pl            # Ollama library catalog parser (see CONTRACT
                               # in the script header)
benchmark/
  benchmark_worker.pl          # standalone ZFS pool benchmark (pure Perl, no
                               # fio needed; scratch dataset, 30 s steady
                               # test, honest classes storage-bound|cache|
                               # tool-limited) -- same file/name as the napp-it
                               # worker; see benchmark/readme.txt
```

## ZFS pool benchmark

`benchmark/benchmark_worker.pl` is a standalone pool benchmark for comparing
pools ("what does THIS pool really deliver?") on any ZFS host -- TrueNAS
CORE/SCALE, FreeBSD, illumos/Solaris, OpenZFS on Linux and Windows. It needs
only perl, zfs/zpool, df and optionally smartctl; the test medium is a scratch
dataset that is created on the pool under test and destroyed again at the end.
It is the SAME file (name and content) as the napp-it worker shipped in
`data/menues/_lib/scripts/bench/benchmark_worker.pl`.

```sh
perl benchmark/benchmark_worker.pl profile=quick pool=tank     # about 1-2 min
perl benchmark/benchmark_worker.pl profile=mailserver syncwrite=yes load=balanced
perl benchmark/benchmark_worker.pl check=yes pool=tank         # dry run, no I/O
perl benchmark/benchmark_worker.pl help=yes
```

The numbers are cache-safe by design: `primarycache=metadata` (data out of the
ARC, metadata still cached), `sync=always` for the sync-write phase, a
CONCURRENT `zpool iostat -v` sample per phase, and `recordsize=4K` for the 4k
test file. Every result is tagged `storage-bound`, `cache`, `cache-influenced`
or `tool-limited`, and the log ends with a `BENCH_DONE` marker. See
`benchmark/readme.txt` for the details and the measured limitations.

## Ollama library parser

`ollama/ollama-library.pl` reads the public Ollama model library
(ollama.com/library) via curl and returns the complete model/tag catalog on
demand — model names, per-tag download size, context window, input
capabilities (text/image) and quantization — so a GUI can offer a filtered
model selection for `ollama pull`.

The script is loaded from this repository on demand (raw.githubusercontent)
and cached locally; the **interface contract is pinned in the script header**
(`CONTRACT cs-ollama-catalog-v1`) so the calling GUI stays stable even when
Ollama changes its website markup — only the fetch/parse internals below the
contract header may change.

### Quick start

```sh
perl ollama/ollama-library.pl --list --json
perl ollama/ollama-library.pl --json --vision --param-max 14 --size-max 10
perl ollama/ollama-library.pl --json --vision --newer 12
perl ollama/ollama-library.pl --version
```

### Contract summary (see the script header for the exact schema)

| Flag | Meaning |
|---|---|
| `--list` | list models (name, capabilities, parameter sizes) |
| `--tags [--model NAME]` | per-tag catalog (all models or one model) |
| `--json` | machine-readable JSON (default output; `--tsv` for text) |
| `--vision` | only models capable of image input |
| `--newer MONTHS` | only models updated within MONTHS (approximate) |
| `--param-max B` | only models with <= B billion parameters |
| `--size-max GB` | only tags with <= GB download size |
| `--cache SECS` | cache TTL for the catalog (default 2592000 = 30 days) |
| `--refresh` | rebuild the catalog (ignore the cache) |
| `--version` | print the contract version |

Output record (one per tag):

```json
{ "model": "llama3.2-vision",
  "tag":   "llama3.2-vision:11b-instruct-q4_K_M",
  "size_gb": 7.8, "context": 128000,
  "input": ["text","image"], "quant": "q4_K_M",
  "param_b": 11, "age_days": 300 }
```

## License

BSD 2-Clause — see [LICENSE](LICENSE). Copyright (c) 2026 Guenther Alka /
napp-it.org.
