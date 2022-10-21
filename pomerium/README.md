make install-epinio

generate certs:
mkcert "*.LOCAL_MACHINE_IP.sslip.io"

get traefik IP
docker container inspect k3d-epinio-server-0 | jq -r '.[].NetworkSettings.Networks."k3d-epinio".IPAddress'

kubectl create secret tls dex1-tls --namespace=epinio \
  --cert=./_wildcard.172.18.0.1.sslip.io.pem --key=./_wildcard.172.18.0.1.sslip.io-key.pem

get dex config
kubectl get secret -n epinio dex-config -o jsonpath="{.data['config\.yaml']}" | base64 -d > dex-config.yaml

## Install with valid certificates

DOMAIN=xxxx make install-epinio

Create DNS entry on route53 pointing to your local private ip (192.168..x.x or 10.0.x.x ...)

Export certificate for pomerium:
openssl x509 -in henrique.crt -out henrique.pem -outform PEM

kubectl get secret -n epinio dex-tls -o jsonpath="{.data['tls\.crt']}" | base64 -d > henrique.crt

convert crt to pem



kubectl get secret -n epinio dex-tls -o jsonpath="{.data['tls\.key']}" | base64 -d > henrique.key

docker-compose up


kubectl get secret -n epinio $(kubectl get secret -n epinio | grep ruser-orbitadmspeedy | awk '{print $1}') -o json | jq --arg EPINIO_ROLE "admin" '.metadata.labels["epinio.io/role"]=$EPINIO_ROLE' | kubectl apply -f -