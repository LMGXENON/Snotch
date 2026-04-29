# Snotch Backend

Node/Express backend for Snotch script generation and admin tooling.

## Endpoints
- `GET /health`
- `POST /v1/generate/script`
- `POST /v1/generate/bundles`
- `POST /v1/admin/auth`
- `GET /v1/admin/licenses`
- `POST /v1/admin/licenses/create`
- `POST /v1/admin/licenses/revoke`
- `POST /v1/admin/licenses/reactivate`
- `POST /v1/admin/licenses/update`

## Quick Start
1. Install dependencies:
   - `cd backend`
   - `npm install`
2. Configure environment:
   - `cp .env.example .env`
   - set `OPENAI_API_KEY`, `ADMIN_API_KEY`, and secret values
3. Run locally:
   - `npm run dev`

Backend defaults to `http://localhost:8787`.

## Scripts
- `npm run dev` starts watch mode
- `npm run start` runs a production-style process
- `npm run lint` performs syntax checks
- `npm test` runs API smoke tests
- `npm run secrets` generates random secret values
- `npm run import:licenses -- ../licenses.csv` imports license data

## Environment Variables
See `.env.example` for full list.

Important values:
- `OPENAI_API_KEY`: required for generation endpoints
- `OPENAI_MODEL`: defaults to `gpt-4.1-mini`
- `ADMIN_API_KEY`: required for admin access
- `JWT_SECRET`, `LICENSE_PEPPER`: required for secure license hashing/token helpers
- `ADMIN_BYPASS_UNLIMITED`: defaults to `false`
- `CORS_ORIGIN`: optional comma-separated allowlist
- `REQUEST_TIMEOUT_MS`: OpenAI request timeout (default `20000`)
- `TRUST_PROXY`: set to `true` behind reverse proxy

## Production Notes
- Keep all secrets in your host's secret manager.
- Set `NODE_ENV=production` and configure `CORS_ORIGIN` explicitly.
- Move persistence from `data/licenses.json` to a real database for multi-instance deployments.
- Keep OpenAI API keys server-side only.
