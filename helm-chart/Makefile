release:
	helm package .
	aws s3 cp --acl public-read cluster-resources-*.tgz s3://savvihub-helm-packages/cluster-resources/
	helm repo index . --url https://savvihub-helm-packages.s3.ap-northeast-2.amazonaws.com/cluster-resources/
	rm cluster-resources-*.tgz
