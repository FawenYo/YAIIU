package handlers

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestAddTimezoneOffsetIfMissing(t *testing.T) {
	source := filepath.Join("..", "..", "docs", "screenshots", "settings.PNG")
	input, err := os.ReadFile(source)
	if err != nil {
		t.Fatal(err)
	}

	updated, changed, err := addTimezoneOffsetIfMissing(input, "IMG_5805.PNG", "+08:00")
	if err != nil {
		t.Fatal(err)
	}
	if !changed {
		t.Fatal("expected missing OffsetTimeOriginal to be added")
	}
	if offset := readOffset(t, updated); offset != "+08:00" {
		t.Fatalf("offset = %q, want +08:00", offset)
	}

	unchanged, changed, err := addTimezoneOffsetIfMissing(updated, "IMG_5805.PNG", "+09:00")
	if err != nil {
		t.Fatal(err)
	}
	if changed {
		t.Fatal("expected existing OffsetTimeOriginal to be preserved")
	}
	if offset := readOffset(t, unchanged); offset != "+08:00" {
		t.Fatalf("offset = %q, want existing +08:00", offset)
	}
}

func TestAddTimezoneOffsetSkipsNonImages(t *testing.T) {
	input := []byte("video")
	output, changed, err := addTimezoneOffsetIfMissing(input, "clip.MOV", "+08:00")
	if err != nil {
		t.Fatal(err)
	}
	if changed || string(output) != string(input) {
		t.Fatal("expected non-image payload to pass through unchanged")
	}
}

func TestAddTimezoneOffsetReportsMissingExifTool(t *testing.T) {
	t.Setenv("PATH", "")
	input := []byte("image")
	_, changed, err := addTimezoneOffsetIfMissing(input, "photo.jpg", "+08:00")
	if err == nil {
		t.Fatal("expected an error when exiftool is not on PATH")
	}
	if changed {
		t.Fatal("expected no change when exiftool is missing")
	}
}

func TestCreateMultipartRequestIncludesSourceChecksumAfterRewrite(t *testing.T) {
	metadata := BackgroundUploadRequest{
		DeviceAssetID:  "asset-1-primary-photo.jpg",
		DeviceID:       "device-1",
		FileCreatedAt:  "2026-09-16T00:00:00Z",
		FileModifiedAt: "2026-09-16T00:00:00Z",
		IsFavorite:     "false",
		Filename:       "photo.jpg",
		ContentType:    "image/jpeg",
		SourceChecksum: "0123456789abcdef0123456789abcdef01234567",
	}

	body, contentType, err := createMultipartRequest(metadata, []byte("image"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(contentType, "multipart/form-data") {
		t.Fatalf("content type = %q", contentType)
	}
	if !strings.Contains(body.String(), `"sourceChecksum":"0123456789abcdef0123456789abcdef01234567"`) {
		t.Fatal("expected source checksum in mobile-app metadata")
	}
}

func readOffset(t *testing.T, data []byte) string {
	t.Helper()
	file, err := os.CreateTemp("", "offset-test-*.png")
	if err != nil {
		t.Fatal(err)
	}
	path := file.Name()
	defer os.Remove(path)
	if _, err := file.Write(data); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}

	output, err := exec.Command("exiftool", "-s3", "-OffsetTimeOriginal", path).Output()
	if err != nil {
		t.Fatal(err)
	}
	return string(output[:len(output)-1])
}
