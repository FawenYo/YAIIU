package handlers

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"
)

var exifOffsetPattern = regexp.MustCompile(`^[+-](?:0\d|1\d|2[0-3]):[0-5]\d$`)

// addTimezoneOffsetIfMissing delegates lossless metadata rewriting to ExifTool.
// Unsupported files and images that already have an offset pass through unchanged.
// A missing ExifTool install yields an error the caller treats as "skip normalization".
func addTimezoneOffsetIfMissing(photoData []byte, filename, offset string) ([]byte, bool, error) {
	if !exifOffsetPattern.MatchString(offset) || !isImageFilename(filename) {
		return photoData, false, nil
	}
	if _, err := exec.LookPath("exiftool"); err != nil {
		return nil, false, fmt.Errorf("exiftool not available: %w", err)
	}

	input, err := os.CreateTemp("", "immich-proxy-input-*")
	if err != nil {
		return nil, false, fmt.Errorf("create metadata input: %w", err)
	}
	inputPath := input.Name()
	defer os.Remove(inputPath)

	if _, err := input.Write(photoData); err != nil {
		input.Close()
		return nil, false, fmt.Errorf("write metadata input: %w", err)
	}
	if err := input.Close(); err != nil {
		return nil, false, fmt.Errorf("close metadata input: %w", err)
	}

	output, err := os.CreateTemp("", "immich-proxy-output-*")
	if err != nil {
		return nil, false, fmt.Errorf("create metadata output: %w", err)
	}
	outputPath := output.Name()
	output.Close()
	os.Remove(outputPath)
	defer os.Remove(outputPath)

	cmd := exec.Command(
		"exiftool",
		"-q", "-q",
		"-if", "not defined $OffsetTimeOriginal or $OffsetTimeOriginal eq ''",
		"-OffsetTimeOriginal="+offset,
		"-o", outputPath,
		inputPath,
	)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		if exitError, ok := err.(*exec.ExitError); ok && exitError.ExitCode() == 2 && strings.TrimSpace(stderr.String()) == "" {
			return photoData, false, nil
		}
		return nil, false, fmt.Errorf("write OffsetTimeOriginal: %w: %s", err, strings.TrimSpace(stderr.String()))
	}

	normalized, err := os.ReadFile(outputPath)
	if err != nil {
		return nil, false, fmt.Errorf("read metadata output: %w", err)
	}
	return normalized, true, nil
}

func isImageFilename(filename string) bool {
	lower := strings.ToLower(filename)
	for _, extension := range []string{".jpg", ".jpeg", ".png", ".heic", ".heif", ".tif", ".tiff", ".webp", ".dng", ".arw", ".cr2", ".cr3", ".nef", ".raf", ".orf", ".rw2"} {
		if strings.HasSuffix(lower, extension) {
			return true
		}
	}
	return false
}
