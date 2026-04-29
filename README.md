# Snotch

Say it exactly how you meant it.

Snotch is a voice-synced teleprompter for macOS with a notch-style overlay, script editor, AI-assisted script generation, and backend services for generation and admin tooling.

## Hero Section

The product hero experience is built around a live notch-style prompter preview.

- **Tagline:** "Snotch - Say it exactly how you meant it."
- **Visual concept:** Floating notch UI with animated scrolling script lines.
- **Where it lives:**
  - `landing page/index.html` (header and notch shell)
  - `landing page/assets/main.js` (`loadPrompterText`, `initNotchPrompter`)
  - `landing page/assets/prompter.txt` (editable hero script lines)

If you want to change the hero prompter text, update `landing page/assets/prompter.txt`.

## Features

### macOS app (SwiftUI)

- Voice-aware script scrolling that follows speaking cadence.
- Two notch reading modes:
  - **Highlighted:** current line emphasis
  - **Continuous:** smooth scrolling, no per-line highlight
- Built-in **Audio Tuning**:
  - Noise Gate
  - Input Gain
  - Live VU meter
- Script management:
  - Create, rename, delete
  - Search scripts
  - Drag-and-drop reorder in sidebar
- Script import/export:
  - Import: `.txt`, `.md`, `.docx`, `.pdf`
  - Export: TXT, Markdown, PDF
- Drag-and-drop import directly into:
  - Main app window
  - Notch overlay
- AI script generator with options for:
  - Topic, audience, tone, goal
  - Optional length target
  - Optional teleprompter cue insertion
  - Optional style matching from recorded speech sample
- In-script teleprompter directives:
  - `<break>`
  - `<slow>`
  - `<fast>`
  - `<focus>`
  - `<hold Ns>`
- Overlay quick editor (double-click notch to edit active script quickly).
- Keyboard controls:
  - `Cmd+P` Play/Stop
  - `Shift+Up/Down` manual line scroll
  - `Cmd+[` toggle sidebar
  - `Esc` close app

### Backend (Node.js + Express)

- Health endpoint.
- Script generation endpoints.
- Bundle idea generation endpoint.
- Admin auth endpoint.
- Admin license management endpoints (list/create/revoke/reactivate/update).
- Security middleware (`helmet`, CORS controls, rate limits).
- Flat-file storage for license records (`backend/data/licenses.json`).

### Landing page

- Notch-themed hero header and animated prompter simulation.
- Dynamic line loading from `assets/prompter.txt`.
- Mobile/desktop interaction handling for demo media.

## Installation

## Prerequisites

- macOS
- Xcode 15+
- Node.js 18+ and npm
- Python 3.10+ (for license key utility scripts)

## 1) Clone repository

```bash
git clone https://github.com/LMGXENON/Snotch.git
cd Snotch
```

## 2) Backend setup

```bash
cd backend
npm install
cp .env.example .env
```

Set values in `.env`:

- `OPENAI_API_KEY`
- `ADMIN_API_KEY`
- `JWT_SECRET`
- `LICENSE_PEPPER`
- optional: `OPENAI_MODEL`, `CORS_ORIGIN`, `REQUEST_TIMEOUT_MS`, `TRUST_PROXY`

Run backend locally:

```bash
npm run dev
```

Backend default URL: `http://localhost:8787`

## 3) macOS app setup

From repository root:

```bash
open Snotch.xcodeproj
```

Then in Xcode:

1. Select scheme **Snotch**.
2. Choose a local macOS run target.
3. Build and Run.

## 4) Optional: run landing page locally

```bash
cd "landing page"
python3 -m http.server 5500
```

Open: `http://localhost:5500`

## Usage

## Quick start

1. Launch Snotch.
2. Complete onboarding permissions (microphone, speech recognition, optional accessibility).
3. Create or import a script.
4. Press **Play** (or `Cmd+P`) to start listening and auto-scroll.
5. Adjust **Audio Settings** (Noise Gate / Input Gain) if detection is too sensitive or not sensitive enough.

## Audio tuning tips

- **Higher Noise Gate**: filters room/keyboard noise; requires louder speech.
- **Lower Noise Gate**: more sensitive; captures softer voice.
- **Higher Input Gain**: boosts weak microphone signals.
- Use the **VU meter** to see live input level while tuning.

## Script directives

You can place tags directly in script text to control pacing/behavior:

- `<break>` pause at cue boundary
- `<slow>` slower section
- `<fast>` faster section
- `<focus>` visual emphasis section
- `<hold 1.2s>` timed hold before continuing

## Useful commands

### Backend

```bash
npm run dev
npm run start
npm run lint
npm test
npm run secrets
npm run import:licenses -- ../licenses.csv
```

### License key generation (root)

```bash
python3 scripts/generate_license_keys.py --count 50 --prefix SNTCH --out licenses.csv
```

## API summary

Primary backend routes:

- `GET /health`
- `POST /v1/generate/script`
- `POST /v1/generate/bundles`
- `POST /v1/admin/auth`
- `GET /v1/admin/licenses`
- `POST /v1/admin/licenses/create`
- `POST /v1/admin/licenses/revoke`
- `POST /v1/admin/licenses/reactivate`
- `POST /v1/admin/licenses/update`

See also:

- `backend/README.md`
- `BACKEND_LICENSE_SPEC.md`

## Project structure

```text
Snotch/
  Snotch/                 # macOS SwiftUI app
  Snotch.xcodeproj/       # Xcode project
  backend/                # Node/Express backend
  landing page/           # marketing/hero page assets
  scripts/                # utility scripts (license generation)
  BACKEND_LICENSE_SPEC.md
```

## License

There is currently **no root OSS LICENSE file** in this repository.

Until a license file is added, treat this project as **all rights reserved** by default.

For backend license key workflow details, see `BACKEND_LICENSE_SPEC.md`.
