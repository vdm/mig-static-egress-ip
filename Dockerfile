FROM google/cloud-sdk
COPY gce-static-egress-ip.bash gce-static-egress-ip.bash
ENTRYPOINT ["./gce-static-egress-ip.bash"]
