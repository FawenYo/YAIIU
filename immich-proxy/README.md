# Immich Proxy Server

A proxy server that sits between iOS background upload extension and Immich server. It handles the conversion of raw photo data to the multipart/form-data format required by Immich API.

## Background

iOS 26.1 introduces `PHBackgroundResourceUploadExtension` which allows background photo uploads. However, when using `PHAssetResourceUploadJobChangeRequest.createJob`, the system replaces the `httpBody` with raw photo data, ignoring any multipart form-data structure you've set up.

This proxy server solves this problem by:

1. Receiving raw photo data with metadata in headers/query parameters
2. Converting it to the multipart/form-data format expected by Immich
3. Forwarding the properly formatted request to the Immich server

## Architecture

```
┌─────────────────┐     ┌───────────────┐     ┌──────────────┐
│  iOS Device     │────▶│ Immich Proxy  │────▶│ Immich Server│
│                 │     │               │     │              │
│ Background      │     │ /api/assets/  │     │ /api/assets  │
│ Upload Extension│     │ background    │     │              │
│                 │     │               │     │              │
│ Raw photo data  │     │ Convert to    │     │ Multipart    │
│ + Headers       │     │ multipart     │     │ form-data    │
└─────────────────┘     └───────────────┘     └──────────────┘
```

## Features

- **Background Upload Endpoint** (`/api/assets/background`): Converts raw photo data to Immich-compatible multipart format
- **General Proxy**: All other API requests are proxied directly to Immich server
- **Health Check** (`/health`): Simple health check endpoint

## Configuration

Configuration is done via environment variables:

| Variable            | Default                 | Description                   |
| ------------------- | ----------------------- | ----------------------------- |
| `LISTEN_ADDR`       | `:8080`                 | Address and port to listen on |
| `IMMICH_SERVER_URL` | `http://localhost:2283` | URL of the Immich server      |

## Background Upload API

### Endpoint

```
POST /api/assets/background
```

### Headers

| Header               | Required | Description                                        |
| -------------------- | -------- | -------------------------------------------------- |
| `x-api-key`          | Yes      | Immich API key for authentication                  |
| `X-Device-Asset-Id`  | No       | Unique identifier for the asset                    |
| `X-Device-Id`        | No       | Device identifier (default: `ios-immich-uploader`) |
| `X-File-Created-At`  | No       | ISO8601 timestamp of file creation                 |
| `X-File-Modified-At` | No       | ISO8601 timestamp of file modification             |
| `X-Is-Favorite`      | No       | Whether the asset is a favorite (default: `false`) |
| `X-Filename`         | No       | Original filename of the asset                     |
| `X-Content-Type`     | No       | MIME type of the asset                             |

### Request Body

Raw binary data of the photo/video file.

### Response

Returns the response from Immich server:

```json
{
    "id": "ef96f635-61c7-4639-9e60-61a11c4bbfba",
    "duplicate": false
}
```

## Running

### Using Go

```bash
cd immich-proxy
export IMMICH_SERVER_URL=http://your-immich-server:2283
go run .
```

### Using Docker

```bash
docker run -p 8080:8080 \
  -e IMMICH_SERVER_URL=http://your-immich-server:2283 \
  fawenyo/immich-proxy:0.1.0
```

Or build your own:

```bash
cd immich-proxy
docker build -t immich-proxy .
docker run -p 8080:8080 \
  -e IMMICH_SERVER_URL=http://your-immich-server:2283 \
  immich-proxy
```

### Using Helm (Kubernetes)

```bash
# Add values override (optional)
cat > my-values.yaml << EOF
config:
  immichServerURL: "http://immich-server:2283"

ingress:
  enabled: true
  className: nginx
  hosts:
    - host: immich-proxy.example.com
      paths:
        - path: /
          pathType: Prefix
EOF

# Install / Upgrade the chart
helm upgrade -i immich-proxy ./deployment/immich-proxy -f my-values.yaml

# Or install / upgrade with inline values
helm upgrade -i immich-proxy ./deployment/immich-proxy \
  --set config.immichServerURL=http://immich-server:2283
```
