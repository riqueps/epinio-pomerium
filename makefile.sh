#!/bin/bash

set -e
shopt -s expand_aliases


function check-envs {

	# Check if required env is set, if not exit in errors
	REQ_ENVS=(
	  AWS_ACCESS_KEY_ID AWS_HOSTED_ZONE_ID AWS_SECRET_ACCESS_KEY
	)
	TO_EXIT=0
	
	if [[ ${DOMAIN} != *"sslip"* ]]; then

		for ENV_NAME in ${REQ_ENVS[@]}; do
		  if [ -z $(printenv ${ENV_NAME}) ] || [ "$(printenv ${ENV_NAME})" = "null" ]; then
		    echo "Required environment NOT initialized: ${ENV_NAME}"
		    TO_EXIT=1
		  fi
		done
		if [ ${TO_EXIT} -eq 1 ]; then
		  echo "Above required enivronment(s) is not set properly. Crashing application deliberately"
		  exit 1
		fi
	fi
}

function deploy-epinio {
	helm repo add epinio https://epinio.github.io/helm-charts && helm repo update
#	kubectl rollout status deployment traefik -n traefik --timeout=480s
	kubectl create namespace traefik
	helm uninstall -n epinio epinio && sleep 15

	# check if domain is not set, means local dev env, else developerment env
	if [[ ${DOMAIN} == *"sslip"* ]]; then
		TLS_ISSUER=selfsigned-issuer
	else
		# Development or Prod landscape using LetsEncrypt with Route53
		TLS_ISSUER=letsencrypt-epinio
		
		# Modify yamls with AWS keys and secrets - to request for LetsEncrypt cert via CertManager
		cat epinioIssuer.yaml.template > epinioIssuer.yaml
		sed -i "s/accessKeyID:.*/accessKeyID: ${AWS_ACCESS_KEY_ID}/g" epinioIssuer.yaml
		sed -i "s/secret-access-key:.*/secret-access-key: ${AWS_SECRET_ACCESS_KEY_CRYPTO}/g" epinioIssuer.yaml
		sed -i "s/hostedZoneID:.*/hostedZoneID: ${AWS_HOSTED_ZONE_ID}/g" epinioIssuer.yaml
		kubectl apply -f epinioIssuer.yaml

		if [[ -z ${PROD} ]]; then
			echo "\nWildcard LetsEncrypt Configurations..."
			cat wildcardCertificate.yaml.template > wildcardCertificate.yaml
			sed -i "s/commonName:.*/commonName: '*.${DOMAIN}'/g" wildcardCertificate.yaml
			sed -i "s/- .*/- '*.${DOMAIN}'/g" wildcardCertificate.yaml
			kubectl apply -f wildcardCertificate.yaml
			
			echo -e "\nWaiting for TLS certificate to be ready, this can take a while..."
			kubectl wait --for=condition=ready certificate epinio -n traefik --timeout=480s
			# kubectl apply -f defaultCert.yaml
		else
			echo "\nProduction/Default LetsEncrypt Configurations..."
			echo "Note: Certificates of new apps takes > 60 seconds to be ready!"
		fi
	fi

	helm install epinio -n epinio --create-namespace --version ${EPINIO_SERVER_VERSION} epinio/epinio \
		--set global.domain=${DOMAIN} \
		--set ingress.ingressClassName=pomerium \
		--set 'ingress.annotations.ingress\.pomerium\.io/allow_public_unauthenticated_access=true' \
		--set 'ingress.annotations.ingress\.pomerium\.io/pass_identity_headers=true' \
		--set 'ingress.annotations.ingress\.pomerium\.io/tls_skip_verify=true' \
		--set global.tlsIssuer=${TLS_ISSUER}
		
	kubectl rollout status deployment epinio-server -n epinio --timeout=480s
}

#src: https://docs.epinio.io/references/authorization#add-a-new-user

function deploy-neuvector {
	helm repo add neuvector https://neuvector.github.io/neuvector-helm/
	cat neuvector.yaml.template > neuvector.yaml
	sed -i "s/host:.*/host: 'neuvector.${DOMAIN}'/g" neuvector.yaml
	helm install neuvector --create-namespace --namespace neuvector neuvector/core --values neuvector.yaml
	rm neuvector.yaml
}

function deploy-pomerium-docker {
	# Setup SSL certificates for Pomerium
	if [[ ${DOMAIN} == *"sslip"* ]];
	then
		(cd pomerium/ && mkcert "*.${DOMAIN}")
		(cd pomerium/ && cat docker-compose.yaml.template > docker-compose.yaml)
		(cd pomerium/ && sed -i "s/DOMAIN-CERT-KEY/_wildcard.${DOMAIN}-key.pem/g" docker-compose.yaml)
		(cd pomerium/ && sed -i "s/DOMAIN-CERT/_wildcard.${DOMAIN}.pem/g" docker-compose.yaml)
	else
		kubectl get secret -n traefik epinio-tls -o jsonpath="{.data['tls\.crt']}" | base64 -d > pomerium/pomerium-cert.crt
		kubectl get secret -n traefik epinio-tls -o jsonpath="{.data['tls\.key']}" | base64 -d > pomerium/pomerium-cert.key
		(cd pomerium/ && cat docker-compose.yaml.template > docker-compose.yaml)
		(cd pomerium/ && sed -i "s/DOMAIN-CERT-KEY/pomerium-cert.key/g" docker-compose.yaml)
		(cd pomerium/ && sed -i "s/DOMAIN-CERT/pomerium-cert.crt/g" docker-compose.yaml)
	fi
	# Setup Pomerium OIDC provider
	cat pomerium/identityprovider.json.template > pomerium/identityprovider.json
	sed -i "s/DOMAIN/${DOMAIN}/g" pomerium/identityprovider.json
	
	cat pomerium/identityprovider-users.json.template > pomerium/identityprovider-users.json
	sed -i "s/USER/${USER}/g" pomerium/identityprovider-users.json
	sed -i "s/PASSWORD/${PASSWORD}/g" pomerium/identityprovider-users.json

	cat pomerium/pomerium-config.yaml.template > pomerium/pomerium-config.yaml
	sed -i "s/DOMAIN/${DOMAIN}/g" pomerium/pomerium-config.yaml
	
	docker-compose -f pomerium/docker-compose.yaml up -d

	# Setup Dex
	kubectl get secret -n epinio dex-config -o jsonpath="{.data['config\.yaml']}" | base64 -d > dex-config.yaml
	echo " " >> dex-config.yaml
	echo " " >> dex-config.yaml
	echo "connectors:" >> dex-config.yaml
	echo "- type: oidc" >> dex-config.yaml
	echo "  id: dex_id" >> dex-config.yaml
	echo "  name: Dex" >> dex-config.yaml
	echo "  config:" >> dex-config.yaml
	echo "    issuer: http://idp.${DOMAIN}:9000" >> dex-config.yaml
	echo "    clientID: dex_id" >> dex-config.yaml
	echo "    clientSecret: dex_secret" >> dex-config.yaml
	echo "    redirectURI: https://auth.${DOMAIN}/callback" >> dex-config.yaml
	echo "    scopes:" >> dex-config.yaml
	echo "     - profile" >> dex-config.yaml
	echo "     - email" >> dex-config.yaml
	echo "     - openid" >> dex-config.yaml
	kubectl get secret -n epinio dex-config -o json | jq --arg DEX_CONFIG "$(cat dex-config.yaml | base64)" '.data["config.yaml"]=$DEX_CONFIG' | kubectl apply -f -
	kubectl delete pod -n epinio $(kubectl get pods -n epinio | grep dex | awk '{print $1}')
	
}

function deploy-pomerium {
	# OIDC
	sleep 10
	# users
	cat pomerium/oidc-user-configmap.yaml.template > pomerium/oidc-user-configmap.yaml
	sed -i "s/USER/${ORBITADM_USR}/g" pomerium/oidc-user-configmap.yaml
	sed -i "s/PASSWORD/${ORBITADM_PWD}/g" pomerium/oidc-user-configmap.yaml
	kubectl apply -f pomerium/oidc-user-configmap.yaml
	# oidc clients
	cat pomerium/oidc-provider-configmap.yaml.template > pomerium/oidc-provider-configmap.yaml
	sed -i "s/DOMAIN/${DOMAIN}/g" pomerium/oidc-provider-configmap.yaml
	kubectl apply -f pomerium/oidc-provider-configmap.yaml
	# svc and deployment
	kubectl apply -f pomerium/oidc-svc.yaml
	kubectl apply -f pomerium/oidc-deployment.yaml
	# ingress
	cat pomerium/oidc-ingress.yaml.template > pomerium/oidc-ingress.yaml
	sed -i "s/DOMAIN/${DOMAIN}/g" pomerium/oidc-ingress.yaml
	kubectl apply -f pomerium/oidc-ingress.yaml
	
	# Pomerium
	sleep 10
	kubectl apply -f https://raw.githubusercontent.com/pomerium/ingress-controller/main/deployment.yaml
	cat pomerium/pomerium.yaml.template > pomerium/pomerium.yaml
	sed -i "s/DOMAIN/${DOMAIN}/g" pomerium/pomerium.yaml
	
	if [[ ${DOMAIN} == *"sslip"* ]]; then
		cat pomerium/pomerium-cert.yaml.template > pomerium/pomerium-cert.yaml
		sed -i "s/TLS_ISSUER_NAME/selfsigned-issuer/g" pomerium/pomerium-cert.yaml
		sed -i "s/DOMAIN/${DOMAIN}/g" pomerium/pomerium-cert.yaml
		kubectl apply -f pomerium/pomerium-cert.yaml
		kubectl apply -f pomerium/pomerium.yaml
	else
		sed -i "s|pomerium/pomerium-proxy-tls|traefik/epinio-tls|g" pomerium/pomerium.yaml
		kubectl apply -f pomerium/pomerium.yaml
	fi
	
	# Dex
	sleep 10
	kubectl get secret -n epinio dex-config -o jsonpath="{.data['config\.yaml']}" | base64 -d > dex-config.yaml
	echo " " >> dex-config.yaml
	echo " " >> dex-config.yaml
	echo "connectors:" >> dex-config.yaml
	echo "- type: oidc" >> dex-config.yaml
	echo "  id: dex_id" >> dex-config.yaml
	echo "  name: Dex" >> dex-config.yaml
	echo "  config:" >> dex-config.yaml
	echo "    issuer: https://idp.${DOMAIN}" >> dex-config.yaml
	echo "    clientID: dex_id" >> dex-config.yaml
	echo "    clientSecret: dex_secret" >> dex-config.yaml
	echo "    redirectURI: https://auth.${DOMAIN}/callback" >> dex-config.yaml
	echo "    scopes:" >> dex-config.yaml
	echo "     - profile" >> dex-config.yaml
	echo "     - email" >> dex-config.yaml
	echo "     - openid" >> dex-config.yaml
	kubectl get secret -n epinio dex-config -o json | jq --arg DEX_CONFIG "$(cat dex-config.yaml | base64)" '.data["config.yaml"]=$DEX_CONFIG' | kubectl apply -f -
	kubectl delete pod -n epinio $(kubectl get pods -n epinio | grep dex | awk '{print $1}')

	kubectl annotate ingress -n epinio dex ingress.pomerium.io/pass_identity_headers="true"
	kubectl annotate ingress -n epinio dex ingress.pomerium.io/allow_public_unauthenticated_access="true"
	kubectl annotate ingress -n epinio dex --overwrite kubernetes.io/ingress.class="pomerium"
}

$*
