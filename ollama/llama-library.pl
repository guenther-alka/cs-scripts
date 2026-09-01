#!/usr/bin/env perl
#
# ============================================================================
#  llama-library.pl -- Llama-cpp (GGUF) model catalog
#
#  Unlike ollama-library.pl (which scrapes the live ollama.com/library
#  pages), there is no single official "GGUF library" website -- GGUF
#  quantizations are published as individual HuggingFace repos by various
#  quantizers. This script builds the catalog live from the HuggingFace
#  Hub API, mirroring https://huggingface.co/models?inference_provider=all
#  &base_model_relation=base&sort=downloads (Gea, cs_rc_26.09.02, "llama
#  catalog taugt nicht, kein abgleich mit ollama vornehmen sondern aus
#  huggingface.co ... extrahieren mit hardware, vision, size etc"):
#  it queries the Hub's models API for GGUF repos sorted by downloads
#  (api equivalent of that page), keeps repos that declare a base_model
#  relation (i.e. are a quantization OF a base model -- the api filter
#  string base_model:relation:base is not honoured server-side for the
#  "gguf" tag, so this is applied client-side), and reads hardware
#  (param size / download size per quant), vision capability and age
#  DIRECTLY off each kept repo (file listing + tags + base model's own
#  metadata) -- no cross-referencing against the Ollama catalog anymore.
#
#  MAINTENANCE: nothing to hand-maintain -- the catalog is rebuilt from
#  HuggingFace on every --refresh. If HuggingFace's API shape changes,
#  fix the fetch/parse internals below the CONTRACT section.
#
#  ==========================================================================
#  CONTRACT cs-llama-catalog-v1  (STABLE -- see below)
#  ==========================================================================
#  This header section defines the ONLY stable interface. The calling
#  application may rely on it. Everything BELOW the header (fetch/parse
#  internals) may change when the HuggingFace API changes -- the contract
#  must stay identical.
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
#        "model":   "Qwen3.8-27B",              # model family name
#        "tag":     "Qwen3.8-27B-Q4_K_M",        # display tag (no .gguf)
#        "file":    "Qwen3.8-27B-Q4_K_M.gguf",   # target filename (this is
#                                                 # what ends up in
#                                                 # /root/models/ on the member)
#        "url":     "https://huggingface.co/.../resolve/main/....gguf",
#        "size_gb": 16.8,                # real download size (GB), from the
#                                         # repo's own file listing
#        "context": 32768,               # context window (tokens, 0=unknown,
#                                         # best-effort from the base model's
#                                         # own config.json)
#        "input":   ["text"],            # input modalities -- "image" added
#                                         # when the repo ships an mmproj
#                                         # (llama.cpp multimodal projector)
#                                         # file, a direct on-repo signal
#        "quant":   "Q4_K_M",             # quantization
#        "param_b": 27,                   # parameter size in billions
#        "age_days": 19 } ] }             # real age since the repo's
#                                          # lastModified date on HuggingFace
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
#    (--newer is accepted for CLI symmetry with ollama-library.pl and DOES
#    apply here now, unlike the old curated table -- age_days is real.)
#
#  Caching:
#    Cache file: $CS_SCRIPTS_CACHE or ~/.cache/cs-scripts/llama-library.json
#    Default TTL 30 days (--cache SECS to override, --cache 0 = never
#    expire / manual --refresh only, --refresh forces a rebuild now).
#
#  DATA QUALITY NOTE: the calling GUI should show that catalog entries are
#  live HuggingFace data (hardware/vision/size read directly off each
#  repo), same as the Ollama catalog panel next to it -- no heuristic
#  cross-catalog matching is involved anymore, so no extra disclaimer is
#  needed here beyond what the Ollama panel already shows.
# ============================================================================
use strict;
use warnings;
use Getopt::Long qw(:config bundling no_ignore_case);
use JSON::PP;
use File::Path qw(make_path);
use File::Basename;

our $CONTRACT = 'cs-llama-catalog-v1';
our $VERSION  = '2.0';

# skip repos whose id/tags suggest they are not general-purpose base-model
# quantizations we want to default-list in an admin picker (embeddings/
# ASR/TTS repos that also happen to carry a "gguf" tag, and finetunes
# explicitly marketed as uncensored/abliterated -- keep the catalog to
# well-behaved general chat/instruct models by default).
my $SKIP_ID_RE = qr/uncensor|abliterat|nsfw|explicit|erotic|heretic|-i2v-|-t2v-|text-to-video|whisper|[-_]tts[-_]|automatic-speech|classif|privacy-filter|upscal|rerank|embed|^ced[-_]|VibeVoice/i;
my $SKIP_TAG_RE = qr/^(?:feature-extraction|sentence-similarity|automatic-speech-recognition|text-to-speech|text-to-image)$/;

# preferred quantizer authors -- when several repos quantize the same base
# model, keep the one from a well-known/consistently-tagged quantizer.
my @PREFERRED_AUTHORS = qw(bartowski unsloth lmstudio-community mradermacher TheBloke);

# when required as a library (tests/embedding), skip the CLI main
return 1 if caller;

# ---------------------------------------------------------------- defaults
my %opt = (
    cache   => 2592000,      # 30 days
    json    => 1,
    timeout => 20,
    fetch_n => 100,          # raw HF repos fetched before filtering
    max_families => 24,      # kept model families in the final catalog
);

GetOptions(
    'list'       => \$opt{list},
    'tags'       => \$opt{tags},
    'model=s'    => \$opt{model},
    'json'       => \$opt{json},
    'tsv'        => sub { $opt{json} = 0; $opt{tsv} = 1; },
    'vision'     => \$opt{vision},
    'newer=i'    => \$opt{newer},
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
  --newer N                   only <= N*30 days old
  --param-max B               only <= B billion parameters
  --size-max GB               only <= GB download size
  --cache SECS                cache TTL (0 = never expire, manual rebuild
                              only; default 2592000 = 30 days)
  --refresh                   rebuild the catalog live from HuggingFace
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
if (defined $opt{newer} && $opt{newer} > 0) {
    my $max_age = $opt{newer} * 30;
    @recs = grep { my $a = $_->{age_days}; defined($a) && $a >= 0 && $a <= $max_age } @recs;
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
    my $d; eval { $d = decode_json($c) };
    return $d;
}
sub write_json_file {
    my ($f, $d) = @_;
    open my $fh, '>', $f or return;
    print $fh encode_json($d); close $fh;
}

# -------------------------------------------------------------------- fetch
sub http_get {
    my ($url) = @_;
    my $devnull = ($^O =~ /MSWin/i) ? 'NUL' : '/dev/null';
    my $out;
    if ($^O =~ /MSWin/i) {
        my $q = $url; $q =~ s/"/\\"/g;
        $out = `curl -fsSL --max-time $opt{timeout} "$q" 2>$devnull`;
    } else {
        my $q = $url; $q =~ s/'/'\\''/g;
        $out = `curl -fsSL --max-time $opt{timeout} '$q' 2>$devnull`;
    }
    return defined($out) && $out ne '' ? $out : undef;
}

# ============================================================================
#  BELOW: fetch/parse internals -- may change when the HuggingFace API
#  changes. The CONTRACT above is the only stable interface.
# ============================================================================

sub build_model_list {
    my $full = build_full_catalog();
    my %seen; my @out;
    for my $r (@$full) {
        next if $seen{$r->{model}}++;
        push @out, { model => $r->{model}, tag => '', file => '', url => '',
            size_gb => 0, context => 0, input => [], quant => '', param_b => 0,
            age_days => $r->{age_days} };
    }
    return \@out;
}

sub build_full_catalog {
    my $raw = http_get('https://huggingface.co/api/models?filter=gguf&sort=downloads'
        . "&direction=-1&limit=$opt{fetch_n}&full=true");
    return [] unless defined $raw;
    my $repos; eval { $repos = decode_json($raw) };
    return [] unless ref($repos) eq 'ARRAY';

    my %by_family;   # base-model-family => chosen repo entry
    for my $rep (@$repos) {
        my $id = $rep->{id} // next;
        next if $id =~ $SKIP_ID_RE;
        my $ptag = $rep->{pipeline_tag} // '';
        next if $ptag ne '' && $ptag =~ $SKIP_TAG_RE;

        my ($base) = map { /^base_model:(?!quantized:)(.+)$/ ? $1 : () } @{ $rep->{tags} // [] };
        next unless defined $base && $base ne '';   # keep only quantizations
                                                      # OF a base model (api
                                                      # equivalent of the GUI
                                                      # filter base_model_
                                                      # relation=base)

        my $family = $base; $family =~ s{^.*/}{};    # drop the "author/" prefix
        my ($author) = split m{/}, $id, 2;
        my $existing = $by_family{$family};
        if ($existing) {
            my $existing_pref = grep { $_ eq $existing->{author} } @PREFERRED_AUTHORS;
            my $this_pref     = grep { $_ eq $author } @PREFERRED_AUTHORS;
            next if $existing_pref && !$this_pref;                 # keep the preferred one
            next if $existing_pref == $this_pref
                 && ($existing->{downloads} // 0) >= ($rep->{downloads} // 0); # else higher downloads wins
        }
        $by_family{$family} = { id => $id, author => $author, base => $base,
            downloads => $rep->{downloads} // 0, lastModified => $rep->{lastModified} // '' };
    }

    # highest-downloads families first, capped
    my @families = sort { $by_family{$b}{downloads} <=> $by_family{$a}{downloads} } keys %by_family;
    @families = @families[0 .. $opt{max_families} - 1] if @families > $opt{max_families};

    my @out;
    my %ctx_cache;   # base model id => context window (avoid duplicate fetches)
    for my $family (@families) {
        my $rep = $by_family{$family};
        my $recs = build_family_records($family, $rep, \%ctx_cache);
        push @out, @$recs if @$recs;
    }
    return \@out;
}

sub build_family_records {
    my ($family, $rep, $ctx_cache) = @_;
    my $id = $rep->{id};
    my $enc_id = $id; $enc_id =~ s{ }{%20}g;
    my $raw = http_get("https://huggingface.co/api/models/$enc_id?blobs=true");
    return [] unless defined $raw;
    my $info; eval { $info = decode_json($raw) };
    return [] unless ref($info) eq 'HASH';
    my @sibs = ref($info->{siblings}) eq 'ARRAY' ? @{ $info->{siblings} } : ();

    my $has_mmproj = (grep { ($_->{rfilename} // '') =~ /mmproj/i } @sibs) ? 1 : 0;
    my $param_b = param_from_name($id) || param_from_name($rep->{base}) || 0;
    my $age_days = age_days_from_iso($rep->{lastModified});

    my $context = 0;
    if (exists $ctx_cache->{ $rep->{base} }) {
        $context = $ctx_cache->{ $rep->{base} };
    } else {
        $context = fetch_context_window($rep->{base}) // 0;
        $ctx_cache->{ $rep->{base} } = $context;
    }

    my @out;
    for my $s (@sibs) {
        my $fn = $s->{rfilename} // next;
        next unless $fn =~ /\.gguf$/i;
        next if $fn =~ m{/};              # skip split/subfolder parts (BF16/..., 00001-of-...)
        next if $fn =~ /mmproj/i;         # projector file, not a selectable quant
        next unless $fn =~ /-((?:IQ\d[A-Z0-9_]*|Q\d(?:_[A-Z0-9]+)*|BF16|F16|F32))\.gguf$/i;
        my $quant = $1;
        my $tag  = $fn; $tag =~ s/\.gguf$//i;
        my $size_gb = $s->{size} ? sprintf('%.2f', $s->{size} / 1_000_000_000) + 0 : 0;
        push @out, {
            model => $family, tag => $tag, file => $fn,
            url => "https://huggingface.co/$id/resolve/main/$fn",
            size_gb => $size_gb, context => $context,
            input => ($has_mmproj ? ['text','image'] : ['text']),
            quant => $quant, param_b => $param_b, age_days => $age_days,
        };
    }
    return \@out;
}

sub param_from_name {
    my ($s) = @_;
    return 0 unless defined $s && $s ne '';
    return $1 + 0 if $s =~ /[-_\/](\d+(?:\.\d+)?)B(?:[-_.]|$)/i;
    return 0;
}

sub age_days_from_iso {
    my ($iso) = @_;
    return 0 unless defined $iso && $iso =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/;
    my ($y,$mo,$d,$h,$mi,$se) = ($1,$2,$3,$4,$5,$6);
    my $then = eval {
        require Time::Local;
        Time::Local::timegm($se,$mi,$h,$d,$mo-1,$y);
    };
    return 0 unless defined $then;
    my $days = int((time() - $then) / 86400);
    return $days > 0 ? $days : 0;
}

# best-effort: read the base model's own config.json for its context window.
# Failure (private/gated repo, no config.json, network hiccup) yields undef
# and the caller falls back to 0 (unknown) -- same "0=unknown" contract as
# before, but now a real attempt instead of a borrowed Ollama value.
sub fetch_context_window {
    my ($base) = @_;
    return undef unless defined $base && $base ne '';
    my $enc = $base; $enc =~ s{ }{%20}g;
    my $raw = http_get("https://huggingface.co/$enc/raw/main/config.json");
    return undef unless defined $raw;
    my $cfg; eval { $cfg = decode_json($raw) };
    return undef unless ref($cfg) eq 'HASH';
    for my $k (qw(max_position_embeddings n_positions max_sequence_length seq_length)) {
        return $cfg->{$k} + 0 if defined $cfg->{$k} && $cfg->{$k} =~ /^\d+$/;
    }
    return undef;
}
