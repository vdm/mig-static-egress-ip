#!/bin/bash
set -o errexit
set -uo pipefail

do_curl() {
  curl --fail --silent --show-error -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/$1;
} 
# subshell inherit_errexit doesn't work
do_curl "" >/dev/null 2>&1 || \
  { echo "curl GCE metadata server error" 1>&2; exit 4; }

# instead of gcloud --zone 
export CLOUDSDK_COMPUTE_ZONE=$(do_curl zone | awk -F/ '{print $NF}')

# errexit if gcloud does not work
gcloud compute zones list >/dev/null || { echo "gcloud error" 1>&2; exit 3; }

get_ips() {
  # awk: https://unix.stackexchange.com/a/234436
  gcloud compute addresses list \
    --filter="region:$(echo $CLOUDSDK_COMPUTE_ZONE | awk -F- 'NF{OFS="-"; NF--}1') status=$1" \
    --format='value(address)';
}

# hardcodes network interface, access-config, does not work for multiple
export CURR_IP=$(do_curl network-interfaces/0/access-configs/0/external-ip)

if get_ips "IN_USE" | grep -q "$CURR_IP"; then
  echo "currently assigned $CURR_IP is IN_USE/static";
else
  export NEW_IP=$(get_ips "RESERVED" | head -1)
  if [ -n "$NEW_IP" ]; then
    export NODE=$(do_curl name)

    if [ -n "$CURR_IP" ]; then
      echo "replacing ephemeral IP $CURR_IP"
      # GCE webapp creates non-default --access-config-name "External NAT"
      export NAME="$(gcloud compute instances describe $NODE \
        --format='value(networkInterfaces[0].accessConfigs[0].name)')"
      set -x; gcloud compute instances delete-access-config $NODE \
        --access-config-name="${NAME[*]}";
    else
      echo "no assigned ephemeral IP (None)";
    fi

    # default --access-config-name
    set -x; gcloud compute instances add-access-config $NODE --address $NEW_IP
  else
    echo "unassigned reserved IP not available" 1>&2
    # not `gcloud compute addresses create` -ing here, because you might forget
    #  to ensure it is whitelisted
    exit 1;
  fi;
fi;
