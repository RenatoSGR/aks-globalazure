#########################
######   ISTIO   ########
#########################

#App-Routing

# create the app-routing-ingress yaml definition
kubectl apply -f .\app-routing-ingress.yaml

# get the public IP of the app-routing addon
kubectl get svc nginx -n app-routing-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# curl the store-admin service via the app-routing addon
curl http://<app-routing-ip>


# retry the certificate uri from the key vault needed for the ingress definition
az keyvault certificate show --vault-name  $VAULT_NAME -n aks-ingress-tls --query "id" --output tsv

#copy the uri to the app-routing-ingress-tls.yaml file and apply it
kubectl apply -f .\app-routing-ingress-tls.yaml  

# retrieve the certificate uri from the key vault needed for the ingress definition
az keyvault certificate show --vault-name  $VAULT_NAME -n aks-ingress-tls --query "id" --output tsv

#########################
###### Observabiliy  ####
#########################





#########################
#### Workload Itentity ##
#########################

# verify that csi secret provider is enabled
kubectl get pods -n kube-system -l 'app in (secrets-store-csi-driver,secrets-store-provider-azure)'

# create the identity for the workload identity (already created)
export UAMI=wiglobalazurepmsi2

# create te identity (already created)
az identity create --name $UAMI --resource-group $RESOURCE_GROUP

export USER_ASSIGNED_CLIENT_ID="$(az identity show -g $RESOURCE_GROUP --name $UAMI --query 'clientId' -o tsv)"
export IDENTITY_TENANT=$(az aks show --name $CLUSTER --resource-group $RESOURCE_GROUP --query identity.tenantId -o tsv)
export KEYVAULT_SCOPE=$(az keyvault show --name $VAULT_NAME --query id -o tsv)

# create the role assignment for the identity to access the key vault (already created)
az role assignment create --role "Key Vault Administrator" --assignee $USER_ASSIGNED_CLIENT_ID --scope $KEYVAULT_SCOPE

export AKS_OIDC_ISSUER="$(az aks show --resource-group $RESOURCE_GROUP --name $CLUSTER --query "oidcIssuerProfile.issuerUrl" -o tsv)"
echo $AKS_OIDC_ISSUER
export SERVICE_ACCOUNT_NAME="workload-identity-sa"  
export SERVICE_ACCOUNT_NAMESPACE="aksappga" 

# create the service account with the workload identity annotation clientID
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    azure.workload.identity/client-id: ${USER_ASSIGNED_CLIENT_ID}
  name: ${SERVICE_ACCOUNT_NAME}
  namespace: ${SERVICE_ACCOUNT_NAMESPACE}
EOF

# create the federated identity for the workload identity
export FEDERATED_IDENTITY_NAME="aksglobalazurefederatedidentity2"

# create the federated identity for the workload identity
az identity federated-credential create --name $FEDERATED_IDENTITY_NAME --identity-name $UAMI --resource-group $RESOURCE_GROUP --issuer ${AKS_OIDC_ISSUER} --subject system:serviceaccount:${SERVICE_ACCOUNT_NAMESPACE}:${SERVICE_ACCOUNT_NAME}

# create the secret in the key vault
az keyvault secret show --vault-name $VAULT_NAME --name openaiapikey

# create the secret provider class with the workload identity to access the key vault to retrieve the openai api key
cat <<EOF | kubectl apply -f -
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: globalazure-wi                     # needs to be unique per namespace
  namespace: aksappga
spec:
  provider: azure
  secretObjects:                           # [OPTIONAL] SecretObjects defines the desired state of synced Kubernetes secret objects
  - data:
    - key: keyopenai                       # data field to populate
      objectName: openaiapikey             # name of the mounted content to sync; this could be the object name or the object alias
    secretName: openaisecret               # name of the Kubernetes secret object
    type: Opaque       
  parameters:
    usePodIdentity: "false"
    clientID: "${USER_ASSIGNED_CLIENT_ID}" # Setting this to use workload identity
    keyvaultName: ${VAULT_NAME}         # Set to the name of your key vault
    cloudName: ""                          # [OPTIONAL for Azure] if not provided, the Azure environment defaults to AzurePublicCloud
    objects:  |
      array:
        - |
          objectName: openaiapikey        # Set to the name of your secret
          objectType: secret              # object types: secret, key, or cert
          objectVersion: ""               # [OPTIONAL] object versions, default to latest if empty
    tenantId: "${IDENTITY_TENANT}"        # The tenant ID of the key vault
EOF

# verify the secret provider class created
kubectl get secretproviderclass -n aksappga

# describe the secret provider class 
kubectl describe secretproviderclass globalazure-wi -n aksappga

# verify the secret created
kubectl get secret openaisecret -n aksappga

# apply the ai-service deployment
kubectl apply -f ai-service-v2.yaml

kubectl get pods -n aksappga

# check the env vars on pod, and confirm the openai api key is being retrieved from the key vault
kubectl get pods -n aksappga
kubectl -n aksappga exec -it <pod-name> -c ai-service -- /bin/sh
env


#########################
###### Karpenter ########
#########################

