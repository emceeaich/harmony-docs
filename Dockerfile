ARG BZDB="-mysql8"
FROM bugzilla/bugzilla-perl-slim${BZDB}:20240419.1

ENV DEBIAN_FRONTEND noninteractive

ENV LOG4PERL_CONFIG_FILE=log4perl-json.conf

RUN apt-get install -y rsync

# we run a loopback logging server on this TCP port.
ENV LOGGING_PORT=5880

ENV LOCALCONFIG_ENV=1

WORKDIR /app

COPY . /app

RUN chown -R app:app /app && \
    perl -I/app -I/app/local/lib/perl5 -c -E 'use Bugzilla; BEGIN { Bugzilla->extensions }' && \
    perl -c /app/scripts/entrypoint.pl

USER app

RUN perl checksetup.pl --no-database --default-localconfig && \
    rm -rf /app/data /app/localconfig && \
    mkdir /app/data

EXPOSE 8000

ENTRYPOINT ["/app/scripts/entrypoint.pl"]
CMD ["httpd"]
