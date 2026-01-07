package proxy

import (
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
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

// ReverseProxy handles proxying requests to the Immich server
type ReverseProxy struct {
	targetURL *url.URL
	proxy     *httputil.ReverseProxy
}

// NewReverseProxy creates a new reverse proxy for the given target URL
func NewReverseProxy(targetURL string) *ReverseProxy {
	target, err := url.Parse(targetURL)
	if err != nil {
		log.Fatalf("Failed to parse target URL: %v", err)
	}

	proxy := httputil.NewSingleHostReverseProxy(target)

	// Customize error handler
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		log.Printf("Proxy error: %v", err)
		http.Error(w, "Proxy error: "+err.Error(), http.StatusBadGateway)
	}

	// Modify the director to handle request transformation
	originalDirector := proxy.Director
	proxy.Director = func(r *http.Request) {
		originalDirector(r)
		// Preserve the original Host header or set it to the target
		r.Host = target.Host
	}

	return &ReverseProxy{
		targetURL: target,
		proxy:     proxy,
	}
}

// Handler returns the HTTP handler function for the reverse proxy
func (rp *ReverseProxy) Handler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		clientIP := GetClientIP(r)
		log.Printf("[%s] Proxying request: %s %s -> %s%s", clientIP, r.Method, r.URL.Path, rp.targetURL.String(), r.URL.Path)
		rp.proxy.ServeHTTP(w, r)
	}
}
