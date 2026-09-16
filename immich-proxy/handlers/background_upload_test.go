package handlers

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestBackgroundUploadOptionsSelectsNonResumableFallback(t *testing.T) {
	req := httptest.NewRequest(http.MethodOptions, "/api/assets/background", nil)
	response := httptest.NewRecorder()

	BackgroundUploadHandler("http://immich.invalid").ServeHTTP(response, req)

	if response.Code != http.StatusNotImplemented {
		t.Fatalf("expected status %d, got %d", http.StatusNotImplemented, response.Code)
	}
}

func TestBackgroundUploadReturnsImmichAssetIDHeader(t *testing.T) {
	immich := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"id":"ef96f635-61c7-4639-9e60-61a11c4bbfba","duplicate":false}`)
	}))
	defer immich.Close()

	req := httptest.NewRequest(http.MethodPost, "/api/assets/background", strings.NewReader("video"))
	req.Header.Set("X-Filename", "clip.mov")
	req.Header.Set("Authorization", "Bearer token")
	response := httptest.NewRecorder()

	BackgroundUploadHandler(immich.URL).ServeHTTP(response, req)

	if response.Code != http.StatusCreated {
		t.Fatalf("expected status %d, got %d", http.StatusCreated, response.Code)
	}
	if got := response.Header().Get(immichAssetIDHeader); got != "ef96f635-61c7-4639-9e60-61a11c4bbfba" {
		t.Fatalf("asset id header = %q", got)
	}
}
