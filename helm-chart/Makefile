release:
	helm dependency update
	helm package .
	aws s3 cp --acl public-read cluster-resources-*.tgz s3://vessl-helm-packages/cluster-resources/
	helm repo index . --merge index.yaml --url https://vessl-helm-packages.s3.ap-northeast-2.amazonaws.com/cluster-resources/
	rm cluster-resources-*.tgz

local_update:
	helm upgrade --install vessl . \
		--set agent.apiServer=http://host.minikube.internal:10000 \
		--set agent.customImageSource=host.minikube.internal:5050/cluster-agent:dev \
		--set agent.imagePullPolicy=Always \
		--set agent.accessToken=q0Rmo/sAD0eEE9rXLgGq/E5wXM9xv2AYc2Ba8S6fOCLAqk2tZ4vYgsAk6q9XXDyP0HLsbQ== \
		--set agent.clusterName=local \
		--set prometheus.enabled=true \
		--set prometheus.remoteWriteURL=http://aron-backend-local-remote-write-gateway.mimir.svc.cluster.local/remote-write \
		-n vessl --create-namespace
