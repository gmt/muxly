FROM alpine:3.22

RUN apk add --no-cache iproute2 socat

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
