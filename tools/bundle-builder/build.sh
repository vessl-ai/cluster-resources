#!/bin/bash
K0S_VERSION="v1.26.2+k0s.0"
ARCH="amd64"

mkdir -p output/
BIN_URL="https://github.com/k0sproject/k0s/releases/download/$K0S_VERSION/k0s-$K0S_VERSION-$ARCH"
BUNDLE_URL="https://github.com/k0sproject/k0s/releases/download/$K0S_VERSION/k0s-airgap-bundle-$K0S_VERSION-$ARCH"

BIN_FILENAME="vessl-k0s-bin"
BUNDLE_FILENAME="vessl-k0s-bundle"

curl -LJs -o output/$BIN_FILENAME $BIN_URL
curl -LJs -o output/$BUNDLE_FILENAME $BUNDLE_URL

xargs -n1 docker pull < images.txt
docker load < output/$BUNDLE_FILENAME

tar xfO output/$BUNDLE_FILENAME manifest.json | jq -r "[.[].RepoTags] | flatten[]" > output/bundle-images.txt
cat images.txt >> output/bundle-images.txt
xargs docker save -o < output/bundle-images.txt
