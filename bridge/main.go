package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"
)

var (
	tradeQueue = make(chan Trade, 100)
	queueMux   sync.Mutex
	netNT      int
	hedgeLot   float64
)

type Trade struct {
	ID            string    `json:"id"`      // Unique trade identifier
	BaseID        string    `json:"base_id"` // Base ID for multi-contract trades
	Time          time.Time `json:"time"`
	Action        string    `json:"action"`         // Buy/Sell
	Quantity      float64   `json:"quantity"`       // Always 1 for individual contracts
	Price         float64   `json:"price"`          // Entry price
	TotalQuantity int       `json:"total_quantity"` // Total contracts in this trade
	ContractNum   int       `json:"contract_num"`   // Which contract this is (1-based)
}

// getCurrentLotMultiplier tries to read the EA lot multiplier from an environment variable. If not set, it returns a fallback value.
func getCurrentLotMultiplier() float64 {
	mStr := os.Getenv("EA_LOT_MULTIPLIER")
	if mStr != "" {
		if m, err := strconv.ParseFloat(mStr, 64); err == nil {
			return m
		}
	}
	return 0.05
}

func logTradeHandler(w http.ResponseWriter, r *http.Request) {
	var trade Trade
	if err := json.NewDecoder(r.Body).Decode(&trade); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}

	sel := tradeQueue

	select {
	case sel <- trade:
		// Update hedging state
		queueMux.Lock()
		if trade.Action == "Buy" {
			netNT++
		} else if trade.Action == "Sell" {
			netNT--
		}
		lotMultiplier := getCurrentLotMultiplier()
		desiredHedgeLot := float64(netNT) * lotMultiplier
		if hedgeLot != desiredHedgeLot {
			fmt.Printf("Adjusting hedge from %.2f to %.2f\n", hedgeLot, desiredHedgeLot)
			hedgeLot = desiredHedgeLot
		}
		queueMux.Unlock()
		w.Write([]byte(`{"status":"success"}`))
	default:
		http.Error(w, "queue full", http.StatusServiceUnavailable)
	}
}

func getTradeHandler(w http.ResponseWriter, r *http.Request) {
	select {
	case trade := <-tradeQueue:
		json.NewEncoder(w).Encode(trade)
	default:
		w.Write([]byte(`{"status":"no_trade"}`))
	}
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	queueMux.Lock()
	defer queueMux.Unlock()

	status := map[string]interface{}{
		"status":     "healthy",
		"queue_size": len(tradeQueue),
	}
	json.NewEncoder(w).Encode(status)
}

func main() {
	http.HandleFunc("/log_trade", logTradeHandler)
	http.HandleFunc("/mt5/get_trade", getTradeHandler)
	http.HandleFunc("/health", healthHandler)

	fmt.Println("Starting bridge server on 127.0.0.1:5000")
	log.Fatal(http.ListenAndServe("127.0.0.1:5000", nil))
}
