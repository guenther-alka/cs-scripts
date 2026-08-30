#!/usr/bin/env perl
#
# ============================================================================
#  ollama-library.pl -- Ollama library catalog parser
#
#  Reads the public Ollama model library (ollama.com/library) via curl and
#  returns the complete model/tag catalog on demand: model names, per-tag
#  download size, context window, input capabilities (text/image) and
#  quantization -- so a GUI can offer a filtered model selection for
#  `ollama pull`.
#
#  ==========================================================================
#  CONTRACT cs-ollama-catalog-v1  (STABLE -- see below)
#  ==========================================================================
#  This header section defines the ONLY stable interface. The calling
#  application may rely on it. Everything BELOW the header (fetch/parse
#  internals) may change when Ollama changes its website markup -- the
#  contract below must stay identical.
#
#  Usage:
#    ollama-library.pl --list [--json|--tsv]
#    ollama-library.pl [--tags] [--model NAME] [--json|--tsv]
#                      [--vision] [--newer MONTHS] [--param-max B]
#                      [--size-max GB] [--cache SECS] [--refresh]
#    ollama-library.pl --version
#    ollama-library.pl --help
#
#  Output schema (--json, one object per tag):
#    { "contract": "cs-ollama-catalog-v1",
#      "count": N,
#      "cached": 0|1,
#      "records": [ {
#        "model":   "llama3.2-vision",     # model family name
#        "tag":     "llama3.2-vision:11b-instruct-q4_K_M",
#        "size_gb": 7.8,                    # download size (approx GB)
#        "context": 128000,                 # context window (tokens, 0=unknown)
#        "input":   ["text","image"],       # input modalities
#        "quant":   "q4_K_M",               # quantization (from tag name, '' if unknown)
#        "param_b": 11,                     # parameter size in billions
#        "age_days": 300 } ] }              # approx age in days (relative page dates)
#
#  --list: records without per-tag fields (size_gb/context/input/quant/param_b
#          are 0/'' there); one record per MODEL family.
#  TSV:    header line + one line per record (fields in the same order).
#
#  Filters are applied on the (cached) catalog at query time:
#    --vision       keep only records with "image" in input
#    --newer N      keep only records with age_days <= N*30 (approximate)
#    --param-max B  keep only records with 0 < param_b <= B
#    --size-max GB  keep only records with size_gb > 0 and <= GB
#
#  Caching:
#    The full catalog is cached locally (default TTL 30 days, --cache SECS
#    to override, --refresh to rebuild). Cache file:
#    $CS_SCRIPTS_CACHE or ~/.cache/cs-scripts/ollama-library.json
# ============================================================================
use strict;
use warnings;
use Getopt::Long qw(:config bundling no_ignore_case);
use JSON::PP;
use File::Path qw(make_path);
use File::Basename;

our $CONTRACT = 'cs-ollama-catalog-v1';
our $VERSION  = '1.0';

# when required as a library (tests/embedding), skip the CLI main
return 1 if caller;

# ---------------------------------------------------------------- defaults
my %opt = (
    cache => 2592000,      # 30 days
    timeout => 20,         # per-request curl timeout (sec)
    max_models => 0,       # 0 = unlimited (debug/testing aid)
    json => 1,
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
    'timeout=i'  => \$opt{timeout},
    'max-models=i' => \$opt{max_models},
    'version'    => \$opt{version},
    'help'       => \$opt{help},
) or exit 1;


if ($opt{help})    { print <<HELP; exit 0; }
ollama-library.pl  (contract $CONTRACT, script $VERSION)

Usage:
  --list                      list model families (no per-tag fields)
  --tags                      per-tag catalog (default)
  --model NAME                only this model family
  --json                      JSON output (default)
  --tsv                       tab-separated output
  --vision                    only vision-capable tags
  --newer MONTHS              only updated within MONTHS (approximate)
  --param-max B               only <= B billion parameters
  --size-max GB               only <= GB download size
  --cache SECS                catalog cache TTL (default 2592000 = 30 days)
  --refresh                   rebuild the catalog (ignore cache)
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
    $opt{cached} = 0;
    $records = $opt{list} ? build_model_list() : build_full_catalog();
    if (!$opt{list} && @$records) {
        make_path(dirname($cache_file)) unless -d dirname($cache_file);
        write_json_file($cache_file, { contract => $CONTRACT, built => time(), records => $records });
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
    @recs = grep { ($_->{age_days} // 0) <= $max_age } @recs;
}
if (defined $opt{param_max} && $opt{param_max} > 0) {
    @recs = grep { my $p = $_->{param_b} // 0; $p > 0 && $p <= $opt{param_max} } @recs;
}
if (defined $opt{size_max} && $opt{size_max} > 0) {
    @recs = grep { my $s = $_->{size_gb} // 0; $s > 0 && $s <= $opt{size_max} } @recs;
}

# ------------------------------------------------------------------- output
if ($opt{tsv}) {
    print join("\t", qw(model tag size_gb context input quant param_b age_days)), "\n";
    for my $r (@recs) {
        my $in = ref($r->{input}) eq 'ARRAY' ? join(',', @{$r->{input}}) : '';
        print join("\t", $r->{model} // '', $r->{tag} // '', $r->{size_gb} // '',
            $r->{context} // '', $in, $r->{quant} // '', $r->{param_b} // '',
            $r->{age_days} // ''), "\n";
    }
} else {
    print encode_json({ contract => $CONTRACT, count => scalar(@recs),
        cached => $opt{cached} ? 1 : 0, records => \@recs }), "\n";
}
exit 0;

# ------------------------------------------------------------------- caching
sub cache_file {
    my $base = $ENV{CS_SCRIPTS_CACHE} // '';
    $base = "$ENV{HOME}/.cache/cs-scripts" if $base eq '';
    return "$base/ollama-library.json";
}
sub cache_fresh {
    my ($f, $ttl) = @_;
    my @st = stat($f);
    return @st && (time() - $st[9]) <= $ttl;
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

# ------------------------------------------------------------------ library
sub build_model_list {
    my $html = http_get('https://ollama.com/library');
    return [] unless defined $html;
    my $models = parse_library_page($html);
    my @recs;
    for my $m (@$models) {
        push @recs, {
            model    => $m->{name},
            tag      => $m->{name},
            size_gb  => 0,
            context  => 0,
            input    => [ $m->{caps}{vision} ? ('text', 'image') : ('text') ],
            quant    => '',
            param_b  => @{$m->{params}} ? $m->{params}[0] : 0,
            age_days => $m->{age_days} // 0,
        };
    }
    return \@recs;
}

sub build_full_catalog {
    my $html = http_get('https://ollama.com/library');
    return [] unless defined $html;
    my $models = parse_library_page($html);
    my @recs;
    my $count = 0;
    for my $m (@$models) {
        next if $opt{model} && $m->{name} ne $opt{model};
        last if $opt{max_models} && ++$count > $opt{max_models};
        print STDERR "  [$m->{name}] fetching tags...\n";
        my $tags_html = http_get("https://ollama.com/library/$m->{name}/tags");
        next unless defined $tags_html;
        my $tags = parse_tags_page($tags_html);
        if (!@$tags) {
            push @recs, {
                model => $m->{name}, tag => $m->{name}, size_gb => 0, context => 0,
                input => [ $m->{caps}{vision} ? ('text', 'image') : ('text') ],
                quant => '', param_b => @{$m->{params}} ? $m->{params}[0] : 0,
                age_days => $m->{age_days} // 0,
            };
            next;
        }
        for my $t (@$tags) {
            push @recs, {
                model    => $m->{name},
                tag      => $t->{tag},
                size_gb  => $t->{size_gb} // 0,
                context  => $t->{context} // 0,
                input    => $t->{input} || ['text'],
                quant    => $t->{quant} // '',
                param_b  => ($t->{param_b} // 0) || (@{$m->{params}} ? $m->{params}[0] : 0),
                age_days => ($t->{age_days} // 0) || ($m->{age_days} // 0),
            };
        }
    }
    return \@recs;
}

# split the library list page into model cards and extract per-model info
sub parse_library_page {
    my ($html) = @_;
    my @models;
    my @cards = split(m{<a href="/library/([^"/]+)" class="group w-full space-y-5">}, $html);
    for (my $i = 1; $i < @cards; $i += 2) {
        my $name = $cards[$i];
        my $body = $cards[$i + 1] // '';
        next if $name eq '';
        my %caps;
        while ($body =~ m{<span[^>]*text-indigo-600[^>]*>\s*([a-z]+)\s*</span>}g) {
            $caps{lc($1)} = 1;
        }
        my @params;
        while ($body =~ m{<span[^>]*text-blue-600[^>]*>\s*([0-9.]+)b\s*</span>}g) {
            my $p = $1; $p =~ s/\.0$//;
            push @params, $p + 0;
        }
        my $age_days = 0;
        if ($body =~ /Updated&nbsp;<\/span>\s*<span\s*>\s*([^<]+?)\s*<\/span>/s) {
            $age_days = age_to_days($1);
        }
        push @models, { name => $name, caps => \%caps, params => \@params, age_days => $age_days };
    }
    return \@models;
}

# parse a model's /tags page into per-tag records
sub parse_tags_page {
    my ($html) = @_;
    my @tags;
    my %seen;
    my @blocks = split(m{<span class="group-hover:underline">([^<]+)</span>}, $html);
    for (my $i = 1; $i < @blocks; $i += 2) {
        my $tag  = $blocks[$i];
        my $body = $blocks[$i + 1] // '';
        next if $tag eq '' || $seen{$tag}++;
        my $size_gb = 0;
        if ($body =~ /([0-9.]+)\s*(GB|MB)/i) {
            # copy the captures FIRST -- a regex inside the ternary below
            # would clobber $1/$2 of this outer match (perl capture gotcha)
            my ($num, $unit) = ($1, $2);
            $size_gb = (uc($unit) eq 'GB') ? $num + 0 : $num / 1024;
        }
        my $context = 0;
        if ($body =~ /([0-9.]+)\s*(K|M)?\s*context\s*window/i) {
            my $n = $1 + 0; my $u = $2 || '';
            $context = $u =~ /M/i ? int($n * 1000000) : $u =~ /K/i ? int($n * 1000) : int($n);
        }
        my @input;
        if ($body =~ /([A-Za-z]+(?:\s*,\s*[A-Za-z]+)?)\s+input/i) {
            @input = map { lc($_) } split(/\s*,\s*/, $1);
        }
        my $age_days = 0;
        if ($body =~ /(\d+\s+(?:years?|months?|weeks?|days?)\s+ago|yesterday|today)/i) {
            $age_days = age_to_days($1);
        }
        push @tags, {
            tag      => $tag,
            size_gb  => $size_gb,
            context  => $context,
            input    => \@input,
            quant    => quant_from_tag($tag),
            param_b  => param_from_tag($tag),
            age_days => $age_days,
        };
    }
    return \@tags;
}

# ------------------------------------------------------------- small helpers
sub age_to_days {
    my ($s) = @_;
    $s = lc($s // '');
    return 0 if $s =~ /today|now|an?\s+hour/;
    return 1 if $s =~ /yesterday/;
    my ($n, $unit) = $s =~ /(\d+)\s*(year|month|week|day)s?\s+ago/;
    return 0 unless defined $n;
    return int($n * 365) if $unit eq 'year';
    return int($n * 30)  if $unit eq 'month';
    return int($n * 7)   if $unit eq 'week';
    return int($n)       if $unit eq 'day';
    return 0;
}

sub quant_from_tag {
    my ($tag) = @_;
    return $1 if $tag =~ /[-_:](q\d+(?:_[A-Z0-9_]+)+)$/i;
    return lc($1) if $tag =~ /[-_:](fp16|bf16|f16|f32)$/i;
    return $1 if $tag =~ /[-_:](q\d+_\d+)$/i;
    return '';
}

sub param_from_tag {
    my ($tag) = @_;
    return $1 + 0 if $tag =~ /:(\d+(?:\.\d+)?)b?[\-_]/i;
    return $1 + 0 if $tag =~ /:(\d+(?:\.\d+)?)b?$/i;
    return 0;
}

    print $fh encode_json($d); close $fh;
}

# -------------------------------------------------------------------- fetch
sub http_get {
    my ($url) = @_;
    my $devnull = ($^O =~ /MSWin/i) ? 'NUL' : '/dev/null';
    my $out;
    if ($^O =~ /MSWin/i) {
        # Windows cmd: double quotes only, no /dev/null
        my $q = $url; $q =~ s/"/\\"/g;
        $out = `curl -fsSL --max-time $opt{timeout} "$q" 2>$devnull`;
    } else {
        # POSIX sh: single quotes, /dev/null
        my $q = $url; $q =~ s/'/'\\''/g;
        $out = `curl -fsSL --max-time $opt{timeout} '$q' 2>$devnull`;
    }
    return defined($out) && $out ne '' ? $out : undef;
}

# ============================================================================
#  BELOW: fetch/parse internals -- may change when ollama.com changes markup.
#  The CONTRACT above is the only stable interface.
# ============================================================================
