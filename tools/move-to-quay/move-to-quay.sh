#!/bin/bash

for image in $(cat image-list.txt); do
    echo "Pulling $image..."
    docker pull $image --platform=amd64
    image_tag=$(echo $image | awk '{split($0,a,"/"); print a[3]}')
    quay_image="quay.io/vessl-ai/$image_tag"
    echo "Retagging $image as $quay_image..."
    docker tag $image $quay_image
    echo "Pushing $quay_image..."
    docker push $quay_image
done