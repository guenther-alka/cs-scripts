#!/usr/bin/env perl
#
# ============================================================================
#  llama-library.pl -- Llama-cpp (GGUF) model catalog
#
#  Unlike ollama-library.pl (which scrapes the live ollama.com/library
#  pages), there is no single official "GGUF library" website to scrape --
#  GGUF quantizations are published as individual HuggingFace repos by
#  various community quantizers. This script instead ships a hand-curated
#  list of known-good GGUF repos/files (currently: bartowski's
#  quantizations, widely used and consistently named/tagged).
#
#  MAINTENANCE: to add/update models, edit the @CATALOG data table below
#  (near "CURATED CATALOG DATA") and commit/push to this repo -- the GUI
#  re-fetches this script from GitHub (cached, see ai_llama_parser_script()
#  in aihelplib.pl) so a push here reaches every install on their next
#  catalog rebuild. There is no live scraping to break, so --refresh is
#  effectively instant (kept only for interface symmetry with
#  ollama-library.pl / ai_ollama_catalog_rebuild_bg()).
#
#  ==========================================================================
#  CONTRACT cs-llama-catalog-v1  (STABLE -- see below)
#  ==========================================================================
#  This header section defines the ONLY stable interface. The calling
#  application may rely on it. The curated data table below may change
#  freely (models added/removed/re-quantized) -- the contract must stay
#  identical.
#
#  Usage:
#    llama-library.pl --list [--json|--tsv]
#    llama-library.pl [--tags] [--model NAME] [--json|--tsv]
#                     [--vision] [--param-max B] [--size-max GB]
#                     [--cache SECS] [--refresh] [--cached-only]
#    llama-library.pl --version
#    llama-library.pl --help
#
#  Output schema (--json, one object per file):
#    { "contract": "cs-llama-catalog-v1",
#      "count": N,
#      "cached": 0|1,
#      "built": 1788091745,             # epoch of the catalog cache (0 if none)
#      "records": [ {
#        "model":   "Meta-Llama-3.1-8B-Instruct",   # model family name
#        "tag":     "Meta-Llama-3.1-8B-Instruct-Q4_K_M",  # display tag (no .gguf)
#        "file":    "Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf", # target filename
#                                                     # (this is what ends up
#                                                     # in /root/models/ on
#                                                     # the member)
#        "url":     "https://huggingface.co/.../resolve/main/....gguf",
#        "size_gb": 4.92,                # download size (GB)
#        "context": 128000,              # context window (tokens, 0=unknown)
#        "input":   ["text"],            # input modalities
#        "quant":   "Q4_K_M",            # quantization
#        "param_b": 8,                   # parameter size in billions
#        "age_days": 0 } ] }             # curated entries have no genuine
#                                         # release date -- 0 unless a
#                                         # best-effort Ollama family match
#                                         # supplies one, see ENRICHMENT below
#
#  --list: records without per-tag fields (size_gb/context/input/quant/
#          param_b/url are 0/''/[] there); one record per MODEL family.
#  TSV:    header line + one line per record (fields in the same order as
#          the JSON keys above, "input" comma-joined).
#
#  Filters are applied on the (cached) catalog at query time:
#    --vision       keep only records with "image" in input
#    --param-max B  keep only records with 0 < param_b <= B
#    --size-max GB  keep only records with size_gb > 0 and <= GB
#    (--newer is accepted for CLI symmetry with ollama-library.pl but is a
#    no-op here -- curated entries have no meaningful "age".)
#
#  Caching:
#    The built catalog (== the curated table, so this is cheap) is cached
#    locally the same way as ollama-library.pl for interface symmetry.
#    Cache file: $CS_SCRIPTS_CACHE or ~/.cache/cs-scripts/llama-library.json
#
#  ENRICHMENT (cs_rc_26.09.01_05, Gea: "ollama katalog ... als quelle fuer
#  infos die der cpp katalog eventuell nicht liefert?"):
#    At build time (--refresh, or any build when no fresh cache exists),
#    this script best-effort matches each curated model family against a
#    SIBLING ollama-library.pl in the same directory (both are fetched
#    into the same _cfg dir by aihelplib.pl) to fill in "vision" and
#    "age_days" -- fields the curated table itself has no real data for
#    (every curated entry ships with vision=>0, age_days=>0; see
#    aihelplib.pl.clg / this repo's README for why). Deliberately
#    --cached-only against the sibling: this NEVER triggers a live
#    ollama.com fetch of its own -- it only reuses whatever the Ollama
#    catalog already has cached from its own independent rebuild, so
#    rebuilding the Llama catalog gains no new network dependency.
#    The match is a HEURISTIC string comparison (HuggingFace repo naming
#    and Ollama's own model names have no canonical mapping -- e.g.
#    "Meta-Llama-3.1-8B-Instruct" vs "llama3.1") -- wrong or missed
#    matches are expected and acceptable, NOT a bug to chase down. The
#    calling GUI must show a visible disclaimer next to any data that came
#    from this (CS_Tools_Download/action.pl does, next to the Llama-cpp
#    heading). If the sibling script or its cache is missing, enrichment
#    silently yields nothing -- curated defaults (vision=0, age_days=0)
#    are used exactly as before this feature existed.
# ============================================================================
use strict;
use warnings;
use Getopt::Long qw(:config bundling no_ignore_case);
use JSON::PP;
use File::Path qw(make_path);
use File::Basename;

our $CONTRACT = 'cs-llama-catalog-v1';
our $VERSION  = '1.0';
our @CATALOG;   # populated near the bottom of the file (CURATED CATALOG
                # DATA) -- forward-declared here so build_model_list()/
                # build_full_catalog() above it see it under `use strict`
                # (an `our` declared only at its point of use is lexically
                # in scope from there on, not file-wide).

# ============================================================================
#  CURATED CATALOG DATA -- edit here to add/update/remove models. Sizes and
#  filenames verified against the repo's HuggingFace file listing on
#  2026-09-01; re-verify if a repo gets re-quantized under the same name.
#  Populated here (before the "skip CLI if caller" return below) so it's
#  also available when this script is `require`d/`do`ne as a library.
# ============================================================================
@CATALOG = (
    {
        model => 'Meta-Llama-3.1-8B-Instruct',
        repo  => 'bartowski/Meta-Llama-3.1-8B-Instruct-GGUF',
        param_b => 8, context => 128000, vision => 0,
        quants => [
            { quant => 'Q4_K_M', size_gb => 4.92 },
            { quant => 'Q5_K_M', size_gb => 5.73 },
            { quant => 'Q6_K',   size_gb => 6.60 },
            { quant => 'Q8_0',   size_gb => 8.54 },
        ],
    },
    {
        model => 'Llama-3.2-3B-Instruct',
        repo  => 'bartowski/Llama-3.2-3B-Instruct-GGUF',
        param_b => 3, context => 128000, vision => 0,
        quants => [
            { quant => 'Q4_K_M', size_gb => 2.02 },
            { quant => 'Q5_K_M', size_gb => 2.32 },
            { quant => 'Q6_K',   size_gb => 2.64 },
            { quant => 'Q8_0',   size_gb => 3.42 },
        ],
    },
    {
        model => 'Qwen2.5-7B-Instruct',
        repo  => 'bartowski/Qwen2.5-7B-Instruct-GGUF',
        param_b => 7, context => 32768, vision => 0,
        quants => [
            { quant => 'Q4_K_M', size_gb => 4.68 },
            { quant => 'Q5_K_M', size_gb => 5.44 },
            { quant => 'Q6_K',   size_gb => 6.25 },
            { quant => 'Q8_0',   size_gb => 8.10 },
        ],
    },
    {
        model => 'Mistral-7B-Instruct-v0.3',
        repo  => 'bartowski/Mistral-7B-Instruct-v0.3-GGUF',
        param_b => 7, context => 32768, vision => 0,
        quants => [
            { quant => 'Q4_K_M', size_gb => 4.37 },
            { quant => 'Q5_K_M', size_gb => 5.14 },
            { quant => 'Q6_K',   size_gb => 5.95 },
            { quant => 'Q8_0',   size_gb => 7.70 },
        ],
    },
    {
        model => 'Phi-3.5-mini-instruct',
        repo  => 'bartowski/Phi-3.5-mini-instruct-GGUF',
        param_b => 3.8, context => 128000, vision => 0,
        quants => [
            { quant => 'Q4_K_M', size_gb => 2.39 },
            { quant => 'Q5_K_M', size_gb => 2.82 },
            { quant => 'Q6_K',   size_gb => 3.14 },
            { quant => 'Q8_0',   size_gb => 4.06 },
        ],
    },
);

# when required as a library (tests/embedding), skip the CLI main
return 1 if caller;

# ---------------------------------------------------------------- defaults
my %opt = (
    cache => 2592000,      # 30 days (kept for symmetry; rebuild is instant)
    json => 1,
);

GetOptions(
    'list'       => \$opt{list},
    'tags'       => \$opt{tags},
    'model=s'    => \$opt{model},
    'json'       => \$opt{json},
    'tsv'        => sub { $opt{json} = 0; $opt{tsv} = 1; },
    'vision'     => \$opt{vision},
    'newer=i'    => \$opt{newer},       # accepted, no-op (see header)
    'param-max=f'=> \$opt{param_max},
    'size-max=f' => \$opt{size_max},
    'cache=i'    => \$opt{cache},
    'refresh'    => \$opt{refresh},
    'cached-only'=> \$opt{cached_only},
    'version'    => \$opt{version},
    'help'       => \$opt{help},
) or exit 1;

if ($opt{help})    { print <<HELP; exit 0; }
llama-library.pl  (contract $CONTRACT, script $VERSION)

Usage:
  --list                      list model families (no per-tag fields)
  --tags                      per-file catalog (default)
  --model NAME                only this model family
  --json                      JSON output (default)
  --tsv                       tab-separated output
  --vision                    only vision-capable entries
  --param-max B               only <= B billion parameters
  --size-max GB               only <= GB download size
  --cache SECS                cache TTL (0 = never expire, manual rebuild
                              only; default 2592000 = 30 days)
  --refresh                   rebuild the catalog (curated -- instant)
  --cached-only               never build -- return the cache or empty
                              (GUI triggers rebuilds in the background)
  --version                   print the contract name
HELP

if ($opt{version}) { print "$CONTRACT\n"; exit 0; }

my $cache_file = cache_file();
my $records    = [];

if (!$opt{refresh} && !$opt{list} && -f $cache_file && cache_fresh($cache_file, $opt{cache})) {
    my $data = read_json_file($cache_file);
    $records = $data && ref($data->{records}) eq 'ARRAY' ? $data->{records} : [];
    $opt{cached} = 1;
}

if (!@$records) {
    if ($opt{cached_only}) {
        # --cached-only: never build here (the GUI triggers a background
        # rebuild). Return empty records so the caller shows "not built yet".
        $opt{cached} = 0;
    } else {
        $opt{cached} = 0;
        $records = $opt{list} ? build_model_list() : build_full_catalog();
        if (!$opt{list} && @$records) {
            make_path(dirname($cache_file)) unless -d dirname($cache_file);
            write_json_file($cache_file, { contract => $CONTRACT, built => time(), records => $records });
        }
    }
}

# ------------------------------------------------------------------ filters
my @recs = @$records;
if ($opt{model}) {
    @recs = grep { ($_->{model} // '') eq $opt{model} } @recs;
}
if ($opt{vision}) {
    @recs = grep { my $in = $_->{input}; ref($in) eq 'ARRAY' && grep { $_ eq 'image' } @$in } @recs;
}
if (defined $opt{param_max} && $opt{param_max} > 0) {
    @recs = grep { my $p = $_->{param_b} // 0; $p > 0 && $p <= $opt{param_max} } @recs;
}
if (defined $opt{size_max} && $opt{size_max} > 0) {
    @recs = grep { my $s = $_->{size_gb} // 0; $s > 0 && $s <= $opt{size_max} } @recs;
}

# ------------------------------------------------------------------- output
if ($opt{tsv}) {
    print join("\t", qw(model tag file url size_gb context input quant param_b age_days)), "\n";
    for my $r (@recs) {
        my $in = ref($r->{input}) eq 'ARRAY' ? join(',', @{$r->{input}}) : '';
        print join("\t", $r->{model} // '', $r->{tag} // '', $r->{file} // '',
            $r->{url} // '', $r->{size_gb} // '', $r->{context} // '', $in,
            $r->{quant} // '', $r->{param_b} // '', $r->{age_days} // ''), "\n";
    }
} else {
    my $built = 0;
    if (-f $cache_file) { my @st = stat($cache_file); $built = $st[9] || 0; }
    print encode_json({ contract => $CONTRACT, count => scalar(@recs),
        cached => $opt{cached} ? 1 : 0, built => $built, records => \@recs }), "\n";
}
exit 0;

# ------------------------------------------------------------------- caching
sub cache_file {
    my $base = $ENV{CS_SCRIPTS_CACHE} // '';
    $base = "$ENV{HOME}/.cache/cs-scripts" if $base eq '';
    return "$base/llama-library.json";
}
sub cache_fresh {
    my ($f, $ttl) = @_;
    my @st = stat($f);
    return 0 unless @st;          # no cache file yet
    return 1 if $ttl == 0;        # --cache 0 = never expire (manual --refresh only)
    return (time() - $st[9]) <= $ttl;
}
sub read_json_file {
    my ($f) = @_;
    open my $fh, '<', $f or return undef;
    local $/; my $c = <$fh>; close $fh;
    my $d = eval { decode_json($c) };
    return $d;
}
sub write_json_file {
    my ($f, $d) = @_;
    open my $fh, '>', $f or return;
    print $fh encode_json($d); close $fh;
}

# ------------------------------------------------------------------ library
sub build_model_list {
    my %seen;
    my @recs;
    my $enrich = _ollama_family_map();
    for my $m (@CATALOG) {
        next if $seen{$m->{model}}++;
        my ($vision, $age_days) = _enriched($m, $enrich);
        push @recs, {
            model => $m->{model}, tag => $m->{model}, file => '', url => '',
            size_gb => 0, context => 0,
            input => $vision ? ['text','image'] : ['text'],
            quant => '', param_b => $m->{param_b} // 0, age_days => $age_days,
        };
    }
    return \@recs;
}

sub build_full_catalog {
    my @recs;
    my $enrich = _ollama_family_map();
    for my $m (@CATALOG) {
        next if $opt{model} && $m->{model} ne $opt{model};
        my ($vision, $age_days) = _enriched($m, $enrich);
        for my $q (@{$m->{quants}}) {
            my $file = "$m->{model}-$q->{quant}.gguf";
            push @recs, {
                model    => $m->{model},
                tag      => "$m->{model}-$q->{quant}",
                file     => $file,
                url      => "https://huggingface.co/$m->{repo}/resolve/main/$file",
                size_gb  => $q->{size_gb},
                context  => $m->{context} // 0,
                input    => $vision ? ['text','image'] : ['text'],
                quant    => $q->{quant},
                param_b  => $m->{param_b} // 0,
                age_days => $age_days,
            };
        }
    }
    return \@recs;
}

# ------------------------------------------------------- ollama enrichment
# See the "ENRICHMENT" header block above for the full rationale. Returns
# (vision, age_days) for one curated model entry, upgraded from a matching
# Ollama family (never downgraded -- a curated vision=>1, if one is ever
# added, always wins).
sub _enriched {
    my ($m, $enrich) = @_;
    my $vision   = $m->{vision} ? 1 : 0;
    my $age_days = 0;
    if (my $e = $enrich->{ _family_key($m->{model}) }) {
        $vision ||= $e->{vision};
        $age_days = $e->{age_days};
    }
    return ($vision, $age_days);
}

# normalize a model family name for fuzzy cross-catalog matching -- see
# the ENRICHMENT header comment for why this can never be exact. Examples:
# "Meta-Llama-3.1-8B-Instruct" -> "llama3.1", "Qwen2.5-7B-Instruct" ->
# "qwen2.5", "Mistral-7B-Instruct-v0.3" -> "mistral",
# "Phi-3.5-mini-instruct" -> "phi3.5". Ollama's own family names (e.g.
# "llama3.1", "llama3.2-vision") are normalized the same way so both sides
# compare equal only on a genuine family match -- "llama3.2" (text-only)
# and "llama3.2-vision" normalize to DIFFERENT keys ("llama3.2" vs
# "llama3.2vision"), so a text-only curated entry can't accidentally
# inherit vision=>1 from the vision-tagged sibling family.
sub _family_key {
    my ($s) = @_;
    $s = lc($s // '');
    $s =~ s/^meta[-_]?//;
    $s =~ s/[-_]?instruct.*$//;
    $s =~ s/[-_]?v[\d.]+$//;
    $s =~ s/[-_]?\d+(?:\.\d+)?b(?=[-_]|$)//;
    $s =~ s/[-_]?mini$//;
    $s =~ s/[^a-z0-9.]//g;
    return $s;
}

# best-effort family-key => {vision, age_days} map built from a SIBLING
# ollama-library.pl's own --cached-only output (never triggers a live
# ollama.com fetch -- see ENRICHMENT header comment). Returns {} (silently)
# if the sibling script is missing, its cache is empty, or anything about
# the call fails -- enrichment is opportunistic, never fatal to the Llama
# catalog build.
#
# Deliberately does NOT pass --list: ollama-library.pl's own cache-read
# short-circuit is skipped whenever --list is set (verified live -- --list
# --cached-only always returns empty, even with a fresh full-catalog cache
# on disk, because --list's family-collapsed shape isn't what gets
# cached), so --list here would silently defeat --cached-only every time.
# Fetching the full per-tag catalog instead (same invocation shape as
# ai_ollama_catalog() in aihelplib.pl) and collapsing it to per-family
# vision/age here works with the cache as actually written.
sub _ollama_family_map {
    my %map;
    my $sibling = File::Spec_join(dirname($0), 'ollama-library.pl');
    return \%map unless -f $sibling;
    my $out = eval {
        my @cmd = ($^X, $sibling, '--json', '--cache', '0', '--cached-only');
        if ($^O =~ /MSWin/i) {
            my @q = map { my $a = $_; $a =~ s/"/\\"/g; qq{"$a"} } @cmd;
            return `@{[join(' ', @q)]} 2>NUL`;
        } else {
            my @q = map { my $a = $_; $a =~ s/'/'\\''/g; "'$a'" } @cmd;
            return `@{[join(' ', @q)]} 2>/dev/null`;
        }
    };
    return \%map unless $out;
    my $data = eval { decode_json($out) };
    return \%map unless $data && ref($data->{records}) eq 'ARRAY';
    # collapse per-tag records to one entry per family: vision if ANY tag
    # of that family has image input, age_days = the MINIMUM across its
    # tags (the most-recently-touched tag is the best "how new" signal).
    for my $r (@{$data->{records}}) {
        my $key = _family_key($r->{model} // '');
        next if $key eq '';
        my $vision = (ref($r->{input}) eq 'ARRAY' && grep { $_ eq 'image' } @{$r->{input}}) ? 1 : 0;
        my $age    = $r->{age_days} // 0;
        if (my $e = $map{$key}) {
            $e->{vision} ||= $vision;
            $e->{age_days} = $age if $age > 0 && ($e->{age_days} == 0 || $age < $e->{age_days});
        } else {
            $map{$key} = { vision => $vision, age_days => $age };
        }
    }
    return \%map;
}

# tiny helper so this file doesn't need "use File::Spec" just for one join
sub File::Spec_join { my ($d, $f) = @_; return ($d eq '' || $d eq '.') ? $f : "$d/$f"; }
