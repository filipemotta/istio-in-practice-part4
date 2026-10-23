#!/usr/bin/env bash
# Downloads the pinned CLIs used by the lab into ./bin (gitignored), each one
# checked against the SHA-256 published with its release.
# Idempotent: a binary is only downloaded when missing or at another version.
# Supports darwin/linux on arm64/amd64. No sudo, nothing outside ./bin.
set -euo pipefail

ISTIO_VERSION="1.31.2"
KUBECTL_VERSION="v1.37.1"   # node image is v1.37.0 (kind v0.33.0 default); kubectl skew +/-1 is supported
KIND_VERSION="v0.33.0"
YQ_VERSION="v4.54.1"        # mikefarah/yq, used by ci/envoyfilter-lint.sh

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${REPO_ROOT}/bin"
mkdir -p "${BIN}"

case "$(uname -s)" in
  Darwin) OS="darwin"; ISTIO_OS="osx" ;;
  Linux)  OS="linux";  ISTIO_OS="linux" ;;
  *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  arm64|aarch64) ARCH="arm64" ;;
  x86_64|amd64)  ARCH="amd64" ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

have_version() { # $1 binary, $2 expected substring of the version output, rest: version args
  local out
  [ -x "${BIN}/$1" ] || return 1
  out="$("${BIN}/$1" "${@:3}" 2>/dev/null)" || return 1
  [[ "${out}" == *"$2"* ]]
}
sha256_of() { local s; s="$(shasum -a 256 "$1" 2>/dev/null || sha256sum "$1")"; printf '%s' "${s%% *}"; }
# check_sha <file> <expected sha256> <name>
check_sha() {
  local got
  got="$(sha256_of "$1")"
  if [ -z "$2" ] || [ "$2" != "${got}" ]; then
    echo "$3: checksum mismatch (want ${2:-none}, got ${got})" >&2
    exit 1
  fi
}

if have_version istioctl "${ISTIO_VERSION}" version --remote=false; then
  echo "istioctl ${ISTIO_VERSION} already in bin/"
else
  echo "downloading istioctl ${ISTIO_VERSION} (${ISTIO_OS}-${ARCH})"
  tmp="$(mktemp -d)"
  pkg="istioctl-${ISTIO_VERSION}-${ISTIO_OS}-${ARCH}.tar.gz"
  base="https://github.com/istio/istio/releases/download/${ISTIO_VERSION}"
  curl -sSfL "${base}/${pkg}" -o "${tmp}/${pkg}"
  curl -sSfL "${base}/${pkg}.sha256" -o "${tmp}/sum"
  check_sha "${tmp}/${pkg}" "$(awk '{ print $1 }' "${tmp}/sum")" istioctl
  tar -xzf "${tmp}/${pkg}" -C "${tmp}" istioctl
  mv "${tmp}/istioctl" "${BIN}/istioctl"
  chmod +x "${BIN}/istioctl"
  rm -rf "${tmp}"
fi

if have_version kubectl "${KUBECTL_VERSION}" version --client; then
  echo "kubectl ${KUBECTL_VERSION} already in bin/"
else
  echo "downloading kubectl ${KUBECTL_VERSION} (${OS}/${ARCH})"
  tmp="$(mktemp -d)"
  base="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}"
  curl -sSfL "${base}/kubectl" -o "${tmp}/kubectl"
  check_sha "${tmp}/kubectl" "$(curl -sSfL "${base}/kubectl.sha256" | awk '{ print $1 }')" kubectl
  mv "${tmp}/kubectl" "${BIN}/kubectl"
  chmod +x "${BIN}/kubectl"
  rm -rf "${tmp}"
fi

if have_version kind "${KIND_VERSION} " version; then
  echo "kind ${KIND_VERSION} already in bin/"
else
  echo "downloading kind ${KIND_VERSION} (${OS}-${ARCH})"
  tmp="$(mktemp -d)"
  base="https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}"
  curl -sSfL "${base}/kind-${OS}-${ARCH}" -o "${tmp}/kind"
  check_sha "${tmp}/kind" "$(curl -sSfL "${base}/kind-${OS}-${ARCH}.sha256sum" | awk '{ print $1 }')" kind
  mv "${tmp}/kind" "${BIN}/kind"
  chmod +x "${BIN}/kind"
  rm -rf "${tmp}"
fi

if have_version yq "${YQ_VERSION}" --version; then
  echo "yq ${YQ_VERSION} already in bin/"
else
  echo "downloading yq ${YQ_VERSION} (${OS}_${ARCH})"
  tmp="$(mktemp -d)"
  base="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}"
  curl -sSfL "${base}/yq_${OS}_${ARCH}" -o "${tmp}/yq"
  curl -sSfL "${base}/checksums" -o "${tmp}/checksums"
  # The checksums file lists many hashes per binary; SHA-256 is the 18th
  # (see checksums_hashes_order in the release), i.e. field 19 after the name.
  check_sha "${tmp}/yq" "$(awk -v f="yq_${OS}_${ARCH}" '$1 == f { print $19 }' "${tmp}/checksums")" yq
  mv "${tmp}/yq" "${BIN}/yq"
  chmod +x "${BIN}/yq"
  rm -rf "${tmp}"
fi

echo "binaries in ${BIN}:"
"${BIN}/istioctl" version --remote=false
"${BIN}/kubectl" version --client | sed -n 1p
"${BIN}/kind" version
"${BIN}/yq" --version
