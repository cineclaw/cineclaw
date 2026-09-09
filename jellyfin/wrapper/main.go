package main

import (
	"bytes"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

const realProbe = "/usr/lib/jellyfin-ffmpeg/ffprobe.real"
const cacheDir = "/cache/ffprobe"

func main() {
	var inputArg string
	for i := 1; i < len(os.Args); i++ {
		if os.Args[i] == "-i" && i+1 < len(os.Args) {
			inputArg = os.Args[i+1]
			break
		}
	}

	cleanPath := strings.TrimPrefix(inputArg, "file:")
	if cleanPath == "" || !strings.HasPrefix(cleanPath, "/media/") {
		runReal(os.Args[1:])
		return
	}

	isJSON := false
	for _, a := range os.Args {
		if a == "json" {
			isJSON = true
			break
		}
	}
	if !isJSON {
		runReal(os.Args[1:])
		return
	}

	_ = os.MkdirAll(cacheDir, 0755)

	dir := filepath.Dir(cleanPath)
	cacheKeyDir := dir
	baseDirName := strings.ToLower(filepath.Base(dir))
	if strings.Contains(baseDirName, "season") || strings.Contains(baseDirName, "сезон") || strings.HasPrefix(baseDirName, "s0") || strings.HasPrefix(baseDirName, "s1") || strings.HasPrefix(baseDirName, "s2") {
		cacheKeyDir = filepath.Dir(dir)
	}

	h := md5.Sum([]byte(cacheKeyDir))
	cacheFile := filepath.Join(cacheDir, hex.EncodeToString(h[:])+".json")

	var fileSize int64 = 0
	if fi, err := os.Stat(cleanPath); err == nil {
		fileSize = fi.Size()
	}

	// 1. Check if cached profile exists
	if cachedBytes, err := os.ReadFile(cacheFile); err == nil {
		var data map[string]interface{}
		if err := json.Unmarshal(cachedBytes, &data); err == nil {
			if fmtMap, ok := data["format"].(map[string]interface{}); ok {
				fmtMap["filename"] = inputArg
				if fileSize > 0 {
					fmtMap["size"] = fmt.Sprintf("%d", fileSize)
					if brStr, ok := fmtMap["bit_rate"].(string); ok {
						if br, err := strconv.ParseFloat(brStr, 64); err == nil && br > 0 {
							dur := float64(fileSize*8) / br
							fmtMap["duration"] = fmt.Sprintf("%.6f", dur)
						}
					}
				}
			}
			enc := json.NewEncoder(os.Stdout)
			if err := enc.Encode(data); err == nil {
				return
			}
		}
	}

	// 2. Not cached: Run real ffprobe via unseekable pipe:0 on the first 4 MB of the file
	// This prevents ffprobe from seeking to the end of a 2-10GB file over FUSE to find chapters/cues.
	f, err := os.Open(cleanPath)
	if err != nil {
		runReal(os.Args[1:])
		return
	}

	headerBytes := make([]byte, 4*1024*1024)
	n, _ := io.ReadFull(f, headerBytes)
	f.Close()

	if n > 0 {
		probeCmd := exec.Command(realProbe,
			"-v", "warning",
			"-print_format", "json",
			"-show_streams",
			"-show_format",
			"-i", "pipe:0",
		)
		probeCmd.Stdin = bytes.NewReader(headerBytes[:n])
		out, err := probeCmd.Output()
		if err == nil {
			var data map[string]interface{}
			if err := json.Unmarshal(out, &data); err == nil {
				if streams, ok := data["streams"].([]interface{}); ok && len(streams) > 0 {
					if fmtMap, ok := data["format"].(map[string]interface{}); ok {
						fmtMap["filename"] = inputArg
						if fileSize > 0 {
							fmtMap["size"] = fmt.Sprintf("%d", fileSize)
							if brStr, ok := fmtMap["bit_rate"].(string); ok {
								if br, err := strconv.ParseFloat(brStr, 64); err == nil && br > 0 {
									dur := float64(fileSize*8) / br
									fmtMap["duration"] = fmt.Sprintf("%.6f", dur)
								}
							}
						}
					}
					data["chapters"] = []interface{}{}
					data["frames"] = []interface{}{}

					if encoded, err := json.MarshalIndent(data, "", "    "); err == nil {
						_ = os.WriteFile(cacheFile, encoded, 0644)
						os.Stdout.Write(encoded)
						return
					}
				}
			}
		}
	}

	// Fallback to real with optimized buffer parameters
	var newArgs []string
	for i := 1; i < len(os.Args); i++ {
		arg := os.Args[i]
		if arg == "200M" || arg == "1G" {
			newArgs = append(newArgs, "5M")
		} else {
			newArgs = append(newArgs, arg)
		}
	}

	cmd := exec.Command(realProbe, newArgs...)
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		runReal(os.Args[1:])
		return
	}

	var data map[string]interface{}
	if err := json.Unmarshal(out, &data); err == nil {
		if streams, ok := data["streams"].([]interface{}); ok && len(streams) > 0 {
			_ = os.WriteFile(cacheFile, out, 0644)
		}
	}

	os.Stdout.Write(out)
}

func runReal(args []string) {
	cmd := exec.Command(realProbe, args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			os.Exit(exitErr.ExitCode())
		}
		os.Exit(1)
	}
}
