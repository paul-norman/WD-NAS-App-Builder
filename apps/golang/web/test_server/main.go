package main

import (
	"net/http"
)

func main() {
	http.Handle("/", http.FileServer(http.Dir("./static")))
	http.ListenAndServe(":30289", nil)
	println("Go app is listening on: 0.0.0.0:30289")
}