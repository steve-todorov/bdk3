FROM alpine:3.20
RUN apk add --no-cache busybox-extras
COPY app/server.sh /server.sh
RUN chmod +x /server.sh
EXPOSE 8080
ENTRYPOINT ["/server.sh"]


