package main

import (
	"log"
	"net/http"
	"os"
	"strings"

	"immich-proxy/handlers"
	"immich-proxy/proxy"
)

func main() {
	// Load configuration from environment variables
	config := loadConfig()

	log.Printf("Starting Immich Proxy Server...")
	log.Printf("Listening on: %s", config.ListenAddr)
	log.Printf("Immich Server: %s", config.ImmichServerURL)

	// Create reverse proxy for general API calls
	reverseProxy := proxy.NewReverseProxy(config.ImmichServerURL)

	// Create multiplexer
	mux := http.NewServeMux()

	// Health check endpoint
	mux.HandleFunc("/health", handlers.HealthHandler)

	// Background upload endpoint - converts raw photo data to multipart form-data
	mux.HandleFunc("/api/assets/background", handlers.BackgroundUploadHandler(config.ImmichServerURL))

	// All other requests are proxied directly to Immich server
	mux.HandleFunc("/", reverseProxy.Handler())

	// Start server
	server := &http.Server{
		Addr:    config.ListenAddr,
		Handler: logMiddleware(mux),
	}

	log.Fatal(server.ListenAndServe())
}

// Config holds the server configuration
type Config struct {
	ListenAddr      string
	ImmichServerURL string
}

// loadConfig loads configuration from environment variables
func loadConfig() *Config {
	listenAddr := os.Getenv("LISTEN_ADDR")
	if listenAddr == "" {
		listenAddr = ":8080"
	}

	immichServerURL := os.Getenv("IMMICH_SERVER_URL")
	if immichServerURL == "" {
		immichServerURL = "http://localhost:2283"
	}

	return &Config{
		ListenAddr:      listenAddr,
		ImmichServerURL: immichServerURL,
	}
}

// logMiddleware logs all incoming requests except health checks
func logMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Skip logging for health check endpoint to reduce log noise
		if r.URL.Path != "/health" {
			clientIP := GetClientIP(r)
			log.Printf("[%s] %s %s", r.Method, r.URL.Path, clientIP)
		}
		next.ServeHTTP(w, r)
	})
}

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
