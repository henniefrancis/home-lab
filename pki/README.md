# PKI for IAM Roles Anywhere

Config templates and scripts for the offline CA and the two Raspberry Pi identities. Nothing secret lives in this folder, and
`*.key`, `*.csr` and `*.crt` are git-ignored.

| File | Purpose |
|------|---------|
| `openssl-ca.cnf` | CA certificate template (CN `home-lab-offline-ca`, CA:true, pathlen 0) |
| `openssl-leaf.cnf` | Extensions for the Pi certs (CA:false, digitalSignature, clientAuth) |
| `../scripts/pki/new-ca.sh` | Laptop: create the offline CA (ECDSA P-384, encrypted key, 5 years) |
| `../scripts/pki/pi-csr.sh` | Pi: generate the keys and CSRs |
| `../scripts/pki/sign.sh` | Laptop: validate a CSR and sign it (1 year) |
| `../scripts/pki/pi-install-cert.sh` | Pi: validate and install a signed cert |

Subjects are exactly `CN=home-lab-pi-traefik` and `CN=home-lab-pi-host`, each with `OU=<pki_generation>` (default `gen-1`), issued by
`CN=home-lab-offline-ca`. These must match the trust policies in `terraform/edge/iam-dns01.tf` and `iam-pi-host.tf`.
Step-by-step commands: `docs/runbooks/m2-pi-setup.md`.
