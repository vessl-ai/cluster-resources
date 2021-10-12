release:
	helm package .
	aws s3 cp --acl public-read cluster-resources-*.tgz s3://vessl-helm-packages/cluster-resources/
	helm repo index . --merge index.yaml --url https://veessl-helm-packages.s3.ap-northeast-2.amazonaws.com/cluster-resources/
	rm cluster-resources-*.tgz
