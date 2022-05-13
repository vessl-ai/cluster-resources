package main

import (
	"bytes"
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
	registries := make([]RegistryResponse, 0)
	json.NewDecoder(res.Body).Decode(&registries)
	log.Println("status", res.StatusCode)
	log.Println("registries", registries)
	registryId := 0
	if len(registries) == 0 {
		payload := CreateRegistryRequest{
			Name:        registryName,
			Url:         registryURL,
			Type:        registryType,
			Description: description,
		}
		pBytes, _ := json.Marshal(payload)
		buff := bytes.NewBuffer(pBytes)
		res, err := http.Post(fmt.Sprintf("%s/registries", basicAuthURL), "application/json", buff)
		if err != nil {
			panic(err)
		}
		log.Println(res.StatusCode)
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
	} else {
		registryId = registries[0].Id
	}
	res, err = http.Get(fmt.Sprintf("%s/projects/%s/summary", basicAuthURL, registryName))
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
	timer := time.NewTimer(time.Minute * 10)
	for {
		res, _ := http.Get("http://harbor/api/v2.0/ping")
		if res != nil {
			if res.StatusCode == 200 {
				break
			}
		}
		log.Println("Ping failed.")
		select {
		case <-timer.C:
			panic("Harbor did not responded in 10 minutes.")
		default:
			time.Sleep(time.Second * 5)
		}
	}
	addRegistry("quay", "quay", "https://quay.io", "quay.io")
	addRegistry("docker-hub", "dockerhub", "https://hub.docker.com", "dockerhub")
	addRegistry("harbor", "vessl-harbor", "https://harbor.vessl.ai", "harbor.vessl.ai")
}
