#!/bin/sh
##
# Script to deploy a Kubernetes project with a StatefulSet running a MongoDB Replica Set, to GKE.
## https://github.com/cvallance/mongo-k8s-sidecar/issues/32
## https://codelabs.developers.google.com/codelabs/cloud-mongodb-statefulset/index.html?index=..%2F..%2Findex#7


# Create new GKE Kubernetes cluster (using host node VM images based on Ubuntu
# rather than ChromiumOS default & also use slightly larger VMs than default)

GKE_MONGODB_CLUSTER=gke-mongodb-cluster
ZONE=us-central1-a
GKE_PROJECT=sylvainleroy-blog
VM_SIZE=n1-highcpu-2
REPLICAS=3 # Don't forget to modify the service...

echo "Creation of cluster"
gcloud compute project-info describe --project ${GKE_PROJECT}
gcloud container clusters create "${GKE_MONGODB_CLUSTER}" --image-type=UBUNTU --machine-type=${VM_SIZE}
gcloud container clusters get-credentials ${GKE_MONGODB_CLUSTER} --zone ${ZONE} --project ${GKE_PROJECT}
gcloud config set container/cluster ${GKE_MONGODB_CLUSTER}

echo "Configure host VM using daemonset to disable hugepages"
kubectl apply -f ../resources/hostvm-node-configurer-daemonset.yaml

# Register GCE Fast SSD persistent disks and then create the persistent disks
echo "Creating GCE disks"
kubectl apply -f ../resources/fast-storageclass.yaml
kubectl apply -f ../resources/slow-storageclass.yaml
sleep 5
for i in {1..$REPLICAS}
do
    gcloud compute disks create --size 10GB --type pd-ssd pd-ssd-disk-$i
done
sleep 3

# Create persistent volumes using disks created above
echo "Creating GKE Persistent Volumes"
for i in {1..$REPLICAS}
do
    sed -e "s/INST/${i}/g" ../resources/xfs-gce-ssd-persistentvolume.yaml > /tmp/xfs-gce-ssd-persistentvolume.yaml
    kubectl apply -f /tmp/xfs-gce-ssd-persistentvolume.yaml
done
rm /tmp/xfs-gce-ssd-persistentvolume.yaml
sleep 3

echo "Create keyfile for the MongoD cluster as a Kubernetes shared secret"
TMPFILE=$(mktemp)
/usr/bin/openssl rand -base64 741 > $TMPFILE
kubectl create secret generic shared-bootstrap-data --from-file=internal-auth-mongodb-keyfile=$TMPFILE
rm $TMPFILE

echo "Create mongodb service with mongod stateful-set"
sed -e "s/REPLICAS_NUMBER/${REPLICAS}/g" ../resources/mongodb-service.yaml > /tmp/mongodb-service.yaml
kubectl apply -f /tmp/mongodb-service.yaml

echo

# Wait until the final (3rd) mongod has started properly
echo "Waiting for the 3 containers to come up (`date`)..."
echo " (IGNORE any reported not found & connection errors)"
sleep 30
echo -n "  "
until kubectl --v=0 exec mongod-2 -c mongod-container -- mongo --quiet --eval 'db.getMongo()'; do
    sleep 5
    echo -n "  "
done
echo "...mongod containers are now running (`date`)"
echo

for i in {1..$REPLICAS}
do
    kubectl expose pod mongod-${i} --name mongod-${i} --type NodePort
done


# Print current deployment state
kubectl get persistentvolumes
echo
kubectl get all

