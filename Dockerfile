FROM alpine:3.20
COPY app/server.sh /server.sh
RUN chmod +x /server.sh
EXPOSE 8080
ENTRYPOINT ["/server.sh"]
