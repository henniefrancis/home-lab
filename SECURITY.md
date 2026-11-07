# Security Policy

## Reporting a vulnerability

Please do **not** open a public issue for security problems.

Use GitHub's private vulnerability reporting: open the repository's **Security** tab and choose
**Report a vulnerability**. I will acknowledge a report within a few days and aim to fix or mitigate
confirmed issues promptly. This is a personal project maintained on a best-effort basis.

## Scope

This repository holds infrastructure-as-code and configuration for a personal home lab. It is
published as a reference. Findings that matter most:

- Secrets or credentials committed to the repository or its history.
- Misconfigurations that would expose home lab services beyond the LAN and tailnet.
- Over-broad IAM or trust policies in the Terraform code.

## Secret handling

- No secrets, real domain names, account IDs or personal email addresses are committed.
  Secrets live in AWS SSM Parameter Store and are fetched at deploy time; other real values live in
  HCP Terraform workspace variables and SSM String parameters.
- `gitleaks` runs in CI and as a pre-commit hook. Enable GitHub secret scanning and push protection
  on any fork.
- If you find a leaked secret in this repository, report it privately as above.
