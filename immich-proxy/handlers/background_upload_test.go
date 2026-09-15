package handlers

import (
	"net/http"
	"net/http/httptest"
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
