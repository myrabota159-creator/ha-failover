FROM alpine:3.22
RUN apk add --no-cache bash jq coreutils tar gzip curl findutils net-snmp-tools tzdata
COPY lib.sh run.sh failover.sh snmp.sh watchdog.sh notify.sh return.sh /
RUN chmod +x /run.sh /failover.sh /snmp.sh /watchdog.sh /notify.sh /return.sh
CMD ["/run.sh"]
