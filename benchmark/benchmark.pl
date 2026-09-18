#!/usr/bin/perl
# =============================================================================
# benchmark_worker.pl -- member-side measurement worker (pool benchmark)
# -----------------------------------------------------------------------------
# Runs ON A MEMBER as root/admin, detached. Started by benchmark_director.pl on
# the frontend via  &socket("perl <member_tmp>/benchmark_worker.pl <runid>", ip)
# -> server.pl's background() makes it a detached root process (server.pl itself
#    stays free; it is SYNCHRONOUS and must never run a 1..30 min command).
#
# USAGE
#   perl benchmark_worker.pl <runid> [key=value ...]
#   keys (argv overrides the parameter file):
#     profile=quick|basic|database|fileserver|mediaserver|mailserver|individual
#     pool=<zpool name>                (default: first pool from zpool list)
#     streams=1|5|auto                 (default: auto, capped by vCPU count)
#     load=readheavy|writeheavy|balanced
#     filesize_ram=<percent>           (only honoured for profile=individual)
#     four_k=yes|no   syncwrite=yes|no   mixed=yes|no   steady=yes|no
#     steady_min=<minutes>             (default 30)
#     rundir=<dir>                     (default: directory of this script)
#
# STANDALONE USE -- no napp-it frontend required, e.g. on foreign hardware
# (TrueNAS CORE/SCALE, plain FreeBSD, any ZFS host):
#     perl benchmark_worker.pl profile=quick pool=tank
#   Without a runid argument the id is generated as auto_YYYYMMDD_HHMMSS (so the
#   scratch dataset gets a valid name), the log/marker land next to THIS script
#   (override with rundir=/tmp), and only zfs/zpool/df/uptime/smartctl are used.
#   This file is published from the cs-scripts repo as benchmark/benchmark.pl --
#   keep the napp-it copy (data/menues/_lib/scripts/bench/benchmark_worker.pl)
#   and that one identical when changing either.
#
# FILES (all in the SAME directory this script was deployed to = member $tpath)
#   benchmark_<runid>.par     parameters (written by the director, optional)
#   last_benchmark.log        THE RESULT (truncated per run):
#                               header lines  "bench_hdr: key=value ..."
#                               sample lines  "t=..s cum=..GB write=..MB/s ..."
#                               result lines  "RESULT <name>=<value> <unit>"
#                               last line     "BENCH_DONE ok|error <reason>"
#   benchmark.running         fixed-name marker = only ONE benchmark per member;
#                             present  -> print "already running" and exit
#   benchmark_<runid>.cancel  sentinel: checked between phases -> clean stop
#   benchmark_<runid>.tmp*    scratch files (removed at the end)
#
# TEST MEDIUM
#   Preferred: a freshly created scratch DATASET on the pool under test
#     zfs create -o sync=always|standard -o primarycache=none|all \
#                -o secondarycache=none -o compression=off -o atime=off \
#                -o mountpoint=<mnt> <pool>/csbench_<runid>
#   It is ALWAYS destroyed again (END block, also on error/cancel).
#   Fallback when zfs is unavailable (plain drive letter / no privileges):
#   a test FOLDER, and the report marks cache/sync as "n/a".
#
# MEASUREMENT NOTES (all values measured live on this cluster, 2026.09.18)
#   * no O_DIRECT (Perl buffer alignment) -> cache bypass via primarycache=none
#   * sync writes via ZFS sync=always (POSIX::fsync is not available)
#   * async write numbers are a CACHE indicator (measured: 1358 vs 136 MB/s)
#   * 4k random read in Perl: ~141k IOPS ceiling at 1 vCPU, ~168k on .50
#     -> results are flagged storage-bound | cache | tool-limited(CPU)
#   * concurrency uses threads (the project loads 'threads' on every platform)
#   * a mirror already splits a single stream over both disks -> the 1-vs-N
#     stream ratio is NOT expected to be N; it is reported, not promised.
# =============================================================================

use strict;
use warnings;
use English qw( -no_match_vars );
use Time::HiRes qw(time);
use Fcntl qw(O_WRONLY O_CREAT O_TRUNC);
use File::Basename qw(dirname);
use File::Spec;
use POSIX qw(strftime);

$| = 1;

my $OSISWIN = ($OSNAME =~ /MSWin/i) ? 1 : 0;

# ---- where am I? (capture BEFORE this script deletes itself) -----------------
my $SELF  = $PROGRAM_NAME;
my $TPATH = dirname($SELF);
my $LOG   = File::Spec->catfile($TPATH, 'last_benchmark.log');
my $RUNM  = File::Spec->catfile($TPATH, 'benchmark.running');

# The first argument is either a runid (the director passes one) OR already a
# key=value pair.  Standalone use on foreign hardware looks exactly like this:
#     perl benchmark_worker.pl profile=quick pool=tank
# A key=value string must NEVER become the runid -- it would be used in the ZFS
# dataset name ("csbench_profile=quick" is an invalid dataset name and would
# silently drop the run into the folder fallback).
my $ARGV0 = shift @ARGV;
my $RUNID;
if (defined $ARGV0 && $ARGV0 =~ /^[A-Za-z0-9_.-]+$/) {
    $RUNID = $ARGV0;
} else {
    unshift @ARGV, $ARGV0 if defined $ARGV0;
    $RUNID = 'auto_' . strftime('%Y%m%d_%H%M%S', localtime);
}
my $CANCEL = File::Spec->catfile($TPATH, "benchmark_${RUNID}.cancel");
my $PAR    = File::Spec->catfile($TPATH, "benchmark_${RUNID}.par");

# ---- parameters: .par file first, argv wins ---------------------------------
my %P = ();
if (-f $PAR) {
    if (open(my $pf, '<', $PAR)) {
        while (my $l = <$pf>) {
            chomp $l; $l =~ s/^\s+|\s+$//g;
            next if $l eq '' || $l =~ /^#/;
            my ($k, $v) = split(/\s*=\s*/, $l, 2);
            $P{$k} = $v if defined $k && defined $v;
        }
        close $pf;
    }
}
for my $a (@ARGV) {
    my ($k, $v) = split(/=/, $a, 2);
    $P{$k} = $v if defined $k && defined $v;
}

# ---- usage / help -----------------------------------------------------------
if (($P{help} // '') =~ /^y/i) {
    print <<"USAGE";
benchmark_worker.pl -- ZFS pool benchmark, runs ON the machine under test.
  usage:  perl benchmark_worker.pl [runid] [key=value ...]
  keys:   profile=quick|basic|database|fileserver|mediaserver|mailserver|individual
          pool=<zpool>        (default: first pool of 'zpool list')
          streams=1|5|auto    (default auto, capped by the vCPU count)
          load=readheavy|writeheavy|balanced
          four_k=yes|no   write=yes|no   syncwrite=yes|no
          mixed=yes|no    multiuser=yes|no
          steady=yes|no   steady_min=30  steady_interval=30
          filesize_ram=<percent of RAM>   (honoured for profile=individual only)
          rundir=<dir>        (default: the directory this script lives in)
          verbose=yes
  result: <rundir>/last_benchmark.log
          bench_hdr lines (all parameters) + RESULT lines + BENCH_DONE ok|error
  notes:  the test medium is a scratch DATASET on the pool under test which is
          created and destroyed again automatically (primarycache=metadata,
          sync=always for the sync-write phase).  Fallback: a test folder.
USAGE
    exit 0;
}

# ---- output directory (standalone / foreign hardware) -----------------------
# The script may live on a read-only mount (e.g. /root on an appliance), so the
# log/marker location is overridable and falls back to a writable place.
if (($P{rundir} // '') =~ /\S/) {
    my $rd = $P{rundir};
    mkdir $rd unless -d $rd;
    if (-d $rd && -w $rd) {
        $TPATH  = $rd;
        $LOG    = File::Spec->catfile($TPATH, 'last_benchmark.log');
        $RUNM   = File::Spec->catfile($TPATH, 'benchmark.running');
        $CANCEL = File::Spec->catfile($TPATH, "benchmark_${RUNID}.cancel");
    } else {
        warn "rundir=$rd not usable -- keeping $TPATH\n";
    }
}
unless (-d $TPATH && -w $TPATH) {
    my $fb = ($OSISWIN ? ($ENV{TEMP} // 'C:\\Windows\\Temp') : '/tmp');
    if (-d $fb && -w $fb) {
        warn "$TPATH not writable -- using $fb\n";
        $TPATH  = $fb;
        $LOG    = File::Spec->catfile($TPATH, 'last_benchmark.log');
        $RUNM   = File::Spec->catfile($TPATH, 'benchmark.running');
        $CANCEL = File::Spec->catfile($TPATH, "benchmark_${RUNID}.cancel");
    }
}

# ---- environment -------------------------------------------------------------
sub _env_cpus {
    my $n = 0;
    if ($OSISWIN) { $n = $ENV{NUMBER_OF_PROCESSORS} // 0; }
    else {
        # order matters for foreign systems: nproc (Linux), sysctl hw.ncpu
        # (FreeBSD/macOS/TrueNAS CORE), psrinfo (Solaris/illumos),
        # getconf (last resort, POSIX).
        $n = $1 if `nproc 2>/dev/null` =~ /^(\d+)/;
        $n ||= $1 if `sysctl -n hw.ncpu 2>/dev/null` =~ /^(\d+)/;
        $n ||= scalar(grep { /\S/ } `psrinfo 2>/dev/null`);
        $n ||= $1 if `getconf _NPROCESSORS_ONLN 2>/dev/null` =~ /^(\d+)/;
    }
    return $n > 0 ? $n : 1;
}
sub _env_ram_gb {
    my ($kb) = (0);
    if ($OSISWIN) {
        my $g = (`wmic ComputerSystem get TotalPhysicalMemory 2>NUL`)[0] // '';
        $kb = int($1 / 1024) if $g =~ /(\d{6,})/;
    } elsif ($OSNAME =~ /solaris|illumos/i) {
        my $m = join('', grep { /Memory size/ } `prtconf 2>/dev/null`);
        $kb = $1 * 1024 if $m =~ /Memory size:\s*(\d+)/;
    } elsif (-r '/proc/meminfo') {
        my $m = (`grep MemTotal /proc/meminfo 2>/dev/null`)[0] // '';
        $kb = $1 if $m =~ /MemTotal:\s*(\d+)/;
    } else {
        # FreeBSD/TrueNAS CORE/macOS: hw.physmem (bytes) / hw.memsize (macOS)
        my $b = $1 if `sysctl -n hw.physmem 2>/dev/null` =~ /^(\d+)/;
        $b ||= $1 if `sysctl -n hw.memsize 2>/dev/null` =~ /^(\d+)/;
        $kb = int($b / 1024) if $b;
    }
    return $kb > 0 ? int($kb / 1048576) : 0;   # GB
}

my $VCPU   = _env_cpus();
my $RAM_GB = _env_ram_gb();

# =============================================================================
# PROFILES -- durations in seconds; streams "auto" = min(vCPU,5), at least 2
# =============================================================================
my %PROFILE = (
    quick       => { p4k => 10, sr => 10, sw => 15, aw => 10, mx => 15, mu => 10, four_k => 1 },
    basic       => { p4k => 20, sr => 20, sw => 25, aw => 15, mx => 25, mu => 20, four_k => 1 },
    database    => { p4k => 30, sr => 10, sw => 20, aw => 10, mx => 20, mu => 20, four_k => 1 },
    fileserver  => { p4k => 30, sr => 30, sw => 20, aw => 15, mx => 30, mu => 20, four_k => 1 },
    mediaserver => { p4k => 10, sr => 45, sw => 20, aw => 20, mx => 20, mu => 15, four_k => 0 },
    mailserver  => { p4k => 15, sr => 15, sw => 45, aw => 10, mx => 25, mu => 20, four_k => 1 },
);
my %PROF_FALLBACK = %{ $PROFILE{basic} };   # 'individual' without explicit keys

my $PROFILE = lc($P{profile} // 'quick');
my %C = %{ $PROFILE{$PROFILE} // \%PROF_FALLBACK };

# load shifts the emphasis (only for non-individual profiles)
my $LOAD = lc($P{load} // 'balanced');
if ($LOAD eq 'readheavy')  { $C{sr} = int($C{sr} * 1.5); $C{sw} = int($C{sw} * 0.6); }
if ($LOAD eq 'writeheavy') { $C{sw} = int($C{sw} * 1.5); $C{aw} = int($C{aw} * 1.5); $C{sr} = int($C{sr} * 0.6); }

my $STREAMS = $P{streams} // 'auto';
$STREAMS = ($VCPU >= 5) ? 5 : ($VCPU >= 2 ? $VCPU : 2) if $STREAMS !~ /^\d+$/;
$STREAMS = 1 if $STREAMS < 1;
my $STREAMS_CLAMPED = ($STREAMS > $VCPU) ? 1 : 0;

my $T_FOUR_K  = (($P{four_k}     // ($C{four_k} ? 'yes' : 'no')) =~ /^y/i) ? 1 : 0;
my $T_SYNC    = (($P{syncwrite}  // 'yes') =~ /^y/i) ? 1 : 0;
my $T_ASYNC   = (($P{write}      // 'yes') =~ /^y/i) ? 1 : 0;
my $T_MIXED   = (($P{mixed}      // 'yes') =~ /^y/i) ? 1 : 0;
my $T_MULTI   = (($P{multiuser}  // 'yes') =~ /^y/i) ? 1 : 0;
my $T_STEADY  = (($P{steady}     // 'no')  =~ /^y/i) ? 1 : 0;
my $STEADY_MIN = $P{steady_min} // 30;
my $STEADY_IV  = $P{steady_interval} // 30;    # 30 s aggregation window (user spec)

my $POOL = $P{pool} // '';

# ---- test file size ----------------------------------------------------------
# filesize_ram is an INDIVIDUAL-only override (% of RAM). Otherwise the size is
# derived from the hardware -- and it no longer has to exceed the ARC, because
# primarycache=none removes the cache from the equation for this dataset.
my $SIZE_PCT = 10;
if ($PROFILE eq 'individual' && defined $P{filesize_ram} && $P{filesize_ram} =~ /^\d+$/) {
    $SIZE_PCT = $P{filesize_ram};
}

# =============================================================================
# LOG
# =============================================================================
my $LOGFH;
sub bench_open {
    open($LOGFH, '>', $LOG) or die "cannot write $LOG: $!\n";
    $LOGFH->autoflush(1);
}
sub blog {
    my ($l) = @_;
    chomp $l;
    print $LOGFH $l, "\n" if $LOGFH;
}
sub bhdr  { my ($k, $v) = @_; blog(sprintf("bench_hdr: %-22s = %s", $k, $v)); }
sub bres  { my ($n, $v, $u) = @_; blog(sprintf("RESULT %-26s = %s %s", $n, $v, $u // '')); }
sub bdone {
    my ($st, $reason) = @_;
    blog(sprintf("BENCH_DONE %s %s", $st, $reason // ''));
}

# =============================================================================
# EXTERNAL TOOLS
# =============================================================================
# smartctl discovery: NOT simply "command -v" -- on OmniOS it lives in
# /opt/ooce/smartmontools/sbin and is absent from PATH (measured 2026.09.18),
# on Windows in "C:\Program Files\smartmontools\bin".
sub find_smartctl {
    my @cand = $OSISWIN
        ? ("C:\\Program Files\\smartmontools\\bin\\smartctl.exe",
           "C:\\Program Files (x86)\\smartmontools\\bin\\smartctl.exe")
        : ("/usr/sbin/smartctl", "/usr/local/sbin/smartctl",
           "/opt/ooce/smartmontools/sbin/smartctl", "/usr/local/bin/smartctl");
    for my $c (@cand) { return $c if -x $c; }
    return '';
}
my $SMARTCTL = find_smartctl();

# zfs/zpool are only used if actually present (plain drive letter / no ZFS)
sub _have { my ($c) = @_; my $o = $OSISWIN ? `where $c 2>NUL` : `command -v $c 2>/dev/null`; return ($o =~ /\S/) ? 1 : 0; }
my $HAVE_ZFS   = _have('zfs');
my $HAVE_ZPOOL = _have('zpool');

sub _zpool_list {
    return () unless $HAVE_ZPOOL;
    my @p = map { /^(\S+)/ ? $1 : () } `zpool list -H -o name 2>/dev/null`;
    return @p;
}

# =============================================================================
# TEST MEDIUM  -- scratch dataset on the pool under test (or a folder)
# =============================================================================
my @POOLS = _zpool_list();
my $DS     = '';
my $TESTDIR = '';
my $MEDIA_KIND = 'folder';
my $HAVE_SYNC_PROP = 0;
my $HAVE_CACHE_PROP = 0;
my $CACHE_MODE = 'metadata';

# recordsize matters: with the default 128K a 4k random read pulls a whole
# 128K record (32x amplification) -> the 4k test gets its OWN file written at
# recordsize=4K, the sequential/write tests keep 128K.
sub set_recordsize {
    my ($rs) = @_;
    return unless $MEDIA_KIND eq 'dataset';
    my $o = `zfs set recordsize=$rs "$DS" 2>&1`;
    blog("bench_note: zfs set recordsize=$rs -> " . ($o =~ /\S/ ? $o : 'ok'));
}

sub _norm_mnt {
    my ($m) = @_;
    return '' unless defined $m;
    chomp $m;
    if ($OSISWIN) { return $m =~ /^[A-Za-z]:$/ ? "$m\\" : $m; }
    return $m;
}

sub _free_mb {
    my ($p) = @_;
    my $mb = 0;
    if ($OSISWIN) {
        my ($dl) = $p =~ /^([A-Za-z]:)/;
        return 0 unless $dl;
        my $o = `wmic logicaldisk where "DeviceID='$dl'" get FreeSpace 2>NUL`;
        $mb = int($1 / 1048576) if $o =~ /(\d{7,})/;
    } else {
        my $o = `df -Pk "$p" 2>/dev/null`;
        $mb = $1 if $o =~ /^\S+\s+\d+\s+\d+\s+(\d+)/m;
    }
    return $mb;
}

# Create the scratch dataset with the cache-bypass properties.  sync is set per
# phase (only writes care); primarycache=none is what makes the READ tests
# storage-bound on every ZFS variant -- including Oracle Solaris 11.4, where
# O_DIRECT does not exist at all.
sub mk_media {
    my ($sync_mode, $cache_mode) = @_;
    $sync_mode  //= 'standard';
    # primarycache=metadata (NOT none): none also drops the METADATA cache, so
    # every read has to re-fetch dnode/indirect blocks from disk -- measured
    # 2026.09.18 on .50: 4k random read collapsed to 19 IOPS / seq read to
    # 19 MB/s.  'metadata' keeps data out of the ARC (storage-bound measurement)
    # without the pathological metadata re-reads.
    $cache_mode //= 'metadata';
    $CACHE_MODE = $cache_mode;

    unless ($HAVE_ZFS && $POOL =~ /\S/) {
        my $base = $POOL =~ /\S/ ? $POOL : ($OSISWIN ? ($ENV{TEMP} // 'C:\\Windows\\Temp') : '/tmp');
        $TESTDIR = File::Spec->catdir($base, "csbench_$RUNID");
        mkdir $TESTDIR;
        $MEDIA_KIND = 'folder';
        return 1;
    }

    $DS = "$POOL/csbench_$RUNID";
    my @opts = ("-o", "compression=off", "-o", "atime=off");
    # probe the properties first: a ZFS build without them must not abort the run
    $HAVE_CACHE_PROP = (`zfs get -H -o property primarycache $POOL 2>/dev/null` =~ /primarycache/) ? 1 : 0;
    $HAVE_SYNC_PROP  = (`zfs get -H -o property sync $POOL 2>/dev/null` =~ /\bsync\b/) ? 1 : 0;
    push @opts, ("-o", "primarycache=$cache_mode") if $HAVE_CACHE_PROP;
    push @opts, ("-o", "secondarycache=none")      if $HAVE_CACHE_PROP;
    push @opts, ("-o", "sync=$sync_mode")          if $HAVE_SYNC_PROP;

    my $out = `zfs create @opts "$DS" 2>&1`;
    if ($out =~ /\S/) {                       # create failed -> folder fallback
        blog("bench_note: zfs create failed: $out");
        my $mnt = _norm_mnt(`zfs get -H -o value mountpoint $POOL 2>/dev/null`);
        $mnt = ($OSISWIN ? ($ENV{TEMP} // 'C:\\Windows\\Temp') : '/tmp') unless $mnt =~ /\S/;
        $TESTDIR = File::Spec->catdir($mnt, "csbench_$RUNID");
        mkdir $TESTDIR;
        $MEDIA_KIND = 'folder';
        return 1;
    }
    $TESTDIR = _norm_mnt(`zfs get -H -o value mountpoint "$DS" 2>/dev/null`);
    $MEDIA_KIND = 'dataset';
    return 1;
}

sub set_sync {
    my ($mode) = @_;
    return unless $MEDIA_KIND eq 'dataset' && $HAVE_SYNC_PROP;
    my $o = `zfs set sync=$mode "$DS" 2>&1`;
    blog("bench_note: zfs set sync=$mode -> " . ($o =~ /\S/ ? $o : 'ok'));
}

sub rm_media {
    return unless $TESTDIR =~ /\S/;
    if ($MEDIA_KIND eq 'dataset' && $DS =~ /\S/) {
        my $o = `zfs destroy -rf "$DS" 2>&1`;
        blog("bench_note: zfs destroy $DS -> " . ($o =~ /\S/ ? $o : 'ok'));
    } else {
        unlink glob(File::Spec->catfile($TESTDIR, 'bench*'));
        rmdir $TESTDIR;
    }
}

# =============================================================================
# CROSS-CHECK SAMPLERS
# =============================================================================
# zpool iostat -v <dur> 2  -> the SECOND sample is the interval average, i.e.
# the proof whether the measured number came from the vdevs (storage-bound) or
# from a cache.  (-l latency histograms need -v on Solaris/illumos; not used.)
sub zpool_sample {
    my ($dur) = @_;
    return 'n/a (no zpool)' unless $HAVE_ZPOOL && $POOL =~ /\S/;
    $dur = int($dur); $dur = 1 if $dur < 1;
    my @o = grep { /\S/ } `zpool iostat -v $dur 2 2>/dev/null`;
    return 'n/a' unless @o;
    my $start = 0;
    for my $i (0 .. $#o) { $start = $i if $o[$i] =~ /^\s*capacity/i; }   # last block
    my @out;
    for my $l (@o[$start .. $#o]) {
        next if $l =~ /^\s*(capacity|-{3,})/i;
        next unless $l =~ /^\s*\S+\s/;
        push @out, "bench_zpool: " . $l;
    }
    return @out ? join("\n", @out) : 'n/a';
}

sub smart_snapshot {
    my ($label) = @_;
    return "bench_smart: $label = n/a (no smartctl)" unless $SMARTCTL =~ /\S/;
    my $dev = '';
    if ($HAVE_ZPOOL && $POOL =~ /\S/) {
        for my $l (`zpool status -P "$POOL" 2>/dev/null`) {
            if ($OSISWIN) { $dev = $1 if $l =~ /(\\\\\.\\PhysicalDrive\d+)/; }
            else          { $dev = $1 if $l =~ m{(/dev/\S+)}; }
            last if $dev =~ /\S/;
        }
    }
    return "bench_smart: $label = n/a (no device found)" unless $dev =~ /\S/;
    my @a = `"$SMARTCTL" -a "$dev" 2>/dev/null`;
    return "bench_smart: $label = n/a (smartctl failed)" unless @a;
    my @keep = map { s/^\s+|\s+$//gr }
               grep { /(Temperature|Percentage Used|Data Units Written|Power On Hours)/i } @a;
    return "bench_smart: $label = n/a (no SMART values)" unless @keep;
    return "bench_smart: $label = " . join(' | ', @keep);
}

sub cpu_load {
    return 'n/a' if $OSISWIN;
    # 'uptime' works on Solaris/illumos/Linux/BSD/macOS and always gives a
    # defined value; the earlier prstat parse could return an undef $1.
    my $j = join('', `uptime 2>/dev/null`);
    return $1 if $j =~ /load average[s]?:\s*([\d.]+)/;
    return 'n/a';
}

sub cancel_requested { return (-f $CANCEL) ? 1 : 0; }

# =============================================================================
# MEASUREMENT CORE
# =============================================================================
# threads are used for concurrency (the project loads 'threads' on every
# platform, incl. Windows); if unavailable we fall back to serial with a note.
my $HAVE_THREADS = 0;
eval { require threads; threads->import(); $HAVE_THREADS = 1; };

# ---- coarse, mergeable latency histogram (microseconds) ---------------------
my @HB = (250, 500, 1000, 2000, 4000, 8000, 16000, 32000, 64000, 128000);
sub new_hist { return [ (0) x (scalar(@HB) + 1) ]; }
sub hist_add { my ($h, $us) = @_; my $i = 0; $i++ while $i < @HB && $us > $HB[$i]; $h->[$i]++; }
sub hist_merge { my ($a, $b) = @_; $a->[$_] += $b->[$_] for 0 .. $#HB; }
sub hist_pct {
    my ($h, $p) = @_;
    my $tot = 0; $tot += $_ for @$h;
    return 0 unless $tot;
    my $want = int($tot * $p / 100);
    $want = 1 if $want < 1;
    my $cum = 0;
    for my $i (0 .. $#HB) { $cum += $h->[$i]; return $HB[$i] if $cum >= $want; }
    return $HB[-1];
}

# ---- the two workers --------------------------------------------------------
sub _worker_read {
    my ($file, $dur, $bs, $seq) = @_;
    my $h = new_hist();
    open(my $fh, '<', $file) or return (0, 0, 0, 0, $h);
    binmode $fh;
    my $size = -s $file;
    my $blocks = int($size / $bs); $blocks = 1 if $blocks < 1;
    my ($n, $bytes, $max) = (0, 0, 0);
    my $buf = '';
    my $lin = 0;                     # linear sweep position (sequential mode)
    my $t0 = time();
    while (1) {
        # $seq: walk the file from 0 upwards (a REAL sequential read, so ZFS can
        # prefetch); otherwise a random offset per read.  (Without this the
        # "seq read" number was really a random 4k/1M read -- found 2026.09.18.)
        my $off = $seq ? $lin : int(rand($blocks)) * $bs;
        my $s = time();
        sysseek($fh, $off, 0);
        my $r = sysread($fh, $buf, $bs);
        my $us = (time() - $s) * 1e6;
        hist_add($h, $us);
        $max = $us if $us > $max;
        $n++;
        $bytes += $r if defined $r;
        if ($seq) { $lin += $bs; $lin = 0 if $lin >= $size; }
        if (($n & 0xFF) == 0) { last if time() - $t0 >= $dur; }
    }
    close $fh;
    return ($n, $bytes, time() - $t0, $max, $h);
}

sub _worker_write {
    my ($file, $dur, $bs, $cap) = @_;
    my $h = new_hist();
    open(my $fh, '>>', $file) or return (0, 0, 0, 0, $h);   # opened, seeked below
    binmode $fh;
    my $blk = 'W' x $bs;
    my $off = 0;
    my ($n, $bytes, $max) = (0, 0, 0);
    my $t0 = time();
    while (1) {
        my $s = time();
        sysseek($fh, $off, 0);
        my $w = syswrite($fh, $blk);
        my $us = (time() - $s) * 1e6;
        hist_add($h, $us);
        $max = $us if $us > $max;
        if (defined $w) { $bytes += $w; $n++; }
        $off += $bs;
        $off = 0 if $off >= $cap;      # wrap -> in-place overwrite, no growth
        if (($n & 0x3F) == 0) { last if time() - $t0 >= $dur; }
    }
    close $fh;
    return ($n, $bytes, time() - $t0, $max, $h);
}

# ---- run one measurement (1..N concurrent workers) -------------------------
sub _meas {
    my (%a) = @_;      # kind => read|write, file, dur, bs, streams, cap, offset_jitter
    my $streams = $a{streams} // 1;
    $streams = 1 if $streams < 1 || !$HAVE_THREADS;
    my $cap = $a{cap} // (16 * 1048576);
    my $bs  = $a{bs}  // 4096;
    my $dur = $a{dur} // 5;

    my @th;
    my $q = $a{seq} ? 1 : 0;
    for my $i (1 .. $streams) {
        my ($k, $f, $d, $b, $c, $sq) = ($a{kind}, $a{file}, $dur, $bs, $cap, $q);
        push @th, threads->create(sub {
            return $k eq 'read' ? _worker_read($f, $d, $b, $sq) : _worker_write($f, $d, $b, $c);
        });
    }
    my ($n, $bytes, $el, $max) = (0, 0, 0, 0);
    my $h = new_hist();
    for my $t (@th) {
        my @r = $t->join();
        next unless @r && defined $r[0];
        $n     += $r[0];
        $bytes += $r[1] // 0;
        $el     = $r[2] if ($r[2] // 0) > $el;
        $max    = $r[3] if ($r[3] // 0) > $max;
        hist_merge($h, $r[4]) if ref $r[4] eq 'ARRAY';
    }
    $el = 0.001 if $el <= 0;
    return {
        n     => $n,
        mb    => $bytes / 1048576,
        sec   => $el,
        iops  => $n / $el,
        mbs   => ($bytes / 1048576) / $el,
        p50   => hist_pct($h, 50),
        p99   => hist_pct($h, 99),
        maxus => $max,
    };
}

# ---- helpers ----------------------------------------------------------------
# "153M" / "1.2K" / "1024" -> MB/s
sub _parse_bw {
    my ($v) = @_;
    return 0 unless defined $v && $v =~ /([\d.]+)\s*([KMGT]?)/i;
    my ($n, $u) = ($1 + 0, uc($2 // ''));
    return $n / 1048576 if $u eq '';      # bytes
    return $n / 1024    if $u eq 'K';
    return $n           if $u eq 'M';
    return $n * 1024    if $u eq 'G';
    return $n * 1048576 if $u eq 'T';
    return 0;
}

# pull the measured bandwidth of the pool's own line out of a zpool sample
sub _zpool_bw_mbs {
    my ($sample) = @_;
    for my $l (split /\n/, ($sample // '')) {
        next unless $l =~ /^bench_zpool:\s+(\S+)\s+/;
        next unless $1 eq $POOL;
        my @f = split /\s+/, $l;
        return (_parse_bw($f[-1]) + _parse_bw($f[-2])) / 1 if @f >= 3;
    }
    return -1;
}

# storage-bound | cache | tool-limited(CPU) -- the honest label per measurement
sub classify {
    my ($res, $sample) = @_;
    return 'n/a' if $MEDIA_KIND ne 'dataset' || !$HAVE_CACHE_PROP;
    my $bw = _zpool_bw_mbs($sample);
    return 'n/a (no vdev data)' if $bw < 0;
    return 'cache' if $bw < $res->{mbs} * 0.10;
    return 'storage-bound' if $bw >= $res->{mbs} * 0.50;
    return 'partial';
}

# ---- pre-create the test file (its own write load -- reported separately) ---
sub make_testfile {
    my ($path, $mb) = @_;
    my $bs = 1048576;
    open(my $fh, '>', $path) or return 0;
    binmode $fh;
    my $blk = 'A' x $bs;
    my $t0 = time();
    my $w = 0;
    for (1 .. $mb) { $w += syswrite($fh, $blk) // 0; }
    close $fh;
    my $dt = time() - $t0;
    $dt = 0.001 if $dt <= 0;
    return ($w / 1048576) / $dt;
}

# ---- steady write: per-interval sample lines + SMART + latency --------------
sub steady_write {
    my ($file, $cap, $dur_s, $interval, $bs) = @_;
    open(my $fh, '>>', $file) or return ();
    binmode $fh;
    my $blk = 'S' x $bs;
    my $off = 0;
    my ($bytes, $n) = (0, 0);
    my ($t0, $last) = (time(), time());
    my ($lb, $ln) = (0, 0);
    my $us_sum = 0; my $us_max = 0;
    my @win;
    while (1) {
        my $s = time();
        sysseek($fh, $off, 0);
        my $w = syswrite($fh, $blk);
        my $us = (time() - $s) * 1e6;
        $us_sum += $us; $us_max = $us if $us > $us_max;
        if (defined $w) { $bytes += $w; $n++; }
        $off += $bs;
        $off = 0 if $off >= $cap;
        my $now = time();
        if ($now - $last >= $interval) {
            my $win_mbs = (($bytes - $lb) / 1048576) / ($now - $last);
            push @win, $win_mbs;
            blog(sprintf("sample t=%5.0fs cum=%8.2fGB write=%8.1fMB/s iops=%7.0f lat_avg=%.2fms lat_max=%.1fms",
                $now - $t0, $bytes / 1073741824, $win_mbs, ($n - $ln) / ($now - $last),
                ($us_sum / ($n || 1)) / 1000, $us_max / 1000));
            blog(zpool_sample($interval));
            blog(smart_snapshot(sprintf("t=%.0fs", $now - $t0)));
            $last = $now; $lb = $bytes; $ln = $n; $us_sum = 0; $us_max = 0;
            last if cancel_requested();
        }
        last if ($now - $t0) >= $dur_s;
    }
    close $fh;
    # steady state = median of the LAST QUARTER of the windows (warm-up dropped)
    my $q = int(@win / 4);
    my @tail = $q > 0 ? @win[$q .. $#win] : @win;
    @tail = sort { $a <=> $b } @tail;
    my $med = @tail ? $tail[int(@tail / 2)] : 0;
    return ($med, scalar(@win), ($bytes / 1048576) / (time() - $t0));
}

# =============================================================================
# GUARD: only ONE benchmark per member (parallel runs would skew the numbers)
# =============================================================================
if (-f $RUNM) {
    my $who = '';
    if (open(my $rf, '<', $RUNM)) { local $/; $who = <$rf> // ''; close $rf; }
    $who =~ s/[\r\n]+/ /g;
    print "already running ($who)\n";
    exit 0;
}
my $DONE = 0;
my $T0   = time();
END {
    eval { rm_media() if $TESTDIR =~ /\S/; };
    if (!$DONE && $LOGFH) { bdone('error', 'aborted (worker exited or was cancelled)'); }
    unlink $RUNM;
    unlink $CANCEL;
}
if (open(my $rf, '>', $RUNM)) { print $rf "runid=$RUNID pool=$POOL pid=$$\n"; close $rf; }

bench_open();

# =============================================================================
# HEADER -- everything that makes this run reproducible/comparable
# =============================================================================
my $VERBOSE = (-t STDOUT) || (($P{verbose} // '') =~ /^y/i) ? 1 : 0;
sub vlog { print @_, "\n" if $VERBOSE; }

unless ($POOL =~ /\S/) { $POOL = $POOLS[0] // ''; }

bhdr('run_id',    $RUNID);
bhdr('pool',      $POOL =~ /\S/ ? $POOL : '(none -> folder)');
bhdr('profile',   $PROFILE);
bhdr('load',      $LOAD);
bhdr('vCPU',      $VCPU);
bhdr('RAM_GB',    $RAM_GB);
bhdr('streams',   $STREAMS . ($STREAMS_CLAMPED ? "  WARNING: > vCPU=$VCPU -> tool-limited" : ''));
bhdr('os',        $OSNAME);
bhdr('perl',      "$^V");
bhdr('threads',   $HAVE_THREADS ? 'yes' : 'no (serial fallback)');
bhdr('smartctl',  $SMARTCTL =~ /\S/ ? $SMARTCTL : 'n/a');
bhdr('pools',     join(',', @POOLS) || 'n/a');
bhdr('phases',    join(',', grep { /\S/ } (
                    $T_FOUR_K ? "4k:$C{p4k}s" : '',
                    "seqread:$C{sr}s",
                    $T_SYNC  ? "syncwrite:$C{sw}s" : '',
                    $T_ASYNC ? "asyncwrite:$C{aw}s" : '',
                    $T_MIXED ? "mixed:$C{mx}s" : '',
                    $T_MULTI ? "multiuser:$C{mu}s x$STREAMS" : '',
                    $T_STEADY ? "steady:${STEADY_MIN}min/${STEADY_IV}s" : '')));

mk_media('standard');

my $FREE_MB = _free_mb($TESTDIR =~ /\S/ ? $TESTDIR : '.');
my $want_mb = int($RAM_GB * 1024 * $SIZE_PCT / 100);
$want_mb = 256 if $want_mb < 256;
if ($FREE_MB > 0) {
    my $max = int($FREE_MB * 0.45);
    if ($want_mb > $max) { $want_mb = $max; blog("bench_note: size clamped to free space ($FREE_MB MB free)"); }
}
$want_mb = 128 if $want_mb < 128;
my $cap = $want_mb * 1048576;

bhdr('media',     $MEDIA_KIND . ($DS =~ /\S/ ? " ($DS)" : " ($TESTDIR)"));
bhdr('props',     ($HAVE_CACHE_PROP ? "primarycache=$CACHE_MODE secondarycache=none " : 'no cache props ')
                  . ($HAVE_SYNC_PROP ? 'sync=per-phase ' : 'no sync prop ')
                  . 'recordsize=4K(4k-test)/128K(main)');
bhdr('filesize',  "${want_mb} MB (" . $SIZE_PCT . "% RAM, free=${FREE_MB}MB)");
bhdr('cpu_load',  cpu_load());
blog(smart_snapshot('start'));
blog(zpool_sample(1));

my $file = File::Spec->catfile($TESTDIR, 'bench_file.dat');
vlog("testfile: $file cap=${want_mb}MB");

# ---- run a measurement AND a concurrent zpool sample (the cross-check) ------
sub phase {
    my (%a) = @_;
    my $zs = '';
    my $t = ($HAVE_THREADS && $HAVE_ZPOOL) ? threads->create(sub { zpool_sample($a{dur}) }) : undef;
    my $r = _meas(%a);
    if ($t) { my @x = $t->join(); $zs = $x[0] // ''; }
    else    { $zs = zpool_sample(1); }
    return ($r, $zs);
}

# ---- mixed read+write (concurrent) -----------------------------------------
sub mixed_phase {
    my (%a) = @_;
    my ($aggR, $aggW) = (new_hist(), new_hist());
    my ($nR, $bR, $eR, $nW, $bW, $eW) = (0, 0, 0, 0, 0, 0);
    my (@R, @W);
    if ($HAVE_THREADS) {
        for (1 .. $a{nread})  { my ($f, $d, $b) = ($a{file}, $a{dur}, $a{bs});
                                push @R, threads->create(sub { _worker_read($f, $d, $b) }); }
        for (1 .. $a{nwrite}) { my ($f, $d, $b, $c) = ($a{file}, $a{dur}, $a{bs}, $a{cap});
                                push @W, threads->create(sub { _worker_write($f, $d, $b, $c) }); }
    } else {
        push @R, threads->create(sub { _worker_read($a{file}, $a{dur}, $a{bs}) });
        push @W, threads->create(sub { _worker_write($a{file}, $a{dur}, $a{bs}, $a{cap}) });
    }
    for my $t (@R) { my @x = $t->join(); next unless @x;
                     $nR += $x[0]; $bR += $x[1] // 0; $eR = $x[2] if ($x[2] // 0) > $eR;
                     hist_merge($aggR, $x[4]) if ref $x[4] eq 'ARRAY'; }
    for my $t (@W) { my @x = $t->join(); next unless @x;
                     $nW += $x[0]; $bW += $x[1] // 0; $eW = $x[2] if ($x[2] // 0) > $eW;
                     hist_merge($aggW, $x[4]) if ref $x[4] eq 'ARRAY'; }
    $eR = 0.001 if $eR <= 0;
    $eW = 0.001 if $eW <= 0;
    return ({ iops => $nR / $eR, mbs => ($bR / 1048576) / $eR, p99 => hist_pct($aggR, 99) },
            { iops => $nW / $eW, mbs => ($bW / 1048576) / $eW, p99 => hist_pct($aggW, 99) });
}

# =============================================================================
# PHASES
# =============================================================================
my %CLASS = ();

# --- 4k phases use their OWN file, written at recordsize=4K (see set_recordsize)
my $file4k = File::Spec->catfile($TESTDIR, 'bench_4k.dat');
my $mb4k   = ($want_mb > 256) ? 256 : $want_mb;
# 4k-based phases (mixed, multiuser) must read the 4k-recordsize file, otherwise
# a 4k read pulls a 128k record and the number is dominated by amplification.
my $file_small = '';

if ($T_FOUR_K && !cancel_requested()) {
    set_recordsize('4K');
    vlog('phase: create 4k test file (recordsize=4K)');
    my $mk4 = make_testfile($file4k, $mb4k);
    bres('file_create_4k_singleuser', sprintf('%.1f', $mk4), 'MB/s');
    $file_small = (-s $file4k) ? $file4k : '';
    vlog('phase: 4k random read (single stream)');
    my ($r, $zs) = phase(kind => 'read', file => $file4k, dur => $C{p4k}, bs => 4096, streams => 1);
    bres('4k_iops_read',       sprintf('%.0f', $r->{iops}), 'iop/s');
    bres('4k_read_singleuser', sprintf('%.1f', $r->{mbs}),  'MB/s');
    bres('4k_read_lat_p50_us', sprintf('%.0f', $r->{p50}),  'us');
    bres('4k_read_lat_p99_us', sprintf('%.0f', $r->{p99}),  'us');
    $CLASS{'4k_read'} = classify($r, $zs);
    bres('4k_read_class', $CLASS{'4k_read'}, '');
    blog($zs);
    set_recordsize('128K');
}

if (!cancel_requested()) {
    vlog('phase: create test file (recordsize=128K)');
    my $mk = make_testfile($file, $want_mb);
    bres('file_create_singleuser', sprintf('%.1f', $mk), 'MB/s');

    vlog('phase: sequential read (1MB, single stream, linear sweep)');
    my ($r, $zs) = phase(kind => 'read', file => $file, dur => $C{sr}, bs => 1048576,
                         streams => 1, seq => 1);
    bres('seq_read_singleuser', sprintf('%.1f', $r->{mbs}), 'MB/s');
    bres('seq_read_lat_p99_us', sprintf('%.0f', $r->{p99}), 'us');
    $CLASS{seq_read} = classify($r, $zs);
    bres('seq_read_class', $CLASS{seq_read}, '');
    blog($zs);
}

if ($T_SYNC && !cancel_requested()) {
    vlog('phase: sync write (1MB blocks, sync=always)');
    set_sync('always');
    my ($r, $zs) = phase(kind => 'write', file => $file, dur => $C{sw}, bs => 1048576,
                         streams => 1, cap => $cap);
    bres('sync_write_singleuser', sprintf('%.1f', $r->{mbs}), 'MB/s');
    bres('sync_write_lat_p99_ms', sprintf('%.1f', $r->{p99} / 1000), 'ms');
    $CLASS{sync_write} = classify($r, $zs);
    bres('sync_write_class', $CLASS{sync_write}, '');
    blog($zs);
}

if ($T_ASYNC && !cancel_requested()) {
    vlog('phase: async write (1MB blocks, sync=standard) -- cache indicator');
    set_sync('standard');
    my ($r, $zs) = phase(kind => 'write', file => $file, dur => $C{aw}, bs => 1048576,
                         streams => 1, cap => $cap);
    bres('async_write_singleuser', sprintf('%.1f', $r->{mbs}), 'MB/s (cache indicator)');
    # async writes are absorbed by the dirty-data buffer; the vdev only sees the
    # later flush, so this must NOT be called storage-bound.  Compare it with the
    # sync number instead (measured on .50: 1358 async vs 136 sync MB/s).
    $CLASS{async_write} = 'cache-influenced';
    bres('async_write_class', $CLASS{async_write}, '');
    blog($zs);
}

if ($T_MIXED && !cancel_requested()) {
    vlog('phase: concurrent read+write (2 readers + 2 writers)');
    set_sync('standard');
    my $th = ($HAVE_THREADS && $HAVE_ZPOOL) ? threads->create(sub { zpool_sample($C{mx}) }) : undef;
    my ($R, $W) = mixed_phase(file => ($file_small =~ /\S/ ? $file_small : $file),
                              dur => $C{mx}, bs => 4096, cap => $cap,
                              nread => 2, nwrite => 2);
    my $zs = $th ? (($th->join())[0] // '') : zpool_sample(1);
    bres('conc_read_mbs',         sprintf('%.1f', $R->{mbs}),  'MB/s (2 streams)');
    bres('conc_write_mbs',        sprintf('%.1f', $W->{mbs}),  'MB/s (2 streams)');
    bres('conc_read_lat_p99_us',  sprintf('%.0f', $R->{p99}),  'us');
    bres('conc_write_lat_p99_ms', sprintf('%.1f', $W->{p99} / 1000), 'ms');
    $CLASS{conc} = classify({ mbs => $R->{mbs} + $W->{mbs} }, $zs);
    bres('conc_class', $CLASS{conc}, '');
    blog($zs);
}

if ($T_MULTI && !cancel_requested()) {
    vlog("phase: multiuser read (4k, 1 vs $STREAMS streams)");
    my ($r1) = phase(kind => 'read', file => ($file_small =~ /\S/ ? $file_small : $file),
                     dur => $C{mu}, bs => 4096, streams => 1);
    bres('multiuser_read_1_mbs', sprintf('%.1f', $r1->{mbs}), 'MB/s');
    my ($rn, $zs) = phase(kind => 'read', file => ($file_small =~ /\S/ ? $file_small : $file),
                          dur => $C{mu}, bs => 4096, streams => $STREAMS);
    bres("multiuser_read_${STREAMS}_mbs",  sprintf('%.1f', $rn->{mbs}),  'MB/s');
    bres("multiuser_read_${STREAMS}_iops", sprintf('%.0f', $rn->{iops}), 'iop/s');
    my $ratio = $r1->{mbs} > 0 ? $rn->{mbs} / $r1->{mbs} : 0;
    bres('multiuser_read_ratio', sprintf('%.2f', $ratio),
         "x (1 -> $STREAMS streams; a mirror already splits ONE stream over both disks)");
    $CLASS{multiuser} = classify($rn, $zs);
    bres('multiuser_read_class', $CLASS{multiuser}, '');
    blog($zs);
}

if ($T_STEADY && !cancel_requested()) {
    vlog("phase: steady write ($STEADY_MIN min, sample every ${STEADY_IV}s)");
    set_sync('always');
    my ($med, $wins, $avg) = steady_write($file, $cap, $STEADY_MIN * 60, $STEADY_IV, 1048576);
    bres('steady_write_mbs',     sprintf('%.1f', $med), 'MB/s (median of the last quarter)');
    bres('steady_write_avg_mbs', sprintf('%.1f', $avg), 'MB/s (whole run incl. warm-up)');
    bres('steady_write_windows', $wins, "x ${STEADY_IV}s");
    blog(zpool_sample(1));
    blog(smart_snapshot('end'));
}

# =============================================================================
# SUMMARY
# =============================================================================
my $tot = time() - $T0;
if (cancel_requested()) {
    bres('bench_cancelled', 'yes', "after ${tot}s");
    $DONE = 1;
    bdone('error', 'cancelled');
    exit 0;
}
bhdr('duration_s', sprintf('%.0f', $tot));
unless ($HAVE_CACHE_PROP && $MEDIA_KIND eq 'dataset') {
    blog("bench_note: cache properties NOT applied -> read numbers may be cache-influenced");
}
for my $k (sort keys %CLASS) {
    blog(sprintf("bench_class: %-12s = %s", $k, $CLASS{$k}));
}
$DONE = 1;
bdone('ok', sprintf('%.0fs profile=%s pool=%s media=%s', $tot, $PROFILE, $POOL, $MEDIA_KIND));
vlog("BENCH_DONE ok (${tot}s)  log=$LOG");
