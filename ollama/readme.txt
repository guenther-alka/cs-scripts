==========================================================================
 readme.txt -- ollama/ model catalog scripts
 (c) 2026 Guenther Alka / napp-it.org -- Project: napp-it cs
==========================================================================

This folder holds the two model-catalog parser scripts used by the
napp-it cs "Local AI app" feature (CS_Tools_Download / AI Helpdesk) to
offer a filtered model selection for Ollama and llama-server (Llama-cpp,
GGUF) installs. Both are plain Perl, fetched from GitHub on demand and
cached locally by the GUI (see ai_ollama_parser_script() / ai_llama_
parser_script() in aihelplib.pl, 30-day cache TTL).

They share a near-identical CLI contract so the calling GUI code can
treat them mostly the same:

  --list [--json|--tsv]              one record per MODEL family
  [--tags] [--model NAME] [--json|--tsv]
                                      one record per tag/quantization
  --vision                           keep only records with image input
  --param-max B                      keep only records with param_b <= B
  --size-max GB                      keep only records with size_gb <= GB
  --cache SECS / --refresh / --cached-only
  --version / --help

Both scripts are self-documenting -- see the CONTRACT header comment at
the top of each file for the exact --json/--tsv output schema.

Contents at a glance:

  ollama-library.pl     Live Ollama library catalog (scrapes ollama.com)
  llama-library.pl       Curated Llama-cpp (GGUF) catalog (hand-maintained)

==========================================================================
 ollama-library.pl
==========================================================================
Purpose:
  Reads the public Ollama model library (ollama.com/library) via curl and
  returns the complete model/tag catalog: model names, per-tag download
  size, context window, input capabilities (text/image) and
  quantization.

  This is a LIVE scrape -- "rebuild catalog" in the GUI re-fetches
  ollama.com/library and re-parses it (subject to the fetching host
  having internet access; there is no external repo-auth gate). Results
  are cached locally (default 30 days) so normal browsing of the model
  list does not re-fetch every time.

  Runs on the WINDOWS FRONTEND (not on the managed illumos/Solaris
  member) via plain backticks -- there is no rcmd/socket channel
  involved for this script.

Usage:
  perl ollama-library.pl --list --json
  perl ollama-library.pl --tags --model llama3.2 --json
  perl ollama-library.pl --version

Notes / gotchas:
  - The cache-read short-circuit explicitly excludes --list mode: the
    cache stores per-tag records, and --list's family-collapsed view is
    never read from it. So "--list --cached-only" always returns
    EMPTY, even with a fresh, valid full-catalog cache file present --
    this is intentional (per-tag data can't be honestly collapsed to
    per-family without re-deriving it), not a bug, but it is easy to
    trip over when reusing this script's cache from other code: always
    fetch the full per-tag view (--json, no --list) if you need to read
    from an existing cache without --list.

==========================================================================
 llama-library.pl
==========================================================================
Purpose:
  Unlike ollama-library.pl, there is no single official "GGUF library"
  website to scrape -- GGUF quantizations are published as individual
  HuggingFace repos by various community quantizers. This script instead
  ships a hand-curated list of known-good GGUF repos/files (currently:
  bartowski's quantizations).

  MAINTENANCE: to add/update models, edit the @CATALOG data table near
  "CURATED CATALOG DATA" in the script and commit/push here -- the GUI
  re-fetches this script from GitHub (cached) so a push reaches every
  install on their next catalog rebuild. There is no live scraping to
  break, so --refresh is effectively instant (kept only for interface
  symmetry with ollama-library.pl).

Usage:
  perl llama-library.pl --list --json
  perl llama-library.pl --tags --model Meta-Llama-3.1-8B-Instruct --json
  perl llama-library.pl --version

Ollama-catalog enrichment (cs_rc_26.09.01_05):
  The curated table has no real data for "vision" (always false) or
  "age_days" (always 0) -- there's nothing to derive them from in a
  hand-curated HuggingFace repo list. At catalog-build time,
  llama-library.pl best-effort fuzzy-matches each curated model family
  against a SIBLING ollama-library.pl (found in the same directory) via
  a normalized family-name key, and fills in vision/age_days from any
  match found.

  This is opportunistic reuse only:
    - It calls the sibling with --cached-only, so it NEVER triggers a
      live ollama.com fetch of its own -- only whatever the Ollama
      catalog already has cached from its own independent "rebuild"
      button is used. Missing/stale/absent Ollama cache -> silently no
      enrichment (curated defaults stay: vision=0, age_days=0), never a
      crash or a hang.
    - There is no canonical mapping between HuggingFace GGUF repo names
      (e.g. "Meta-Llama-3.1-8B-Instruct") and Ollama's own model names
      (e.g. "llama3.1") -- the match is a heuristic string-key
      normalization (see _family_key() in the script), not a verified
      identity. It can miss real matches (no match found -> unenriched,
      safe) or, in principle, match two unrelated models that happen to
      normalize to the same key (not observed in the current curated
      table, but not structurally impossible either).
    - Because of that, any GUI surfacing these enriched fields for
      Llama-cpp models MUST show a visible disclaimer next to them
      (see CS_Tools_Download/action.pl in the csweb-gui repo for the
      current wording) -- this was an explicit design requirement, not
      an afterthought.

==========================================================================
 Adding a new curated Llama-cpp model
==========================================================================
1. Find (or quantize) a GGUF release on HuggingFace, ideally from a
   consistently-named/tagged source (bartowski's repos are the current
   convention here).
2. Add one or more entries to @CATALOG in llama-library.pl: model
   (family name), file (target filename), url (resolve/main/... download
   URL), size_gb, context, input (["text"] or ["text","image"]), quant,
   param_b.
3. perl -c llama-library.pl to check syntax.
4. Commit and push -- every csweb-gui install picks it up on its next
   catalog cache refresh (or immediately after --refresh / "rebuild
   model catalog" in the GUI).
