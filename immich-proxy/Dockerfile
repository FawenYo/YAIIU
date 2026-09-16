# Build stage
FROM golang:1.25-alpine AS builder

WORKDIR /app

# Copy go mod files
COPY go.mod ./

# Download dependencies (if any external dependencies are added later)
RUN go mod download

# Copy source code
COPY . .

# Build the binary
RUN CGO_ENABLED=0 GOOS=linux go build -o immich-proxy .

# Runtime stage
FROM alpine:latest

WORKDIR /app

# Install runtime certificates and ExifTool for lossless image metadata updates
RUN apk --no-cache add ca-certificates perl-image-exiftool

# Copy the binary from builder
COPY --from=builder /app/immich-proxy .

# Expose port
EXPOSE 8080

# Run the binary
CMD ["./immich-proxy"]
