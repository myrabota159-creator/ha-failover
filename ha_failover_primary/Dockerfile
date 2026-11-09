FROM alpine:3.22
RUN apk add --no-cache bash python3 jq curl sqlite openssl tar gzip coreutils
COPY run.sh server.py export.sh /
RUN chmod +x /run.sh /server.py /export.sh
CMD ["/run.sh"]
