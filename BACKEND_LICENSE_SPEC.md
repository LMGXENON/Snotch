# Snotch Backend License + Abuse Protection Spec

## Activation Endpoint
- Method: POST
- Path: /v1/license/activate
- Auth: none (public endpoint, rate-limited)
- Request JSON:
  - licenseKey: string
  - deviceId: string
  - appVersion: string
  - platform: string
- Success JSON:
  - ok: true
  - token: string (signed token)
  - expiresAt: string (ISO8601)
  - devicesAllowed: number
  - message: string (optional)
- Failure JSON:
  - ok: false
  - message: string

## Validation Endpoint
- Method: POST
- Path: /v1/license/validate
- Auth: none (token included in body, endpoint rate-limited)
- Request JSON:
  - token: string
  - licenseKey: string
  - deviceId: string
  - appVersion: string
  - platform: string
- Success JSON:
  - ok: true
  - expiresAt: string (ISO8601)
  - message: string (optional)
- Failure JSON:
  - ok: false
  - message: string

## Script Generation Endpoint
- Method: POST
- Path: /v1/generate/script
- Auth: Bearer license token
- Request JSON:
  - topic, audience, tone, goal, styleProfile, targetMinutes, useCues
- Success JSON:
  - ok: true
  - script: string

## Rate Limits
- Activation:
  - Per IP: 20 requests / 15 min
  - Per license key: 10 requests / hour
- Script generation:
  - Per license: 60 requests / hour
  - Per device: 40 requests / hour
  - Per IP: 120 requests / hour

## Abuse Detection Rules
- Flag if one license activates on more than allowed devices quickly.
- Flag if same license appears from impossible geolocation hops.
- Flag if request bursts exceed 5x average baseline.
- Apply temporary cooldown and require manual review for repeated abuse.

## Operational Notes
- Keep OpenAI API key server-side only.
- Return generic error bodies for denied requests.
- Log request id, license hash, device id hash, IP hash, timestamp.
- Use short token expiry (24-72h) and allow offline grace in client.

## License Key Generation
- Use `scripts/generate_license_keys.py` to issue keys in batch.
- Save only `license_hash` in production database.
- Send `license_key` once to customer after purchase.
- Keep pepper/secret in server environment, never in client app.
