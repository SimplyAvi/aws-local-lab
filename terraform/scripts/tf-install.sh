#!/usr/bin/env bash
# Install a pinned Terraform into terraform/.bin/ if it is not already there.
#
# We deliberately do NOT install `tflocal` (the terraform-local pip package):
# this track wires LocalStack through a committed providers.tf instead, so there
# is no Python/pip runtime dependency. See terraform/README.md.
set -euo pipefail

TF_VERSION="${TF_VERSION:-1.5.7}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${HERE}/.bin"
TF_BIN="${BIN_DIR}/terraform"

if [ -x "${TF_BIN}" ] && "${TF_BIN}" version | head -n1 | grep -q "v${TF_VERSION}"; then
  echo "terraform v${TF_VERSION} already installed at ${TF_BIN}"
  exit 0
fi

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$(uname -m)" in
  x86_64 | amd64) arch="amd64" ;;
  arm64 | aarch64) arch="arm64" ;;
  *)
    echo "unsupported arch: $(uname -m)" >&2
    exit 1
    ;;
esac

zip_name="terraform_${TF_VERSION}_${os}_${arch}.zip"
url="https://releases.hashicorp.com/terraform/${TF_VERSION}/${zip_name}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

echo "downloading ${url}"
curl -fsSL -o "${tmp_dir}/${zip_name}" "${url}"
unzip -o -q "${tmp_dir}/${zip_name}" -d "${tmp_dir}"

mkdir -p "${BIN_DIR}"
mv "${tmp_dir}/terraform" "${TF_BIN}"
chmod +x "${TF_BIN}"

"${TF_BIN}" version
echo "installed terraform v${TF_VERSION} -> ${TF_BIN}"
