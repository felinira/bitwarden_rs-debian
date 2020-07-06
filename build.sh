#!/usr/bin/env bash

set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
SRC="$DIR/bitwarden_rs_git"
SRC_WEB="$DIR/bw_web_builds"
DST="$DIR/dist"

while getopts ":r:o:d:" opt; do
  case $opt in
    r) REF="$OPTARG"
    ;;
    o) OS_VERSION_NAME="$OPTARG"
    ;;
    d) DB_TYPE="$OPTARG"
    ;;
    \?) echo "Invalid option -$OPTARG" >&2
    ;;
  esac
done
if [ -z "$REF" ]; then REF=$(curl -s https://api.github.com/repos/dani-garcia/bitwarden_rs/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' | cut -c 1-); fi
if [ -z "$REF_WEB" ]; then REF_WEB=$(curl -s https://api.github.com/repos/dani-garcia/bw_web_builds/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' | cut -c 1-); fi
if [ -z "$OS_VERSION_NAME" ]; then OS_VERSION_NAME='buster'; fi
if [ -z "$DB_TYPE" ]; then DB_TYPE="sqlite"; fi

# Clone bitwarden_rs
if [ ! -d "$SRC" ]; then
  git clone https://github.com/dani-garcia/bitwarden_rs.git "$SRC"
fi
cd "$SRC" || exit
CREF="$(git branch | grep \* | cut -d ' ' -f2)"
if [ "$CREF" != "$REF" ]; then
  git fetch --tags
  git checkout "$REF" --force
else
  git clean -d -f
  git pull
fi
cd - || exit

# Clone bitwarden_web patches
if [ ! -d "$SRC_WEB" ]; then
  git clone https://github.com/dani-garcia/bw_web_builds.git
fi
cd "$SRC_WEB" || exit
CREF="$(git branch | grep \* | cut -d ' ' -f2)"
if [ "$CREF" != "$REF_WEB" ]; then
  git fetch --tags
  git checkout "$REF_WEB" --force
else
  git clean -d -f
  git pull
fi
cd - || exit

# Prepare EnvFile
CONFIG="$DIR/debian/config.env"
cp "$SRC/.env.template" "$CONFIG"
sed -i "s#\# DATA_FOLDER=data#DATA_FOLDER=/var/lib/bitwarden_rs#" "$CONFIG"
sed -i "s#\# WEB_VAULT_FOLDER=web-vault/#WEB_VAULT_FOLDER=/usr/share/bitwarden_rs/web-vault/#" "$CONFIG"
sed -i "s/Uncomment any of the following lines to change the defaults/Uncomment any of the following lines to change the defaults\n\n## Warning\n## The default systemd-unit does not allow any custom directories.\n## Be sure to check if the service has appropriate permissions before you set custom paths./g" "$CONFIG"


mkdir -p "$DST"

# Prepare Dockerfile

# Prepare Systemd-unit
SYSTEMD_UNIT="$DIR/debian/bitwarden_rs.service"
if [ "$DB_TYPE" = "mysql" ]; then
  sed -i "s/After=network.target/After=network.target mysqld.service\nRequires=mysqld.service/g" "$SYSTEMD_UNIT"
elif [ "$DB_TYPE" = "postgresql" ]; then
  sed -i "s/After=network.target/After=network.target postgresql.service\nRequires=postgresql.service/g" "$SYSTEMD_UNIT"
fi

cd "$SRC"
if [ "$DB_TYPE" = "mysql" ]; then
cargo build --features mysql --release
elif [ "$DB_TYPE" = "postgresql" ]; then
cargo build --features postgresql --release
else
cargo build --features sqlite --release
fi

cd "$SRC_WEB"
VAULT_VERSION="$REF_WEB" ./package_web_vault.sh

cd "$DIR"
rm -rf bitwarden_package
mkdir -p bitwarden_package/DEBIAN
mkdir -p bitwarden_package/usr/bin
mkdir -p bitwarden_package/usr/lib/systemd/system
mkdir -p bitwarden_package/etc/bitwarden_rs
mkdir -p bitwarden_package/usr/share/bitwarden_rs

cp "debian/control" "bitwarden_package/DEBIAN/control"
cp "debian/postinst" "bitwarden_package/DEBIAN/postinst"
cp "debian/conffiles" "bitwarden_package/DEBIAN/conffiles"
cp "$SRC/Rocket.toml" "bitwarden_package/etc/bitwarden_rs"
cp "debian/config.env" "bitwarden_package/etc/bitwarden_rs"
cp "debian/bitwarden_rs.service" "bitwarden_package/usr/lib/systemd/system"
cp -r "$SRC_WEB/web-vault/build" "bitwarden_package/usr/share/bitwarden_rs/web-vault"
cp -r "$SRC/target/release/bitwarden_rs" "bitwarden_package/usr/bin/"

cd "$DIR/bitwarden_package"
dpkg-deb --build . bitwarden-rs.deb
