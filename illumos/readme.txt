==========================================================================
 readme.txt -- illumos/ Build- und Hilfsskripte
 (c) 2026 Guenther Alka / napp-it.org -- Projekt: napp-it cs
==========================================================================

Dieser Ordner enthaelt Build- und Hilfsskripte fuer die napp-it cs
Werkzeuge auf OmniOS / illumos. Fuer illumos existieren fuer diese
Werkzeuge KEINE vorgefertigten Binaries -- jedes Skript baut das jeweilige
Werkzeug aus dem Quellcode und (wo sinnvoll) verpackt es in ein
eigenstaendiges Release-Archiv. Das Gegenstueck fuer Oracle Solaris liegt
im Nachbarordner solaris/.

Alle Skripte sind fuer BASH geschrieben:  bash <skript>.sh
(nicht "sh" -- die Skripte pruefen das selbst und brechen sonst mit
"Run with bash" ab.)

Inhalt im Ueberblick:

  rustfs_omnios_1a.sh                 RustFS-Server (S3-Daemon) bauen
  cs-imageindex_omnios_1a.sh          cs-imageindex (Media-Indexer) bauen + verpacken
  build_llamacpp_omnios.sh            llama.cpp llama-server bauen (lokale LLM-Inferenz)
  build.rc.sh                         rustfs-cli installieren/aktualisieren
  build_restic_omnios.txt             Manuelle Notizen: restic kompilieren
  needed_ip_modification_for_rustfs.txt  TCP/UDP-Puffergroessen fuer rustfs anheben

==========================================================================
 rustfs_omnios_1a.sh
==========================================================================
Zweck:
  Baut den RustFS-Server aus dem main-Branch von GitHub fuer
  OmniOS/illumos. RustFS ist der S3-kompatible Speicher-Daemon der
  napp-it cs S3-Dienste.

  Das Skript wendet automatisch alle fuer illumos noetigen
  Quellcode-Anpassungen an:
    - aws-lc-rs durch ring ersetzt (6 Abhaengigkeiten)
    - pprof / pyroscope / jemalloc_pprof / mimalloc deaktiviert
    - brotli alloc-no-stdlib 2.0 -> 3.0 (Duplikat-Konflikt) via
      [patch.crates-io]
    - allocator_reclaim.rs / memory_observability.rs: illumos no-op
      fuer die libmimalloc_sys-Aufrufe
    - main.rs: mimalloc global_allocator entfernt, init_from_env() fix
    - profiling.rs: keine Stubs (unsupported_impl ist bereits exportiert)

  Dies ist das kanonische Skript (Nachfolger der Linie 2a5..2a12; die
  vollstaendige Aenderungshistorie steht im Kopf des Skripts).

Gebrauch:
  bash ./rustfs_omnios_1a.sh

Voraussetzungen:
  - OmniOS mit moeglichst >= 16 GB RAM und mindestens ~40 GB freiem
    Plattenplatz auf dem rpool. Weniger RAM/Plattenplatz wird vom
    Skript selbst abgefedert (siehe Schritt 3 und Schritt 13 unten) --
    es ist keine manuelle Vorbereitung noetig, aber ein sehr enger Pool
    (< ~9 GB frei) fuehrt nur zu einer Warnung, nicht zu einem Abbruch,
    und der Build kann dann an OOM scheitern.
  - System-Rust via pkg (OOCE developer/rust, >= 1.97). Eine veraltete
    rustup-Toolchain aus einem frueheren Build wird automatisch entfernt.
  - bash

Ablauf (13 Schritte):
  1.  Systempakete installieren (inkl. protoc fuer Pulsar-Protobuf-Codegen)
  2.  Rust >= 1.96 sicherstellen (ggf. rustup-Installation)
  3.  Swap pruefen/ergaenzen, falls gesamt < 6 GB (siehe unten)
  4.  Altes Build-Verzeichnis loeschen, frisch von main klonen
  5.  .cargo/config.toml (illumos-Linker gcc) schreiben
  6.  Workspace Cargo.toml patchen
  7.  rustfs/Cargo.toml patchen
  8.  crates/obs/Cargo.toml patchen
  9.  cargo fetch (Cargo.lock neu aufloesen)
  10. brotli lokal patchen (alloc-no-stdlib Duplikat-Konflikt)
  11. Rust-Quelldateien patchen (main.rs, allocator_reclaim.rs,
      memory_observability.rs, profiling.rs -- siehe Liste oben)
  12. RustFS-Console-ZIP herunterladen und nach rustfs/static/ entpacken
  13. Release-Build (siehe unten)
  Danach werden die Startanweisungen ausgegeben.

  Schritt 3 -- dynamische Swap-Ergaenzung (seit 2026-08-09):
    Statt einer festen Groesse (frueher "-V 8g", die auf knappen Pools
    mit "out of space" scheiterte) berechnet das Skript nur so viel
    zusaetzliches Swap-zvol (rpool/swap_build), wie zum Erreichen von
    6 GB Gesamt-Swap fehlt, und prueft vorher den freien Platz auf dem
    Pool (benoetigte Swap-Groesse + 3 GB Build-Headroom fuer target/
    und das Cargo-Registry-Wachstum). Reicht der freie Platz nicht,
    gibt das Skript nur eine WARNUNG aus und faehrt ohne zusaetzliches
    Swap fort, statt mit "set -e" mitten im Lauf abzubrechen. Das
    temporaere zvol wird ueber ein "trap ... EXIT" bei JEDEM
    Skript-Ende automatisch wieder entfernt (Erfolg, Fehler oder
    Ctrl-C) -- es bleibt also kein GB-grosses zvol dauerhaft auf dem
    Pool zurueck.

  Schritt 13 -- codegen-units-Override (seit 2026-08-09):
    Das Skript setzt beim Release-Build IMMER (nicht optional/manuell)
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16, um den Speicherbedarf des
    Linker-Laufs zu senken (Workspace-Default ist codegen-units=1, was
    beim rustfs-Bin-Crate auf einer 14-GB-RAM-Maschine rustc auf ~9 GB
    RSS trieb und den fork() fuer den gcc-Linker unter illumos'
    striktem Swap-Backing-Modell scheitern liess: "Not enough space").
    Mit 16 Einheiten sinkt die Spitzenlast auf ~5,4 GB -- ein kleiner
    Laufzeit-Performance-Kompromiss gegenueber dem Upstream-Default.

Ergebnis:
  RustFS-Binary unter target/release/ im Build-Verzeichnis
  (/root/rustfs bei Standardvorgaben).

==========================================================================
 cs-imageindex_omnios_1a.sh
==========================================================================
Zweck:
  Baut cs-imageindex (den Media-/Bild-Indexer der napp-it cs GUI) aus dem
  Quellcode von github.com/guenther-alka/cs-imageindex und verpackt ein
  vollstaendig eigenstaendiges Release-Archiv.

  HEIC/HEIF- und Video-Dekodierung laeuft ueber das MITgebaute statische
  ffmpeg/ffprobe (ci/build-ffmpeg.sh aus dem Projekt, minimale statische
  LGPL-Konfiguration) -- kein System-libheif, keine ooce-Pakete, kein
  rpath/LD_LIBRARY_PATH-Basteln. Verifiziert auf OmniOS r151058j
  (192.168.2.189) fuer v0.3.0.

Gebrauch:
  bash ./cs-imageindex_omnios_1a.sh

Voraussetzungen:
  - OmniOS, gcc, git, curl, protoc (werden bei Bedarf via pkg installiert)
  - Rust >= 1.75 (sonst automatisch via rustup installiert)
  - mindestens ~4 GB Swap empfohlen (unter 2 GB erscheint eine Warnung)

Ablauf (7 Schritte):
  1.  Systempakete installieren (git, developer/rust, gcc, protoc)
  2.  Rust-Version pruefen, ggf. rustup
  3.  Swap-Check (nur Warnung, wenn < 2 GB)
  4.  Altes Verzeichnis loeschen, frisch von
      github.com/guenther-alka/cs-imageindex klonen
  5.  .cargo/config.toml (illumos-Linker gcc) schreiben
  6.  cargo build --release
  7.  ffmpeg/ffprobe bauen (ci/build-ffmpeg.sh) und das Archiv packen

Ergebnis:
  ~/cs-imageindex-illumos.amd64.tar.gz  -- inhalt:
    cs-imageindex, ffmpeg, ffprobe, models/ (onnx + Lizenzen), README,
    LICENCE + LICENCE-ffmpeg.txt
  Upload z. B. via:  gh release upload <tag> ~/cs-imageindex-illumos.amd64.tar.gz

==========================================================================
 build_llamacpp_omnios.sh
==========================================================================
Zweck:
  Baut llama-server aus llama.cpp (OpenAI-kompatibler lokaler
  Inferenz-Server fuer GGUF-Modelle) auf OmniOS/illumos.

  llama.cpp/ggml hat KEINE offizielle illumos-Unterstuetzung -- das Skript
  wendet die 10 live-verifizierten illumos-Patches automatisch an:
    1.  src/llama-mmap.cpp        RLIMIT_MEMLOCK existiert nicht auf illumos
    2.  vendor/miniaudio.h        C11 _Alignas ist in C++ ungueltig
    3.  tools/mtmd/clip.cpp       pow(int,int) mehrdeutig
    4./5. common/arg.cpp + download.cpp  sys/syslimits.h -> sys/limits.h (__sun)
    6.  common/common.cpp         cache/config-Verzeichnis-Guards (__sun)
    7./8. common/common.cpp       pwd.h include + getpwuid-Guards (__sun)
    9.  tools/mtmd/models/llava.cpp  sqrt(int64_t) mehrdeutig

  Verifiziert auf OmniOS r151058 (gcc 14.3, cmake 4.4, 4 Kerne,
  2026-08-30): llama-server 0.3.0-dev beantwortet /v1/chat/completions
  (getestet mit Qwen2.5-0.5B-Instruct-Q4_K_M).

Gebrauch:
  bash ./build_llamacpp_omnios.sh

Voraussetzungen:
  - Frisches OmniOS (r151058 verifiziert). Die Toolchain
    (gcc14 = developer/gcc14, cmake = ooce/developer/cmake, git, curl,
    gmake bzw. ninja) wird bei Bedarf automatisch via pkg installiert.

Ablauf:
  1.  Toolchain-Sicherstellung (pkg install ...)
  2.  git clone https://github.com/ggml-org/llama.cpp nach /root/llama.cpp
  3.  illumos-Patches per sed (idempotent, kann mehrfach laufen)
  4.  cmake konfigurieren (CPU-only, llama-server, keine Tests/App)
  5.  bauen (parallel) und Binary nach /root/llama-server installieren

Ergebnis:
  /root/llama-server  (dynamische Libs unter /root/llama.cpp/build/bin,
  verlinkt ueber das rpath des Binaries).

==========================================================================
 build.rc.sh
==========================================================================
Zweck:
  Kleines Hilfsskript: installiert bzw. aktualisiert die rustfs-CLI
  (rustfs-cli) aus crates.io via cargo.

Gebrauch:
  bash ./build.rc.sh

Voraussetzungen:
  - cargo im PATH (das Skript wechselt nach /root/.cargo/bin)

==========================================================================
 build_restic_omnios.txt
==========================================================================
Zweck:
  Manuelle Bauanleitung (kein ausfuehrbares Skript) fuer das
  Backup-Werkzeug restic 0.18.1 auf OmniOS.

Gebrauch (Kurzfassung):
  1. pkg install go-126
  2. curl -L https://github.com/restic/restic/archive/refs/heads/master.zip -o restic.zip
  3. unzip restic.zip && cd restic-master
  4. go run build.go
  Test: ./restic version
  -> restic 0.18.1-dev (compiled manually) ... on illumos/amd64

==========================================================================
 needed_ip_modification_for_rustfs.txt
==========================================================================
Zweck:
  Manuelle Notiz: Die illumos-Standardwerte fuer die maximalen TCP/UDP-
  Socket-Puffergroessen sind fuer rustfs zu klein. Vor der Inbetriebnahme
  einmalig erhoehen:

    ipadm set-prop -p max_buf=4194304 tcp
    ipadm set-prop -p max_buf=4194304 udp

==========================================================================
 Aenderungshistorie dieser Datei
==========================================================================
2026-09-01  Umbenannt von _readme.txt zu readme.txt. Inhaltliche Korrektur:
            rustfs_omnios_1a.sh Voraussetzungen -- die codegen-units-
            Override (Schritt 13) ist KEINE manuelle Option fuer wenig
            RAM, sondern wird vom Skript immer automatisch gesetzt.
            Schrittliste 6.-12. praezisiert (statt Sammelgruppe einzeln
            aufgefuehrt, "9. cargo fetch" ist kein Patch-Schritt). Neue
            Absaetze zu Schritt 3 (dynamische Swap-Groesse + Cleanup-Trap)
            und Schritt 13 (Grund/Wirkung der codegen-units-Override)
            ergaenzt.
2026-08-xx  Erstfassung (_readme.txt).

==========================================================================
