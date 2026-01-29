package handlers

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"path/filepath"
	"strings"
	"time"
)

// GetClientIP extracts the real client IP from the request.
// It checks X-Forwarded-For and X-Real-IP headers first (for proxy scenarios),
// then falls back to RemoteAddr.
func GetClientIP(r *http.Request) string {
	// Check X-Forwarded-For header first (may contain multiple IPs)
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		// X-Forwarded-For can contain multiple IPs: client, proxy1, proxy2...
		// The first IP is typically the original client
		ips := strings.Split(xff, ",")
		if len(ips) > 0 {
			clientIP := strings.TrimSpace(ips[0])
			if clientIP != "" {
				return clientIP
			}
		}
	}

	// Check X-Real-IP header (set by NGINX)
	if xri := r.Header.Get("X-Real-IP"); xri != "" {
		return xri
	}

	// Check CF-Connecting-IP header (Cloudflare)
	if cfIP := r.Header.Get("CF-Connecting-IP"); cfIP != "" {
		return cfIP
	}

	// Fall back to RemoteAddr
	return r.RemoteAddr
}

// BackgroundUploadRequest represents the metadata for background upload
// These are passed as URL query parameters or custom headers since
// iOS PHBackgroundResourceUploadExtension replaces httpBody with photo data
type BackgroundUploadRequest struct {
	DeviceAssetID  string `json:"deviceAssetId"`
	DeviceID       string `json:"deviceId"`
	FileCreatedAt  string `json:"fileCreatedAt"`
	FileModifiedAt string `json:"fileModifiedAt"`
	IsFavorite     string `json:"isFavorite"`
	Filename       string `json:"filename"`
	ContentType    string `json:"contentType"`
	ICloudId       string `json:"iCloudId,omitempty"`
	Latitude       string `json:"latitude,omitempty"`
	Longitude      string `json:"longitude,omitempty"`
}

// MobileAppMetadata represents the metadata value for mobile-app key
type MobileAppMetadata struct {
	ICloudId       string `json:"iCloudId,omitempty"`
	CreatedAt      string `json:"createdAt,omitempty"`
	AdjustmentTime string `json:"adjustmentTime,omitempty"`
	Latitude       string `json:"latitude,omitempty"`
	Longitude      string `json:"longitude,omitempty"`
}

// RemoteAssetMetadataItem represents a metadata item to send to Immich
type RemoteAssetMetadataItem struct {
	Key   string            `json:"key"`
	Value MobileAppMetadata `json:"value"`
}

// BackgroundUploadResponse represents the response from Immich server
type BackgroundUploadResponse struct {
	ID        string `json:"id"`
	Duplicate bool   `json:"duplicate"`
}

// BackgroundUploadHandler handles the background upload endpoint
// This endpoint receives raw photo/video data and converts it to
// the multipart/form-data format expected by Immich
func BackgroundUploadHandler(immichServerURL string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		clientIP := GetClientIP(r)

		if r.Method != http.MethodPost {
			http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
			return
		}

		log.Printf("[%s] Background upload request received", clientIP)

		// Extract metadata from headers (since body contains raw photo data)
		metadata := extractMetadata(r)
		log.Printf("[%s] Metadata: %+v", clientIP, metadata)

		// Read the raw photo data from request body
		photoData, err := io.ReadAll(r.Body)
		if err != nil {
			log.Printf("[%s] Failed to read request body: %v", clientIP, err)
			http.Error(w, "Failed to read request body", http.StatusBadRequest)
			return
		}
		defer r.Body.Close()

		log.Printf("[%s] Received %d bytes of photo data", clientIP, len(photoData))

		// Create multipart form data for Immich
		body, contentType, err := createMultipartRequest(metadata, photoData)
		if err != nil {
			log.Printf("[%s] Failed to create multipart request: %v", clientIP, err)
			http.Error(w, "Failed to create multipart request", http.StatusInternalServerError)
			return
		}

		// Forward to Immich server
		immichURL := fmt.Sprintf("%s/api/assets", immichServerURL)
		req, err := http.NewRequest(http.MethodPost, immichURL, body)
		if err != nil {
			log.Printf("[%s] Failed to create request: %v", clientIP, err)
			http.Error(w, "Failed to create request", http.StatusInternalServerError)
			return
		}

		// Set headers
		req.Header.Set("Content-Type", contentType)
		req.Header.Set("Accept", "application/json")

		// Forward the API key from the original request
		if apiKey := r.Header.Get("x-api-key"); apiKey != "" {
			req.Header.Set("x-api-key", apiKey)
		}

		// Send request to Immich
		client := &http.Client{
			Timeout: 5 * time.Minute, // Large files may take time
		}
		resp, err := client.Do(req)
		if err != nil {
			log.Printf("[%s] Failed to forward request to Immich: %v", clientIP, err)
			http.Error(w, "Failed to forward request to Immich", http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()

		// Copy response from Immich back to client
		responseBody, err := io.ReadAll(resp.Body)
		if err != nil {
			log.Printf("[%s] Failed to read Immich response: %v", clientIP, err)
			http.Error(w, "Failed to read Immich response", http.StatusBadGateway)
			return
		}

		log.Printf("[%s] Immich response status: %d, body: %s", clientIP, resp.StatusCode, string(responseBody))

		// Copy response headers
		for key, values := range resp.Header {
			for _, value := range values {
				w.Header().Add(key, value)
			}
		}

		w.WriteHeader(resp.StatusCode)
		w.Write(responseBody)
	}
}

// extractMetadata extracts upload metadata from request headers
func extractMetadata(r *http.Request) BackgroundUploadRequest {
	// Try to get metadata from custom headers first
	metadata := BackgroundUploadRequest{
		DeviceAssetID:  r.Header.Get("X-Device-Asset-Id"),
		DeviceID:       r.Header.Get("X-Device-Id"),
		FileCreatedAt:  r.Header.Get("X-File-Created-At"),
		FileModifiedAt: r.Header.Get("X-File-Modified-At"),
		IsFavorite:     r.Header.Get("X-Is-Favorite"),
		Filename:       r.Header.Get("X-Filename"),
		ContentType:    r.Header.Get("X-Content-Type"),
		ICloudId:       r.Header.Get("X-iCloud-Id"),
		Latitude:       r.Header.Get("X-Latitude"),
		Longitude:      r.Header.Get("X-Longitude"),
	}

	// Fall back to query parameters if headers are not set
	query := r.URL.Query()
	if metadata.DeviceAssetID == "" {
		metadata.DeviceAssetID = query.Get("deviceAssetId")
	}
	if metadata.DeviceID == "" {
		metadata.DeviceID = query.Get("deviceId")
	}
	if metadata.FileCreatedAt == "" {
		metadata.FileCreatedAt = query.Get("fileCreatedAt")
	}
	if metadata.FileModifiedAt == "" {
		metadata.FileModifiedAt = query.Get("fileModifiedAt")
	}
	if metadata.IsFavorite == "" {
		metadata.IsFavorite = query.Get("isFavorite")
	}
	if metadata.Filename == "" {
		metadata.Filename = query.Get("filename")
	}
	if metadata.ContentType == "" {
		metadata.ContentType = query.Get("contentType")
	}
	if metadata.ICloudId == "" {
		metadata.ICloudId = query.Get("iCloudId")
	}
	if metadata.Latitude == "" {
		metadata.Latitude = query.Get("latitude")
	}
	if metadata.Longitude == "" {
		metadata.Longitude = query.Get("longitude")
	}

	// Set defaults
	if metadata.DeviceID == "" {
		metadata.DeviceID = "ios-immich-uploader"
	}
	if metadata.IsFavorite == "" {
		metadata.IsFavorite = "false"
	}
	if metadata.Filename == "" {
		metadata.Filename = "upload.jpg"
	}
	if metadata.ContentType == "" {
		metadata.ContentType = guessContentType(metadata.Filename)
	}

	// Generate device asset ID if not provided
	if metadata.DeviceAssetID == "" {
		metadata.DeviceAssetID = fmt.Sprintf("%s-%d", metadata.Filename, time.Now().UnixNano())
	}

	// Set timestamps if not provided
	now := time.Now().UTC().Format(time.RFC3339)
	if metadata.FileCreatedAt == "" {
		metadata.FileCreatedAt = now
	}
	if metadata.FileModifiedAt == "" {
		metadata.FileModifiedAt = now
	}

	return metadata
}

// createMultipartRequest creates the multipart/form-data request body for Immich
func createMultipartRequest(metadata BackgroundUploadRequest, photoData []byte) (*bytes.Buffer, string, error) {
	body := &bytes.Buffer{}
	writer := multipart.NewWriter(body)

	// Add form fields
	fields := map[string]string{
		"deviceAssetId":  metadata.DeviceAssetID,
		"deviceId":       metadata.DeviceID,
		"fileCreatedAt":  metadata.FileCreatedAt,
		"fileModifiedAt": metadata.FileModifiedAt,
		"isFavorite":     metadata.IsFavorite,
	}

	for key, value := range fields {
		if err := writer.WriteField(key, value); err != nil {
			return nil, "", fmt.Errorf("failed to write field %s: %w", key, err)
		}
	}

	// Include mobile-app metadata with iCloudId if available
	if metadata.ICloudId != "" {
		metadataItem := RemoteAssetMetadataItem{
			Key: "yaiiu-app",
			Value: MobileAppMetadata{
				ICloudId:  metadata.ICloudId,
				CreatedAt: metadata.FileCreatedAt,
				Latitude:  metadata.Latitude,
				Longitude: metadata.Longitude,
			},
		}
		metadataJSON, err := json.Marshal([]RemoteAssetMetadataItem{metadataItem})
			if err != nil {
				return nil, "", fmt.Errorf("failed to marshal metadata: %w", err)
			}
			if err := writer.WriteField("metadata", string(metadataJSON)); err != nil {
				return nil, "", fmt.Errorf("failed to write metadata field: %w", err)
			}
	}

	// Add the file with proper Content-Type
	h := make(textproto.MIMEHeader)
	h.Set("Content-Disposition", fmt.Sprintf(`form-data; name="assetData"; filename="%s"`, metadata.Filename))
	h.Set("Content-Type", metadata.ContentType)

	part, err := writer.CreatePart(h)
	if err != nil {
		return nil, "", fmt.Errorf("failed to create form file: %w", err)
	}

	if _, err := part.Write(photoData); err != nil {
		return nil, "", fmt.Errorf("failed to write photo data: %w", err)
	}

	if err := writer.Close(); err != nil {
		return nil, "", fmt.Errorf("failed to close multipart writer: %w", err)
	}

	return body, writer.FormDataContentType(), nil
}

// guessContentType guesses the content type based on file extension
func guessContentType(filename string) string {
	ext := strings.ToLower(filepath.Ext(filename))
	switch ext {
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".png":
		return "image/png"
	case ".gif":
		return "image/gif"
	case ".heic", ".heif":
		return "image/heic"
	case ".dng":
		return "image/dng"
	case ".raw":
		return "image/raw"
	case ".mp4":
		return "video/mp4"
	case ".mov":
		return "video/quicktime"
	case ".avi":
		return "video/avi"
	case ".webp":
		return "image/webp"
	default:
		return "application/octet-stream"
	}
}

// HealthHandler returns a simple health check endpoint
func HealthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"status": "ok",
		"time":   time.Now().UTC().Format(time.RFC3339),
	})
}
