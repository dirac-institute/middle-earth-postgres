# Service VM monitor: CPU, memory, disk and load of this VM, served on :9110 for
# the gadget monitor. Self-contained: copy this folder into a service's repo
# and add the compose entry from README.md.
FROM docker.io/library/python:3.13.15-slim-trixie

COPY service_vm_monitor.py /srv/service_vm_monitor.py

EXPOSE 9110
CMD ["python3", "-u", "/srv/service_vm_monitor.py"]
