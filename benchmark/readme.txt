==========================================================================
 readme.txt -- benchmark/ (standalone ZFS pool benchmark)
 (c) 2026 Guenther Alka / napp-it.org -- Project: napp-it cs
==========================================================================

benchmark.pl measures POOL performance on the machine it runs on. It needs
no napp-it installation, no frontend and no cluster -- only perl, zfs/zpool,
df and (optionally) smartctl. Written in pure Perl (sysseek/sysread/syswrite
+ Time::HiRes): no fio, nothing to install.

Measured per run
  4k random read IOPS, sequential read, sync write, async write, concurrent
  read+write, multiuser read (1 vs N streams), optionally a long steady-write
  test with one sample line every 30 s.  Every number carries p50/p99 latency
  and an honest class: storage-bound | cache | cache-influenced | tool-limited.

Why the numbers can be trusted (the cache trap)
  * Test medium = a SCRATCH DATASET on the pool under test, created at start
    and destroyed again at the end (also on error/cancel):
      zfs create -o compression=off -o atime=off -o secondarycache=none \
                 -o primarycache=metadata <pool>/csbench_<runid>
    primarycache=metadata keeps DATA out of the ARC so reads really reach the
    disks, but KEEPS the metadata cache.  With primarycache=none the same test
    collapsed to 19 IOPS / 19 MB/s on Solaris (measured 2026.09.18): every read
    then also had to re-fetch dnode/indirect blocks.
  * Sync writes use the ZFS property sync=always (Perl has no fsync).  Same
    pool: 1358 MB/s async (buffered) vs 136 MB/s sync -> the async number is
    only a cache indicator and is labelled as such.
  * zpool iostat -v runs CONCURRENTLY with every phase and is written into the
    log next to the result -- that is what the storage-bound/cache label is
    derived from (measured sync write 100 MB/s <-> vdev 627 ops/101M).
  * 4k tests use their own test file written at recordsize=4K; reading 4k out
    of a default 128K record would pull 128K (32x amplification).
  * A run leaves NO footprint: dataset destroyed, marker/cancel removed.

Limits (documented, not hidden)
  * No O_DIRECT -- Perl cannot align its buffers, so Direct I/O is not usable;
    primarycache=metadata is the portable replacement (OpenZFS/Solaris/illumos).
  * Single-threaded Perl costs ~6-10 us per 4k I/O (~95k IOPS measured on
    Windows, ~168k on a Solaris VM) -> faster storage is "tool-limited".
    Streams help until the CPU saturates: on 1 vCPU 4 streams gave only 1.3x.
  * A mirror already splits ONE read stream over both disks, so the 1-vs-N
    ratio is reported, never promised.

Usage
  perl benchmark.pl profile=quick pool=tank
  perl benchmark.pl profile=mailserver syncwrite=yes load=balanced
  perl benchmark.pl name_of_run profile=basic steady=yes steady_min=30
  perl benchmark.pl help=yes

  profile=quick ~1-2 min, the others 5-10 min.  Without a runid the id is
  generated as auto_YYYYMMDD_HHMMSS.  Result: last_benchmark.log next to the
  script (rundir=/path to change), containing
    bench_hdr: ...            all parameters/environment of the run
    RESULT <name> = <value> <unit>
    BENCH_DONE ok|error ...   (last line = run finished)
  Only one benchmark per machine: a fixed "benchmark.running" marker makes a
  second run answer "already running".  Cancel: create benchmark_<runid>.cancel.

Integration
  The identical script ships in the napp-it cs distribution as
  data/menues/_lib/scripts/bench/benchmark_worker.pl and is deployed to a
  cluster member by the benchmark menu (benchmark_director.pl + action.pl),
  which reads exactly the RESULT lines for its comparison table.
  KEEP BOTH COPIES IDENTICAL when changing one.
