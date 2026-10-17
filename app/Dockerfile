FROM nginxinc/nginx-unprivileged:1.27-alpine

ARG APP_VERSION=dev

COPY default.conf /etc/nginx/conf.d/default.conf

# The base image runs as uid 101; writing into the web root needs root for one step.
USER root
RUN echo "${APP_VERSION}" > /usr/share/nginx/html/version.txt
USER 101
