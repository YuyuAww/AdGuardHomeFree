// AdGuardHomeFree aghbridge (P0-T2)
// Minimal status bridge for the module WebUI:
//   GET  /status  -> {"agh_running":bool,"impl":"kernelsu|apatch|unknown"}
//   GET|POST /exec -> P0 action whitelist: get_status only; else 403
// CORS: Access-Control-Allow-Origin * (+ OPTIONS preflight) so the KSU
// WebView can call this from a file:// page.
//
// Subcommand: aghbridge gen-hash <password> -> prints a bcrypt hash
// (used by customize.sh to fill __AGHF_ADMIN_HASH__; never logged).
//
// The admin credential file $AGHF_STATE/agh_admin.cred ("user:pass") is read
// internally only; it is never returned to any caller.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/crypto/bcrypt"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "gen-hash" {
		if len(os.Args) != 3 {
			fmt.Fprintln(os.Stderr, "usage: aghbridge gen-hash <password>")
			os.Exit(2)
		}
		h, err := bcrypt.GenerateFromPassword([]byte(os.Args[2]), bcrypt.DefaultCost)
		if err != nil {
			fmt.Fprintln(os.Stderr, "gen-hash:", err)
			os.Exit(1)
		}
		fmt.Println(string(h))
		return
	}

	fs := flag.NewFlagSet("aghbridge", flag.ExitOnError)
	listen := fs.String("listen", "127.0.0.1:3001", "listen address")
	implFlag := fs.String("impl", "", "root implementation (kernelsu|apatch)")
	fs.Parse(os.Args[1:])

	impl := resolveImpl(*implFlag)
	srv := &server{impl: impl}

	var ln net.Listener
	var err error
	if ln, err = net.Listen("tcp", *listen); err != nil {
		fmt.Fprintln(os.Stderr, "listen:", err)
		os.Exit(1)
	}
	fmt.Fprintf(os.Stderr, "aghbridge listening on %s impl=%s\n", *listen, impl)
	if err := http.Serve(ln, srv); err != nil {
		fmt.Fprintln(os.Stderr, "serve:", err)
	}
}

// resolveImpl: -impl flag > $AGHF_ROOT_IMPL > $APATCH / $KSU > unknown.
func resolveImpl(flagVal string) string {
	if flagVal != "" {
		return flagVal
	}
	if v := os.Getenv("AGHF_ROOT_IMPL"); v == "kernelsu" || v == "apatch" {
		return v
	}
	if os.Getenv("APATCH") != "" {
		return "apatch"
	}
	if os.Getenv("KSU") != "" {
		return "kernelsu"
	}
	return "unknown"
}

func aghRunning() bool {
	// Scan /proc/*/comm for the AdGuardHome process (no external deps).
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return false
	}
	for _, e := range entries {
		if !e.IsDir() || !isNum(e.Name()) {
			continue
		}
		b, err := os.ReadFile(filepath.Join("/proc", e.Name(), "comm"))
		if err != nil {
			continue
		}
		if strings.TrimSpace(string(b)) == "AdGuardHome" {
			return true
		}
	}
	return false
}

func isNum(s string) bool {
	if s == "" {
		return false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

type server struct {
	impl string
}

type statusResp struct {
	AghRunning bool   `json:"agh_running"`
	Impl       string `json:"impl"`
}

func (s *server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	switch r.URL.Path {
	case "/status":
		writeJSON(w, http.StatusOK, statusResp{aghRunning(), s.impl})

	case "/exec":
		action := extractAction(r)
		switch action {
		case "get_status":
			// P0 whitelist.
			writeJSON(w, http.StatusOK, statusResp{aghRunning(), s.impl})
		case "":
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "missing action (P0 whitelist: get_status)",
			})
		default:
			// P1-T2+ extends the whitelist (stop/start/rollback).
			writeJSON(w, http.StatusForbidden, map[string]string{
				"error": "action not allowed",
			})
		}

	default:
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
	}
}

// extractAction: ?action= query param, or {"action":"..."} JSON body.
func extractAction(r *http.Request) string {
	if a := r.URL.Query().Get("action"); a != "" {
		return a
	}
	if r.Method == http.MethodPost {
		var body struct {
			Action string `json:"action"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err == nil {
			return body.Action
		}
	}
	return ""
}

func writeJSON(w http.ResponseWriter, code int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}
