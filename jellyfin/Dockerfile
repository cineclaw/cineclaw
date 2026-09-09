FROM golang:alpine AS builder
WORKDIR /src
COPY wrapper/main.go .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /ffprobe-wrapper main.go

FROM jellyfin/jellyfin:latest
RUN mv /usr/lib/jellyfin-ffmpeg/ffprobe /usr/lib/jellyfin-ffmpeg/ffprobe.real
COPY --from=builder /ffprobe-wrapper /usr/lib/jellyfin-ffmpeg/ffprobe
RUN chmod +x /usr/lib/jellyfin-ffmpeg/ffprobe
