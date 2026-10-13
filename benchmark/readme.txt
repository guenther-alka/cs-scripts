==========================================================================
 readme.txt -- benchmark/ (standalone ZFS pool benchmark)
 (c) 2026 Guenther Alka / napp-it.org -- Project: napp-it cs
==========================================================================

benchmark_worker.pl measures POOL performance on the machine it runs on. It needs
no napp-it installation, no frontend and no cluster -- only perl, zfs/zpool,
df and (optionally) smartctl. Written in pure Perl (sysseek/sysread/syswrite
+ Time::HiRes): no fio, nothing to install.

Measured per run
  4k random read IOPS, 4k random sync write IOPS, sequential read, sync write, async write, concurrent
  read+write, multiuser read (1 vs N streams), optionally a long steady-write
  test with one sample line every 30 s.  Every number carries p50/p99 latency
  and an honest class: storage-bound | cache | cache-influenced | tool-limited.

The concise statement (RESULT verdict, verdict_text, verdict_note)
  Every finished run ends with ONE rating, ONE line and a note, so the answer to
  "how fast is this storage?" does not need the 40 detail lines:
    verdict       storage-bound | partial | cache | tool-limited | indicative
    verdict_text  sync write MB/s + p99, 4k write IOPS + p99, 4k read IOPS + p99, seq read MB/s, each with its class
    verdict_note  why the rating is what it is (Windows page cache, the tool ceiling of
                  ~80000 4k IOPS, more streams than vCPUs, no scratch dataset / no sync=always)
  Rated: sync write, 4k sync write, 4k read, seq read.  The async write is a cache indicator and is not rated.
  storage-bound = the vdevs delivered the numbers (a read at the tool ceiling counts as "at least");
  partial = only part of it did; cache = the numbers are cache speed; tool-limited = every rated
  value hit the tool's ceiling; indicative = no scratch dataset / vdev data, caches are included.

Console output (standalone run on a terminal, or add verbose=yes)
  At the end of a run the result is printed one value per line, grouped by phase, followed by
  the verdict.  The values are the RESULT lines of the log, so console and log never differ.
  A group is skipped when its phase did not run in the chosen profile.  Example (shortened):

    Pool              : nvme480 (dataset, nvme480/csbench_auto_20261012_153327)
    Profile           : basic, 2048 MB test file, 5 streams, 143 s

    4k random read (1 stream)
      IOPS            : 81393
      Throughput      : 317.9 MB/s
      Latency p50/p99 : 50 / 50 us
      Class           : tool-limited

    Concurrent read+write (5 readers + 5 writers)
      Read            : 365.2 MB/s (p99 250 us)
      Write           : 4.8 MB/s (p99 32.0 ms)
      Class           : storage-bound

    Multiuser read (4k, 1 vs 5 streams)
      1 stream        : 317.7 MB/s
      5 streams       : 522.0 MB/s
      5 streams       : 133626 IOPS
      Scaling         : 1.64 x
      Class           : tool-limited

    Verdict           : storage-bound
      sync write 1104 MB/s p99 2.0 ms (storage-bound)
      ...
      note: a read reached the tool ceiling (~80000 IOPS) - the storage may be faster

  Multiuser read (1 vs N streams) shows how well the pool scales with parallel readers: a mirror
  scales better than RAID-Z.  Multiuser write is not measured separately -- the concurrent
  N+N phase covers read and write together.

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
  perl benchmark_worker.pl profile=basic pool=tank
  perl benchmark_worker.pl profile=mailserver syncwrite=yes load=balanced
  perl benchmark_worker.pl profile=quick pool=tank conc1=yes   # add the concurrent 1+1 phase
  perl benchmark_worker.pl name_of_run profile=basic steady=yes steady_min=30
  perl benchmark_worker.pl profile=steadywrite pool=tank steady_min=45
      (steadywrite = ONLY the steady write test, 3 variants one after the other: singlestream
       write | N streams write | concurrent 1 reader + 1 writer, steady_min = TOTAL minutes (default 45 = 3 x 15 min);
       one "steady_sample:" log line per window = the write performance history)
  perl benchmark_worker.pl check=yes pool=tank   # dry run: resolve env + medium,
                                                 # create nothing (frontend probe)
  perl benchmark_worker.pl help=yes
  perl benchmark_worker.pl profile=basic pool=tank remotepath=/mnt/smb      # + remote tests after the pool tests
  perl benchmark_worker.pl profile=basic pool=tank remotepath=N:\ remote_filesize=65536
  perl benchmark_worker.pl profile=basic remoteonly=yes remotepath=/mnt/smb remote_filesize=8192 start_at=14:30:00   # multi-client

  profile=quick ~1-1.5 min, the others 5-10 min.  Without a runid the id is
  generated as auto_YYYYMMDD_HHMMSS.  Result: last_benchmark.log next to the
  script (rundir=/path to change), containing
    bench_hdr: ...            all parameters/environment of the run
    RESULT <name> = <value> <unit>
    BENCH_DONE ok|error ...   (last line = run finished)
  Only one benchmark per machine: a fixed "benchmark.running" marker makes a
  second run answer "already running".  Cancel: create benchmark_<runid>.cancel.

Remote tests (SMB / NFS / S3) -- remotepath=
  remotepath=<path>   mounted SMB/NFS/S3 path (Windows N:, Linux /mnt/smb, /mnt/nfs, /mnt/rclone-s3).  The mount
                      must exist BEFORE the start, the worker mounts nothing.  After the pool tests the same Perl
                      I/O runs on that path (not in profile steadywrite):
                        seq write/read (1 MB) with client CPU %, 4k random read/write QD1 with p50/p99,
                        open/close round trip, perl_ceiling (what Perl itself can do per stream);
                        from profile basic up also multiuser read 1 vs N streams, concurrent read+write (N+N; same switches
                        multiuser=/mixed=/conc1= as the pool tests), QD16, 64K blocks and metadata ops.
                      RESULT remote_* and perl_ceiling_*; header remotepath / remote_proto (protocol, SMB dialect;
                      on Windows the dialect needs an elevated worker).  Only <remotepath>/csbench_<runid> is
                      written and it is removed again.
                      The N streams are threads on ONE mount = one SMB session, not N separate clients; a real
                      multi-client test needs the worker started on several machines at the same time (see
                      howto.ai/benchmark.info section 13 of the napp-it CS distribution: limits and proposal).
  remote_filesize=<MB>  test file size.  Default: profile quick 2048 MB (fast; reads may be served from cache,
                      the write values are the meaningful ones), every other profile 100% of the LOCAL RAM, never
                      more than 50% of the free space.  A remote SERVER with more RAM keeps part of the file in
                      its cache (ARC): for exact read values set remote_filesize to 100-150% of the RAM of the
                      larger machine (usually the server).
  Notes: Perl only -- for 25G+ / SMB Direct a result near perl_ceiling_* is tool-limited (the log says so), use
         fio/diskspd for exact values.  Set the share's dataset to compression=off.  The client cache cannot be
         switched off over a protocol: open/close and stat values may come from it.  A Samba GUEST mount may create
         a folder but not a file in it (owner nobody, mode 755): mount with credentials or use a share with
         "force user".  Tested: cifs loopback on Linux (profile=basic), Windows mapped drive (check) and a full
         run with a local folder; NFS, rclone-S3 and an elevated Windows run are not tested yet.

Real multi-user test -- several clients at the same time (remoteonly=, start_at=)
  The streams of the remote multiuser/concurrent tests are threads on ONE mount (one SMB session).  A real
  multi-user test runs the worker on SEVERAL machines at the same moment, each with its own mount (own session,
  optionally its own user) of the SAME share.
  remoteonly=yes        no pool tests, no scratch dataset: ONLY the remote tests (needs remotepath, not for steadywrite).
  start_at=<HH:MM[:SS]> local clock (within +-1 h of now).  The worker prepares (creates its test file), waits until
                        that time and then starts the measured phases: the same start_at on all clients = the same
                        moment.  Choose it later than the slowest preparation (file size / write speed + ~20 s); a
                        client that was not ready logs RESULT remote_start_late_s (= not aligned).  RESULT
                        remote_phases_start_epoch = unix time of the first measured phase (compare the clients; the
                        clocks must be NTP-synchronised).
  Per client: the share mounted, perl + the SAME benchmark_worker.pl version, free space for clients x remote_filesize,
  the same profile (basic) and the same remote_filesize, a writable rundir.
  A. By hand (PuTTY / ssh / RDP, one session per client)
     1. Check the clocks on all clients (Linux: date, Windows: w32tm /query /status) and pick start_at = now + 5 min or later.
     2. In EVERY session the same command, then Enter in all of them:
          perl benchmark_worker.pl profile=basic remoteonly=yes remotepath=/mnt/smb remote_filesize=8192 start_at=14:30:00
        (Windows: remotepath=N:\ ...).  Every client writes last_benchmark.log next to the script (rundir=<dir> to change).
     3. Collect the logs of all clients and compare: the SUM of remote_seq_write_mbs / remote_seq_read_mbs / remote_4k_*_iops
        is what the server delivers to N users, the single values show how the load is shared.  Compare with a run on ONE
        client: the aggregate stays the same -> server/network is the limit; it grows -> the single client was the limit.
  B. With the AI (Claude with shell access: ssh/plink to the clients, e.g. Claude Code or the desktop app)
     Give it the client list (ssh-reachable), the share and the mount path per client, the parameters and the task of
     steps 1-3.  Example:
       "Run the benchmark worker as a multi-client test: clients .185, .187 and my-w11, share //192.168.2.112/data
        mounted at /mnt/smb (Windows N:), profile=basic remoteonly=yes remote_filesize=8192, start 5 minutes from now.
        Copy benchmark_worker.pl to every client, start it on all clients in parallel with the same start_at, wait for
        BENCH_DONE, fetch every last_benchmark.log and give me one table: per client and sum of seq write/read MB/s,
        4k iops, p99, the spread of remote_phases_start_epoch and the clients that started late."
     The AI starts the commands in the background (nohup / start), polls the logs, fetches them and builds the table.
     It needs ssh keys or credentials for the clients and your OK to copy the worker and start it.
  Notes: every client writes into its OWN folder csbench_<runid> and removes it again; the test files of all clients
         together must fit into the free space.  Different hardware or mounts (SMB dialect, multichannel) change the
         picture -- the header remote_proto of every client says what was used.  Built and syntax-checked, NOT live-tested
         yet (2026.10.13).
Integration
  The SAME file (same name, same content) ships in the napp-it cs distribution
  as data/menues/_lib/scripts/bench/benchmark_worker.pl and is deployed to a
  cluster member by the benchmark menu (benchmark_director.pl + action.pl),
  which reads exactly the RESULT lines for its comparison table.
  KEEP BOTH COPIES IDENTICAL when changing one -- the repository stores LF, so a
  Windows checkout may show CRLF in the working copy.
