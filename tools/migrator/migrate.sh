#!/bin/sh
helm get values vessl -n vessl > old.yaml
docker run -it --rm --name vessl-helm-value-migrator -v "$PWD":/usr/src/app -w /usr/src/app ruby:alpine ruby convert.rb
