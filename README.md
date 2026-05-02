# mano

Flutter app with two separate backend paths:

- `Try On` uses `ADMIN_API_BASE_URL` (default: `https://unsent-party-luckless.ngrok-free.dev`)
- `Clothes image search` uses `CLOTHING_IMAGE_API_BASE_URL` (default: local API)

## Local Clothing API

This repo includes a local FastAPI service at `tools/clothing_api`.

1. Run API only:
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_local_clothing_api.ps1
```

2. Run app + local clothing API together:
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_app_with_local_clothing_api.ps1
```

The app will call:
- `http://10.0.2.2:8000/api/v1/clothing/image` on Android emulator
- `http://127.0.0.1:8000/api/v1/clothing/image` and `http://localhost:8000` are also in fallback candidates

If you run on a real phone, pass your LAN host:
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_app_with_local_clothing_api.ps1 `
  -AppClothingApiBaseUrl http://192.168.1.10:8000
```

## Dart Defines

You can override endpoints explicitly:

```powershell
flutter run `
  --dart-define=ADMIN_API_BASE_URL=https://unsent-party-luckless.ngrok-free.dev `
  --dart-define=CLOTHING_IMAGE_API_BASE_URL=http://10.0.2.2:8000
```
