#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
WHITE='\033[0;37m' 
NC='\033[0m' # No Color

function fail() {
    msg=$1
    echo -e "${RED}[X] ${msg}${NC}"
    exit 1
}

function success() {
    msg=$1
    echo -e "${GREEN}[✓] ${msg}${NC}"
}

function info() {
    msg=$1
    echo -e "${WHITE}[*] ${msg}${NC}"
}

function log_failure() {
    msg=$1
    echo -e "${RED}[X] ${msg}${NC}"
    echo "${msg}" >> failed.log
}

function push() {
    image=$1
    info "Pushing ${image}..."
    docker push $image 2>&1 > /dev/null
    [ "$?" -eq "0" ] && success "Pushed ${image}" || (log_failure "Push failed: $image")
}

function pull_and_push_for_tag() {
    repo=$1
    tag=$2
    info "Pulling $repo:$tag..."
    ecr_image="public.ecr.aws/vessl/$repo:$tag"
    docker pull $ecr_image --platform=amd64 2>&1 > /dev/null
    [ "$?" -eq "0" ] || { log_failure "Pull failed: $ecr_image"; return 1; }
    success "Pulled $ecr_image."
    quay_image="quay.io/vessl-ai/$repo:$tag"
    harbor_image="harbor.vessl.ai/public/$repo:$tag"
    docker tag $ecr_image $quay_image
    docker tag $ecr_image $harbor_image
    info "$ecr_image is also tagged as $quay_image, $harbor_image."
    push $quay_image &
    push $harbor_image &
    wait
    info "Cleaning up regardless of push success($ecr_image)..."
    docker rmi $ecr_image 2>&1 > /dev/null
    docker rmi $quay_image 2>&1 > /dev/null
    docker rmi $harbor_image 2>&1 > /dev/null
}

function pull_and_push_for_repo() {
    repo=$1
    no_child_spawn=$2
    tags=$(aws ecr-public describe-image-tags --repository-name=$repo --region=us-east-1 | jq -r '.imageTagDetails[].imageTag')
    for tag in $tags; do
        if [ "$no_child_spawn" == "true" ]; then
            pull_and_push_for_tag $repo $tag
        else
            pull_and_push_for_tag $repo $tag &
        fi
    done
    wait
}


# check prerequisites
info "Checking jq and aws cli..."
which jq > /dev/null 2>&1 || fail "jq is required but not installed. Aborting."
which aws > /dev/null 2>&1 || fail "aws is required but not installed. Aborting."
success "jq and aws are installed."

# should log in to quay.io and our harbor
info "Checking if current shell logged into quay.io and harbor..."
quay_login_status=$(cat ~/.docker/config.json | jq '.auths | has("quay.io")')
$quay_login_status || fail "Please log in to quay.io first. Aborting."
vessl_harbor_login_status=$(cat ~/.docker/config.json | jq '.auths | has("harbor.vessl.ai")')
$vessl_harbor_login_status || fail "Please log in to harbor.vessl.ai first. Aborting."
success "Current user has logged in to quay.io and harbor."

info "Log in to AWS ECR Public..."
aws ecr-public get-login-password --region=us-east-1 | docker login --username AWS --password-stdin public.ecr.aws
[ "$?" -eq "0" ] || fail "Failed to log in to AWS ECR Public. Aborting."
success "Logged in to AWS ECR Public."

repositories=$(aws ecr-public describe-repositories --region=us-east-1 | jq -r '.repositories[].repositoryName')

for repo in $repositories; do
    pull_and_push_for_repo $repo &
done
wait

