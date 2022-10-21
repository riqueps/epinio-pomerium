export CLUSTER_NAME ?= epinio
export TMP_DIR ?= /tmp
IP_ADDR := $(shell ifconfig -a | grep "inet " | awk 'NR==1{print $$2}')
export DOMAIN ?= $(IP_ADDR).sslip.io
export EPINIO_SERVER_VERSION ?= 1.3.0
export DNS_ZONE_NAME ?= example.com

# Set keys if it is for dev and prod deployments
export AWS_HOSTED_ZONE_ID ?= XXXXX
export AWS_ACCESS_KEY_ID  ?= XXXXX
export AWS_SECRET_ACCESS_KEY ?= XXXXX
export AWS_SECRET_ACCESS_KEY_CRYPTO := '$(shell echo -n ${AWS_SECRET_ACCESS_KEY} | base64)'

# sudo systemctl stop apache2; sudo systemctl disable apache2
check-port-block:
	-nc -z  localhost 80  && echo "port 80  is being used. please kill that process" ; exit 1
	-nc -z  localhost 443 && echo "port 443 is being used. please kill that process" ; exit 1

check-dependencies: check-port-block
	command -v docker && echo "docker - ok"
	command -v k3d && echo "k3d - ok"
	command -v kubectl && echo "kubectl - ok"
	command -v helm && echo "helm - ok"
	command -v epinio && echo "epinio - ok"
	command -v htpasswd && echo "htpasswd - ok"
	command -v nc && echo "nc - ok"

delete-cluster:
	k3d cluster delete $(CLUSTER_NAME)
	docker-compose -f pomerium/docker-compose.yaml down
	-rm pomerium/pomerium-cert.crt
	-rm pomerium/_wildcard.172.18.0.1.sslip.io-key.pem
	-rm pomerium/_wildcard.172.18.0.1.sslip.io.pem
	-rm pomerium/pomerium-cert.key
	-rm pomerium/pomerium-config.yaml
	-rm pomerium/identityprovider-users.json
	-rm pomerium/identityprovider.json
	-rm pomerium/docker-compose.yaml
	-rm dex-config.yaml
	-rm epinioIssuer.yaml
	-rm wildcardCertificate.yaml

# Installation

install-cert-manager:
	kubectl create namespace cert-manager
	helm repo add jetstack https://charts.jetstack.io
	helm repo update
	helm install cert-manager --namespace cert-manager jetstack/cert-manager \
		--set installCRDs=true \
		--set extraArgs[0]=--enable-certificate-owner-ref=true

create-cluster:
	#k3d cluster create $(CLUSTER_NAME) -p '80:80@loadbalancer' -p '443:443@loadbalancer'
	k3d cluster create epinio --k3s-arg "--disable=traefik@server:0" -p '8080:80@loadbalancer' -p '8443:443@loadbalancer'
	kubectl rollout status deployment metrics-server -n kube-system --timeout=480s
	
	# Install Traefik manually
	helm repo add traefik https://helm.traefik.io/traefik && helm repo update
	helm install traefik -n traefik --create-namespace  traefik/traefik

deploy-epinio:
	./makefile.sh deploy-epinio


install-epinio:
	@echo "\n\n****** Checking dependencies..."
	$(MAKE) check-dependencies

#	@echo "\n\n****** Checking for manadory ENVs..."
#	./makefile.sh check-envs

	@echo "\n\n****** Create k3d cluster..."
	-$(MAKE) create-cluster

	@echo "\n\n****** Deploy cert-manager into cluster..."
	-$(MAKE) install-cert-manager

	@echo "\n\n****** Deploy epinio into cluster..."
	$(MAKE) deploy-epinio

	@echo "\n\n****** Deploy neuvector into cluster..."
	$(MAKE) deploy-neuvector

	@echo "\n\n****** Deploy Pomerium"
	$(MAKE) deploy-pomerium

deploy-neuvector:
	./makefile.sh deploy-neuvector
	# sleep while neuvector boots
	sleep 60

deploy-pomerium:
	./makefile.sh deploy-pomerium