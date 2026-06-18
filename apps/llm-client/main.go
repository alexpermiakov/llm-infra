// llm-client: Simple service that sends prompts to a vLLM inference server
// and returns the LLM response. Uses the OpenAI-compatible /v1/completions API.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	version    = "dev"
	vllmURL    string
	httpClient = &http.Client{Timeout: 30 * time.Second}
)

type completionRequest struct {
	Model     string `json:"model"`
	Prompt    string `json:"prompt"`
	MaxTokens int    `json:"max_tokens"`
}

type completionResponse struct {
	Choices []struct {
		Text string `json:"text"`
	} `json:"choices"`
}

func main() {
	vllmURL = getEnv("VLLM_URL", "http://vllm-inference.vllm-inference.svc.cluster.local:8000")

	mux := http.NewServeMux()
	mux.HandleFunc("/", indexHandler)
	mux.HandleFunc("/ask", askHandler)
	mux.HandleFunc("/healthz", healthHandler)
	mux.HandleFunc("/readyz", readyHandler)
	mux.Handle("/metrics", promhttp.Handler())

	port := getEnv("PORT", "8080")
	fmt.Printf("llm-client %s starting on port %s (vllm: %s)\n", version, port, vllmURL)
	if err := http.ListenAndServe(":"+port, mux); err != nil {
		fmt.Printf("Error starting server: %s\n", err)
		os.Exit(1)
	}
}

func indexHandler(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, map[string]string{
		"service": "llm-client",
		"version": version,
	})
}

func askHandler(w http.ResponseWriter, r *http.Request) {
	prompt := r.URL.Query().Get("prompt")
	if prompt == "" {
		http.Error(w, `{"error": "prompt query parameter is required"}`, http.StatusBadRequest)
		return
	}

	model := getEnv("VLLM_MODEL", "facebook/opt-125m")

	reqBody, _ := json.Marshal(completionRequest{
		Model:     model,
		Prompt:    prompt,
		MaxTokens: 50,
	})

	start := time.Now()
	resp, err := httpClient.Post(vllmURL+"/v1/completions", "application/json", bytes.NewReader(reqBody))
	latency := time.Since(start)

	if err != nil {
		log.Printf("vLLM request failed: %v", err)
		http.Error(w, fmt.Sprintf(`{"error": "vLLM request failed: %s"}`, err), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		http.Error(w, `{"error": "failed to read vLLM response"}`, http.StatusBadGateway)
		return
	}

	if resp.StatusCode != http.StatusOK {
		log.Printf("vLLM returned status %d: %s", resp.StatusCode, string(body))
		w.WriteHeader(http.StatusBadGateway)
		writeJSON(w, map[string]interface{}{
			"error":       "vLLM returned non-200 status",
			"status_code": resp.StatusCode,
			"detail":      string(body),
		})
		return
	}

	var compResp completionResponse
	if err := json.Unmarshal(body, &compResp); err != nil {
		http.Error(w, `{"error": "failed to parse vLLM response"}`, http.StatusBadGateway)
		return
	}

	answer := ""
	if len(compResp.Choices) > 0 {
		answer = compResp.Choices[0].Text
	}

	writeJSON(w, map[string]interface{}{
		"prompt":     prompt,
		"response":   answer,
		"model":      model,
		"latency_ms": latency.Milliseconds(),
	})
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	fmt.Fprint(w, "OK")
}

func readyHandler(w http.ResponseWriter, r *http.Request) {
	fmt.Fprint(w, "Ready")
}

func writeJSON(w http.ResponseWriter, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("failed to write response: %v", err)
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
