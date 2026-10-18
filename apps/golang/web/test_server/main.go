package main

import (
	"log"
	"net/http"
)

func main() {
	http.Handle("/", http.FileServer(http.Dir("./static")))
	log.Println("Go app is listening on: 0.0.0.0:30289")
	log.Fatal(http.ListenAndServe(":30289", nil))
}
