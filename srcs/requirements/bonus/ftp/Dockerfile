# Bonus - FTP server pointing to the WordPress website volume
FROM debian:bookworm

LABEL maintainer="Inception - vsftpd"

RUN apt-get update && \
    apt-get install -y --no-install-recommends vsftpd && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

COPY conf/vsftpd.conf /etc/vsftpd.conf
COPY tools/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN chmod +x /usr/local/bin/docker-entrypoint.sh && \
    mkdir -p /var/run/vsftpd/empty /var/www/html && \
    ln -sf /proc/1/fd/1 /var/log/vsftpd.log && \
    # PAM rejects an account whose shell is not listed in /etc/shells, and the
    # FTP user must not be able to open a real shell.
    echo "/usr/sbin/nologin" >> /etc/shells

EXPOSE 21 21000-21010

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
# -obackground=NO keeps vsftpd in the foreground as PID 1.
CMD ["/usr/sbin/vsftpd", "/etc/vsftpd.conf", "-obackground=NO"]
