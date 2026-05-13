

<h1 align="center">Outfit Advisor  - AI Outfit Advisor</h1>

<p align="center">
  Smart wardrobe management, weather-based outfit recommendations, and virtual try-on in one Flutter app.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Dart-0175C2?style=for-the-badge&logo=dart&logoColor=white" alt="Dart" />
  <img src="https://img.shields.io/badge/Flutter-02569B?style=for-the-badge&logo=flutter&logoColor=white" alt="Flutter" />
  <img src="https://img.shields.io/badge/Python-3776AB?style=for-the-badge&logo=python&logoColor=white" alt="Python" />
  <img src="https://img.shields.io/badge/FastAPI-009688?style=for-the-badge&logo=fastapi&logoColor=white" alt="FastAPI" />
  <img src="https://img.shields.io/badge/Supabase-3FCF8E?style=for-the-badge&logo=supabase&logoColor=white" alt="Supabase" />
  <img src="https://img.shields.io/badge/PostgreSQL-4169E1?style=for-the-badge&logo=postgresql&logoColor=white" alt="PostgreSQL" />
</p>

## Overview

Outfit Advisor  is a Flutter app that helps users:

- Manage a personal wardrobe
- Get weather-aware style suggestions
- Generate AI-driven outfits
- Run virtual try-on through an external generation API

The project also includes a local FastAPI clothing image service used to fetch product-style outfit images.

## Core Features

- Authentication and profile data powered by Supabase
- Wardrobe item management (tops, bottoms, shoes, jackets, dresses, accessories)
- Weather card and weather-adapted suggestions based on user location
- Outfit generation modes:
  - `Use My Wardrobe`
  - `Mix & Match`
  - `Full Outfit Suggestion`
- Try-on flow using avatar + selected garments
- Local clothing image API with Bing -> DuckDuckGo -> Google fallback chain

## Tech Stack

- Frontend: Flutter, Dart, Provider
- Backend/Data: Supabase (PostgreSQL + Auth)
- Local API: FastAPI (Python)
- AI Integrations: Gemini / OpenRouter compatible configuration

## Project Structure

```text
Outfit Advisor /
|-- lib/
|   |-- config/           # dart-define and service configs
|   |-- models/
|   |-- providers/
|   |-- screens/
|   |-- services/
|   |-- theme/
|   `-- widgets/
|-- tools/clothing_api/   # Local FastAPI service
|-- scripts/              # PowerShell helper scripts
`-- assets/images/
```

## Quick Start

### 1) Prerequisites

- Flutter SDK (with Dart `^3.11.1`)
- Python 3.10+ (for local clothing API)
- Android Studio / Xcode (depending on target platform)

### 2) Install dependencies

```powershell
flutter pub get
```

### 3) Run app (basic)

```powershell
flutter run
```

## Run Local Clothing API

This repository includes a local FastAPI service under `tools/clothing_api`.

### API only

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_local_clothing_api.ps1
```

### App + local API together

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_app_with_local_clothing_api.ps1
```

Default API target behavior:

- Android emulator: `http://10.0.2.2:8000/api/v1/clothing/image`
- Additional fallback candidates: `http://127.0.0.1:8000` and `http://localhost:8000`

If running on a physical phone, pass your LAN IP:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_app_with_local_clothing_api.ps1 `
  -AppClothingApiBaseUrl http://192.168.1.10:8000
```

## Runtime Configuration (`--dart-define`)

### Core

| Variable | Purpose | Default |
|---|---|---|
| `ADMIN_API_BASE_URL` | Try-on generation API base URL | `https://unsent-party-luckless.ngrok-free.dev` |
| `ADMIN_API_BASE_URLS` | Comma-separated fallback base URLs | `""` |
| `ADMIN_API_TIMEOUT_SECONDS` | Admin API timeout in seconds | `180` |
| `CLOTHING_IMAGE_USE_EXTERNAL_API` | Enable external clothing image API mode | `false` |
| `CLOTHING_IMAGE_API_BASE_URL` | Single clothing image API base URL | `""` |
| `CLOTHING_IMAGE_API_BASE_URLS` | Comma-separated clothing image API base URLs | `""` |
| `CLOTHING_IMAGE_ALLOW_FALLBACK` | Allow generic image fallback on failures | `true` |
| `ADMIN_EMAILS` | Comma-separated admin emails | `""` |

### AI Provider

| Variable | Purpose |
|---|---|
| `AI_PROVIDER` | `gemini` or `openrouter` |
| `AI_MODEL` | Explicit model override |
| `AI_API_KEY` / `AI_API_KEYS` | Provider key(s), comma-separated supported |
| `AI_BASE_URL` | Optional provider base URL override |
| `GEMINI_API_KEY` / `GEMINI_API_KEYS` | Gemini key(s) |
| `GEMINI_MODEL` | Gemini model override |
| `OPENROUTER_API_KEY` / `OPENROUTER_API_KEYS` | OpenRouter key(s) |
| `OPENROUTER_MODEL` | OpenRouter model override |
| `OPENROUTER_HTTP_REFERER` | Optional OpenRouter referer header |
| `OPENROUTER_X_TITLE` | Optional OpenRouter title header |

### Magic Hour (optional)

| Variable | Purpose | Default |
|---|---|---|
| `MAGIC_HOUR_BASE_URL` | Magic Hour API base URL | `https://api.magichour.ai` |
| `MAGIC_HOUR_API_KEY` / `MAGIC_HOUR_API_KEYS` | API key(s) | `""` |

### Example run with explicit config

```powershell
flutter run `
  --dart-define=ADMIN_API_BASE_URL=https://your-tryon-api.example.com `
  --dart-define=CLOTHING_IMAGE_USE_EXTERNAL_API=true `
  --dart-define=CLOTHING_IMAGE_API_BASE_URL=http://10.0.2.2:8000 `
  --dart-define=AI_PROVIDER=gemini `
  --dart-define=AI_API_KEY=your_key_here
```

## Local Clothing API Endpoints

- `GET /` health/info
- `GET /api/v1/clothing/image?name=...&type=...&index=0` stream image
- `GET /api/v1/clothing/search?name=...&type=...&max_results=5` metadata search

Swagger docs are available at `http://127.0.0.1:8000/docs` when the local API is running.

## Notes

- Keep secrets and API keys out of source control in production projects.
- For mobile testing, remember that `10.0.2.2` is Android emulator loopback to host machine.
