# Bonus - Static showcase website (plain HTML/CSS/JS, no PHP at all)
FROM debian:bookworm

LABEL maintainer="Inception - static site"

RUN apt-get update && \
    apt-get install -y --no-install-recommends nginx && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

COPY conf/static.conf /etc/nginx/conf.d/static.conf
COPY site/ /var/www/static/

RUN rm -f /etc/nginx/sites-enabled/default && \
    chown -R www-data:www-data /var/www/static

EXPOSE 8080

CMD ["nginx", "-g", "daemon off;"]
