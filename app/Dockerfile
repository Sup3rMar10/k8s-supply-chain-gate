FROM nginxinc/nginx-unprivileged:1.27-alpine

ARG APP_VERSION=dev

COPY default.conf /etc/nginx/conf.d/default.conf

# The base image runs as uid 101; package upgrades and writing into the web root need root for these steps.
USER root
# The first pipeline run failed the vulnerability gate on this image: a CRITICAL openssl CVE that the
# base image had not yet picked up but Alpine had already fixed. Upgrading the packages clears it.
RUN apk upgrade --no-cache
RUN echo "${APP_VERSION}" > /usr/share/nginx/html/version.txt
USER 101
