package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
)

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"status": "healthy"})
}

func main() {
	http.HandleFunc("/healthz", healthHandler)
	fmt.Println("Go fixture server listening on 8080")
	log.Fatal(http.ListenAndServe(":8080", nil))
}
