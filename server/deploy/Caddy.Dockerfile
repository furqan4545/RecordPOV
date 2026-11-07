FROM caddy:2-alpine
RUN addgroup -g 10002 recordpov-edge \
 && adduser -D -H -u 10002 -G recordpov-edge recordpov-edge \
 && chown -R 10002:10002 /data /config
USER 10002:10002
