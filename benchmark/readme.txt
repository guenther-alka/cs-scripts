==========================================================================
 readme.txt -- benchmark/ (standalone ZFS pool benchmark)
 (c) 2026 Guenther Alka / napp-it.org -- Project: napp-it cs
==========================================================================

benchmark_worker.pl measures POOL performance on the machine it runs on. It needs
no napp-it installation, no frontend and no cluster -- only perl, zfs/zpool,
df and (optionally) smartctl. Written in pure Perl (sysseek/sysread/syswrite
+ Time::HiRes): no fio, nothing to install.

Measured per run
  4k random read IOPS, sequential read, sync write, async write, concurrent
  read+write, multiuser read (1 vs N streams), optionally a long steady-write
  test with one sample line every 30 s.  Every number carries p50/p99 latency
  and an honest class: storage-bound | cache | cache-influenced | tool-limited.

The concise statement (RESULT verdict, verdict_text, verdict_note)
  Every finished run ends with ONE rating, ONE line and a note, so the answer to
  "how fast is this storage?" does not need the 40 detail lines:
    verdict       storage-bound | partial | cache | tool-limited | indicative
    verdict_text  sync write MB/s + p99, 4k read IOPS + p99, seq read MB/s, each with its class
    verdict_note  why the rating is what it is (Windows page cache, the tool ceiling of
                  ~80000 4k IOPS, more streams than vCPUs, no scratch dataset / no sync=always)
  Rated: sync write, 4k read, seq read.  The async write is a cache indicator and is not rated.
  storage-bound = the vdevs delivered the numbers (a read at the tool ceiling counts as "at least");
  partial = only part of it did; cache = the numbers are cache speed; tool-limited = every rated
  value hit the tool's ceiling; indicative = no scratch dataset / vdev data, caches are included.
  Standalone runs on a terminal print it as "VERDICT: ..." (or add verbose=yes).

Fast profiles (quick, basic)
  Test file capped at 2 GB (primarycache=metadata makes a RAM-sized file unnecessary),
  concurrent 1+1 only in database/fileserver/individual (conc1=yes adds it elsewhere; the N+N
  variant always runs), the multiuser 1-stream value is the 4k single-stream read (same file and
  block size, measured once), and zfs set sync is only issued when the mode changes.
  Measured: profile=quick 82 s on Solaris 11.4 (1 vCPU, VMDK pool; 93-163 s before).

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

Windows (measured 2026.09.18, OpenZFS on Windows zfswin-2.4.1rc15)
  * zfs/zpool are called by plain name (the napp-it convention) and sit in the
    MACHINE PATH after the OpenZFS install, so services find them as well.
  * Datasets are NOT addressed by mountpoint there: that property stays unix
    style ("/winpool") while the pool is mounted on a drive letter given by the
    Windows-only property driveletter (ex. "d:").  A dataset path is therefore
    <drive>:\<path below the pool root> -- the script resolves it that way;
    using the mountpoint put the test file on the system drive instead.
  * wmic no longer exists on current Windows -> RAM, free space and cpu_load use
    PowerShell CIM / Get-PSDrive (the napp-it convention) with wmic as fallback.
  * zfs create/set/destroy need ADMIN rights.  Without them the OpenZFS CLI
    prints "permission denied / Attempting to relaunch command with
    administrator privileges..." and may still create the dataset, so the script
    asks ZFS whether the dataset exists instead of trusting that message.  Run
    it elevated on Windows (the napp-it backend service is), otherwise the
    folder fallback is used and the cache/sync properties do not apply.
  * cmd.exe has no /dev/null and backticks are NOT reliable in a console-less
    worker (verified: the output can be empty), so all external commands run
    through one funnel: Windows = cmd /c into a temp file which is read back,
    Unix = plain backtick.  A "2>/dev/null" would make cmd.exe abort the command
    entirely -- that silently disabled the property probes, the zpool sampler and
    the SMART reads before.  Cleanup reads the directory instead of using glob()
    (whose backslash escaping left the test files behind on Windows).

Usage
  perl benchmark_worker.pl profile=quick pool=tank
  perl benchmark_worker.pl profile=mailserver syncwrite=yes load=balanced
  perl benchmark_worker.pl profile=quick pool=tank conc1=yes   # add the concurrent 1+1 phase
  perl benchmark_worker.pl name_of_run profile=basic steady=yes steady_min=30
  perl benchmark_worker.pl profile=steadywrite pool=tank steady_min=30
      (steadywrite = ONLY the steady write test, 3 variants one after the other: singlestream
       write | N streams write | concurrent 1 reader + 1 writer, steady_min = TOTAL minutes;
       one "steady_sample:" log line per window = the write performance history)
  perl benchmark_worker.pl check=yes pool=tank   # dry run: resolve env + medium,
                                                 # create nothing (frontend probe)
  perl benchmark_worker.pl help=yes

  profile=quick ~1-1.5 min, the others 5-10 min.  Without a runid the id is
  generated as auto_YYYYMMDD_HHMMSS.  Result: last_benchmark.log next to the
  script (rundir=/path to change), containing
    bench_hdr: ...            all parameters/environment of the run
    RESULT <name> = <value> <unit>
    BENCH_DONE ok|error ...   (last line = run finished)
  Only one benchmark per machine: a fixed "benchmark.running" marker makes a
  second run answer "already running".  Cancel: create benchmark_<runid>.cancel.

Integration
  The SAME file (same name, same content) ships in the napp-it cs distribution
  as data/menues/_lib/scripts/bench/benchmark_worker.pl and is deployed to a
  cluster member by the benchmark menu (benchmark_director.pl + action.pl),
  which reads exactly the RESULT lines for its comparison table.
  KEEP BOTH COPIES IDENTICAL when changing one -- the repository stores LF, so a
  Windows checkout may show CRLF in the working copy.
