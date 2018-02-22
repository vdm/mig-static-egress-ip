# mig-static-egress-ip

Google Compute Engine (GCE) Managed Instance Group (MIG) instances are assigned ephemeral public IP addresses and this [can](https://groups.google.com/forum/#!topic/kubernetes-users/C34yKt0qKtY) [not](https://groups.google.com/forum/#!topic/kubernetes-users/zNytc8GVB5s) be configured. This is a problem for any processes on those instances which need to communicate with old-fashioned third-party servers which insist on whitelisting client IPs.

A static IP can be assigned to an existing VM with the GCE 'access-config' API. `mig-static-egress-ip.bash` runs on the VM, identifying the VM from the GCE metadata server, and then using gcloud to both check whether any current external IP is static, and if not replace it. It will also work where there is no assigned public IP, allowing this option to be selected in the MIG instance template, and saving assigning an ephemeral IP only to immediate delete it.

If there is no allocated and unassigned static IP available, the script will exit with a non-zero code. It does not attempt to allocate such IPs itself, because whitelisting them normally requires humans.

## Diagnostics
```
$ gcloud compute addresses list
NAME  REGION        ADDRESS      STATUS
a1    europe-west1  104.x.x.127  RESERVED
a2    europe-west1  35.x.x.12    IN_USE
```

```
$ gcloud compute instances describe INSTANCE --format='value(networkInterfaces[0].accessConfigs[0])'
kind=compute#accessConfig;name=External NAT;natIP=35.x.x.12;type=ONE_TO_ONE_NAT
```

## Configuration
```
$ gcloud config set project PROJECT
$ gcloud config set compute/zone europe-west1-d
$ gcloud config list
```

Without "Private Google Access" enabled, `delete-access-config` will work with an ephemeral IP but then the following call to `add-access-config` will fail because the GCE VM can not access the Compute Engine API. This also prevents logs from being shipped to Stackdriver Logging.
```
$ gcloud compute networks subnets update default --enable-private-ip-google-access
```

`--region` needs to match `compute/zone` above.
```
$ gcloud compute addresses create a1 --region europe-west1
$ gcloud compute addresses create a2 --region europe-west1
```

## Usage
### Kubernetes [init container](https://kubernetes.io/docs/concepts/workloads/pods/init-containers/)
This can be used by any Pod that requires an egress static IP. Here we use a Job to demonstrate, but it should also work with a Deployment or other Pod.

The https://www.googleapis.com/auth/compute (compute-rw) OAuth scope is not assigned by default in GKE and is required for address enumeration and assignment.
```
$ gcloud container clusters create test --preemptible --num-nodes=1 --scopes=gke-default,compute-rw
$ gcloud container clusters get-credentials test
```

#### Before
```
$ kubectl run test -it --quiet --rm --restart=Never --image=google/cloud-sdk -- curl -s https://ifconfig.co/
35.x.x.198
```

```
$ kubectl apply k8s.yaml
```

#### After
```
$ kubectl logs job/curl-egress-ip
104.x.x.127
```

## Docker container (without K8S)
Does not use Kubernetes. Works for GKE GCE VMs. Docker Hub image: [vdm1/mig-egress-static-ip](https://hub.docker.com/r/vdm1/mig-egress-static-ip/)

```
local$ gcloud compute ssh INSTANCE
ssh$ docker run vdm1/mig-static-egress-ip
+ gcloud compute instances delete-access-config INSTANCE '--access-config-name=External NAT'
Updated [https://www.googleapis.com/compute/v1/projects/p/zones/europe-west1-d/instances/INSTANCE].
+ gcloud compute instances add-access-config INSTANCE --address 35.x.x.12
```

[Connection is lost here. Escape from ssh by pressing Enter ~ .]
```
Connection to 104.x.x.32 closed.
ERROR: (gcloud.compute.ssh) [/usr/local/bin/ssh] exited with return code [255].
```

## Script on GCE VM
### As startup-script
```
$ gcloud compute instances create INSTANCE --scopes=default,compute-rw --metadata-from-file=startup-script=mig-static-egress-ip.bash [--no-address]
```

### After startup
```
bash$ <mig-static-egress-ip.bash gcloud compute ssh INSTANCE -- -t
```

# Dependencies (tested versions)
```
$ gcloud version
Google Cloud SDK 189.0.0
```

* grep (not busybox)
* awk

# TODO
Least privilege IAM configuration, restricted beyond the coarse compute-rw GCE Scope.

Usage: MIG Instance Template startup-script.

Script could be ['injected' as a Kubernetes ConfigMap](http://blog.phymata.com/2017/07/29/inject-an-executable-script-into-a-container-in-kubernetes/ ) allowing the google/cloud-sdk image to be used directly, rather than the Docker Hub image built from this repo.

This script assumes a single pool of addresses designated only by whether they are static/not ephemeral. Multiple 'pools' could be designated by GCE [_Labels_](https://cloud.google.com/compute/docs/labeling-resources) (alpha).

# Caveats
There is a risk of disrupting already established outbound connections on the node at the time the IP is assigned.

The 0th access config of the 0th network interface on the GCE VM is hard-coded.

A static public IP assigned to a node will not be released until that node dies, even if no existing workload on the node actually requires the IP. This could be addressed by counting leases with a semaphore around the static IP address resource, released at Pod `preStop`. Perhaps nodes will be recycled often and not live long enough for this to be an issue.

Having a process on the the VM itself run the calls like this does require some non-default privileges, but the trade-off ensures that the calls are only made after the VM has entered the required state, which can be unreliable to coordinate with an extra process. Checking whether the currently assigned IP is ephemeral first should make the script idempotent (safe to run more than once, e.g. if another Pod on the same Google Kubernetes Engine (GKE) Node has already run it).

Perhaps one day instance templates will be enabled to create or use an unassigned static (labelled) address, thus making this unnecessary. [@@ GCP Issue]

# Alternatives
## Script run in a Daemonset instead of initContainer
* Would have the advantage of running before other workloads' pods, so they can safely change the IP before there are other workloads to disrupt on the same node.
* On the other hand it might use up static IPs which are otherwise not needed by any workloads that happen to be currently scheduled on the node. 
http://blog.phymata.com/2017/05/13/run-once-daemonset-on-kubernetes/ could work but you have to delete the daemonset from kubectl which means changing the deploy.sh script.
* The K8S contrib [startup-script](https://github.com/kubernetes/contrib/tree/master/startup-script) Daemonset did not seem to support depending on a different Docker image, which this script requires. Also like the Daemonset workaround, it implements a 'checkpoint' workaround to make the script run just once on startup and not forever.
* Alternatively, an initContainer should run at least once for each pod.

## Cloud Function triggered by Pubsub export from Stackdriver Logging
* Encountered multiple race conditions between API calls and VM state at time of log events.
* node.js Google API client was much less convenient than gcloud in bash.

## GCE NAT Gateway
I believe this is the closest equivalent configuration: https://cloud.google.com/vpc/docs/special-configurations#multiple-natgateways

Cons
* provisioning and operation of extra special GCE VMs.
* extra routing configuration.
* per-GCP-project overhead.
