#!/usr/bin/env bash
#
# make-test-ca.sh — create a short-lived CA and localhost server certificate
# for the real HTTPS redirect fixture.
#
# The generated key material is local test material only. The script refuses
# to overwrite an existing output set and prints paths, never private-key
# contents. Install only the generated CA certificate into the dedicated
# simulator; do not add it to a developer or production trust store.
#
# Usage:
#   make-test-ca.sh <empty-output-directory>
#
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <empty-output-directory>" >&2
    exit 2
fi

output_dir="$1"
mkdir -p "${output_dir}"

for path in \
    "${output_dir}/ca.key.pem" \
    "${output_dir}/ca.cert.pem" \
    "${output_dir}/server.key.pem" \
    "${output_dir}/server.cert.pem"; do
    if [[ -e "${path}" ]]; then
        echo "refusing to overwrite existing test certificate: ${path}" >&2
        exit 1
    fi
done

openssl_bin="$(command -v openssl || true)"
if [[ -z "${openssl_bin}" ]]; then
    echo "openssl is required" >&2
    exit 1
fi

umask 077
config_file="$(mktemp "${TMPDIR:-/tmp}/tls-producer-test-ca.XXXXXX.cnf")"
trap 'rm -f "${config_file}"' EXIT

printf '%s\n' \
    '[req]' \
    'distinguished_name = req_distinguished_name' \
    'prompt = no' \
    '[req_distinguished_name]' \
    'CN = TLS Producer local redirect fixture' \
    '[ca_ext]' \
    'basicConstraints = critical,CA:TRUE,pathlen:1' \
    'keyUsage = critical,keyCertSign,cRLSign' \
    '[server_ext]' \
    'basicConstraints = critical,CA:FALSE' \
    'keyUsage = critical,digitalSignature,keyEncipherment' \
    'extendedKeyUsage = serverAuth' \
    'subjectAltName = @server_alt_names' \
    '[server_alt_names]' \
    'DNS.1 = localhost' \
    'IP.1 = 127.0.0.1' \
    > "${config_file}"

"${openssl_bin}" genrsa -out "${output_dir}/ca.key.pem" 3072 >/dev/null 2>&1
"${openssl_bin}" req -x509 -new -sha256 \
    -key "${output_dir}/ca.key.pem" \
    -out "${output_dir}/ca.cert.pem" \
    -days 7 \
    -subj "/CN=TLS Producer local redirect test CA" \
    -config "${config_file}" \
    -extensions ca_ext \
    >/dev/null 2>&1

"${openssl_bin}" genrsa -out "${output_dir}/server.key.pem" 2048 >/dev/null 2>&1
"${openssl_bin}" req -new -sha256 \
    -key "${output_dir}/server.key.pem" \
    -out "${output_dir}/server.csr.pem" \
    -subj "/CN=localhost" \
    -config "${config_file}" \
    >/dev/null 2>&1
"${openssl_bin}" x509 -req -sha256 \
    -in "${output_dir}/server.csr.pem" \
    -CA "${output_dir}/ca.cert.pem" \
    -CAkey "${output_dir}/ca.key.pem" \
    -CAcreateserial \
    -out "${output_dir}/server.cert.pem" \
    -days 7 \
    -extfile "${config_file}" \
    -extensions server_ext \
    >/dev/null 2>&1

rm -f "${output_dir}/server.csr.pem" "${output_dir}/ca.cert.srl"
chmod 600 \
    "${output_dir}/ca.key.pem" \
    "${output_dir}/server.key.pem"
chmod 644 \
    "${output_dir}/ca.cert.pem" \
    "${output_dir}/server.cert.pem"

echo "CA_CERT=${output_dir}/ca.cert.pem"
echo "SERVER_CERT=${output_dir}/server.cert.pem"
echo "SERVER_KEY=${output_dir}/server.key.pem"
