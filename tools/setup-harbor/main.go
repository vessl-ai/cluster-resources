package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"
)

type CreateRegistryRequest struct {
	Name        string `json:"name"`
	Url         string `json:"url"`
	Insecure    bool   `json:"insecure"`
	Type        string `json:"type"`
	Description string `json:"description"`
}

type RegistryResponse struct {
	Id int `json:"id"`
}

type CreateProjectRequest struct {
	ProjectName  string `json:"project_name"`
	RegistryID   int    `json:"registry_id"`
	Public       bool   `json:"public"`
	StorageLimit int    `json:"storage_limit"`
}

func addRegistry(registryType, registryName, registryURL, description string) {
	log.Println("Adding registry:", registryName)
	password := os.Getenv("HARBOR_ADMIN_PASSWORD")
	basicAuthURL := fmt.Sprintf("http://admin:%s@harbor/api/v2.0", password)
	res, err := http.Get(fmt.Sprintf("%s/registries?q=name%%3D%s", basicAuthURL, registryName))
	if err != nil {
		panic(err)
	}
	defer res.Body.Close()
	registries := make([]interface{}, 0)
	json.NewDecoder(res.Body).Decode(&registries)
	registryId := 0
	if len(registries) == 0 {
		payload := CreateRegistryRequest{
			Name:        registryName,
			Url:         registryURL,
			Insecure:    false,
			Type:        registryName,
			Description: description,
		}
		pBytes, _ := json.Marshal(payload)
		buff := bytes.NewBuffer(pBytes)
		res, err := http.Post(fmt.Sprintf("%s/registries", basicAuthURL), "application/json", buff)
		if err != nil {
			panic(err)
		}
		if res.StatusCode != 201 {
			panic("Failed to create registry")
		}
		res, err = http.Get(fmt.Sprintf("%s/registries?q=name%%3D%s", basicAuthURL, registryName))
		if err != nil {
			panic(err)
		}
		if res.StatusCode != 200 {
			panic("Failed to get registry")
		}
		defer res.Body.Close()
		registries := make([]RegistryResponse, 0)
		json.NewDecoder(res.Body).Decode(&registries)
		if len(registries) == 0 {
			panic("Failed to get registry")
		}
		registryId = registries[0].Id
	}
	res, err = http.Get(fmt.Sprintf("%s/api/v2.0/projects/%s/summary", registryName, basicAuthURL))
	if err != nil {
		panic(err)
	}
	if res.StatusCode != 200 {
		payload := CreateProjectRequest{
			ProjectName:  registryName,
			RegistryID:   registryId,
			Public:       true,
			StorageLimit: -1,
		}
		pBytes, _ := json.Marshal(payload)
		buff := bytes.NewBuffer(pBytes)
		res, err := http.Post(fmt.Sprintf("%s/projects", basicAuthURL), "application/json", buff)
		if err != nil {
			panic(err)
		}
		if res.StatusCode != 201 {
			panic("Failed to create registry")
		}
	}
}

func main() {
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute*10)
	defer cancel()
	client := http.DefaultClient
	for {
		req, err := http.NewRequestWithContext(ctx, "GET", "http://harbor/api/v2.0/ping", nil)
		if err != nil {
			panic(err)
		}
		req = req.WithContext(ctx)
		res, err := client.Do(req)
		if res.StatusCode == 200 {
			break
		} else if err == context.DeadlineExceeded {
			panic("Harbor is not ready, context deadline exceeded.")
		}
	}
	addRegistry("quay", "quay", "https://quay.io", "quay.io")
	addRegistry("dockerhub", "dockerhub", "https://hub.docker.com", "dockerhub")
	addRegistry("harbor", "harbor", "https://harbor.vessl.ai", "harbor.vessl.ai")
}
