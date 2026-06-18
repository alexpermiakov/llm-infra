// order-service: Simple HTTP service for order data.
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"sync/atomic"

	"github.com/prometheus/client_golang/prometheus/promhttp"
)

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("failed to write response: %v", err)
	}
}

var (
	version  = "dev"
	reqCount atomic.Int64
)

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/", indexHandler)
	mux.HandleFunc("/orders", ordersHandler)
	mux.HandleFunc("/healthz", healthHandler)
	mux.HandleFunc("/readyz", readyHandler)
	mux.Handle("/metrics", promhttp.Handler())

	port := getEnv("PORT", "8080")
	fmt.Printf("order-service %s starting on port %s\n", version, port)
	if err := http.ListenAndServe(":"+port, mux); err != nil {
		fmt.Printf("Error starting server: %s\n", err)
		os.Exit(1)
	}
}

func indexHandler(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, map[string]string{
		"service": "order-service",
		"version": version,
	})
}

func ordersHandler(w http.ResponseWriter, r *http.Request) {
	count := reqCount.Add(1)

	statuses := []string{"pending", "confirmed", "processing", "shipped", "delivered"}
	writeJSON(w, map[string]any{
		"order": map[string]any{
			"order_id": fmt.Sprintf("ORD-%06d", count),
			"status":   statuses[rand.Intn(len(statuses))],
			"total":    fmt.Sprintf("%.2f", rand.Float64()*500+10),
			"items":    rand.Intn(10) + 1,
		},
	})
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	fmt.Fprint(w, "OK")
}

func readyHandler(w http.ResponseWriter, r *http.Request) {
	fmt.Fprint(w, "Ready")
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
