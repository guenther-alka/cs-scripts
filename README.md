# cs-scripts

Build/utility scripts for the **napp-it cs** project family — the OmniOS/illumos
and Solaris build scripts for the Rust/Go cs-tools, plus the standalone
**Ollama library parser** used by the napp-it CS Tools Download page.

Project: napp-it / csweb-gui | Maintained by: gea-napp-it | AI-assisted by:
Claude (Anthropic)

## Repository layout

```
illumos/
  rustfs_omnios_1a.sh          # RustFS build on OmniOS/illumos (canonical;
                               # history of the 2a5..2a12 line in its header)
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
```

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
