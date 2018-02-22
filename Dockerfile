FROM google/cloud-sdk
COPY mig-static-egress-ip.bash mig-static-egress-ip.bash
ENTRYPOINT ["./mig-static-egress-ip.bash"]
