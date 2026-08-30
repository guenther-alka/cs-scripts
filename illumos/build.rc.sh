if [ -z "${BASH_VERSION:-}" ]; then
    echo "ERROR: Run with bash, not sh:  bash $0"
    exit 1
fi

cd /root/.cargo/bin
cargo install rustfs-cli --force