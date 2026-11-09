# Runbook: certificate, staging to production (pointer)

The certificate switch is part of the single ordered M6 cutover: see `m6-go-live.md`, steps 1 to 4:

1. ACME switch to production (`config/lab.env`, the staging store is kept)
2. verify the chain issuer
3. CAA `accounturi` through Terraform
4. HSTS raised in steps, only after the alerting in `alerting.md` is live

Each step there has its own verify and rollback. Day-to-day certificate monitoring is `alerting.md`.
