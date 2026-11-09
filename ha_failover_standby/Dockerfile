FROM alpine:3.22
RUN apk add --no-cache bash jq coreutils tar gzip curl findutils net-snmp-tools tzdata sqlite
COPY lib.sh run.sh failover.sh snmp.sh watchdog.sh notify.sh return.sh setup.sh /
RUN chmod +x /run.sh /failover.sh /snmp.sh /watchdog.sh /notify.sh /return.sh /setup.sh
CMD ["/run.sh"]
