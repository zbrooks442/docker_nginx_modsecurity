FROM debian:buster-slim as modsecurity-build

# Install the required build dependencies for ModSecurity

RUN apt-get update -qq && \
	apt-get install -y apt-utils \
	autoconf \
	automake \
	build-essential \
	git \
	libcurl4-openssl-dev \
	libgeoip-dev \
	liblmdb-dev \
	libpcre++-dev \
	libtool \
	libxml2-dev \
	libyajl-dev \
	pkgconf \
	wget \
	zlib1g-dev && \
	apt-get clean && rm -rf /var/lib/apt/lists/*

RUN cd /opt && \
    git clone --depth 1 -b v3/master --single-branch https://github.com/SpiderLabs/ModSecurity && \
    cd ModSecurity && \
    git submodule init && \
    git submodule update && \
    ./build.sh && \
    ./configure && \
    make >/dev/null 2>&1 && \
    make install >/dev/null 2>&1

RUN strip /usr/local/modsecurity/bin/* /usr/local/modsecurity/lib/*.a /usr/local/modsecurity/lib/*.so*

FROM debian:buster-slim AS nginx-build

COPY --from=modsecurity-build /usr/local/modsecurity/ /usr/local/modsecurity/

# Install the required build dependencies for the Nginx ModSecuirty Connector

RUN apt-get update -qq && \
	apt-get install -y curl \
	gnupg2 \
	ca-certificates \
	lsb-release && \
	echo "deb http://nginx.org/packages/mainline/debian `lsb_release -cs` nginx" \
    | tee /etc/apt/sources.list.d/nginx.list && \
    curl -fsSL https://nginx.org/keys/nginx_signing.key | apt-key add - && \
    apt update -qq && \
    apt-get install -y nginx \
	apt-utils \
	autoconf \
	automake \
	build-essential \
	git \
	libcurl4-openssl-dev \
	libgeoip-dev \
	liblmdb-dev \
	libpcre++-dev \
	libtool \
	libxml2-dev \
	libyajl-dev \
	pkgconf \
	wget \
	zlib1g-dev && \
	apt-get clean && rm -rf /var/lib/apt/lists/* 

# Compile the modsecurity nginx connector

RUN cd /opt && \
	git clone --depth 1 https://github.com/SpiderLabs/ModSecurity-nginx.git && \
	nginx -v 2> version.txt && \
	wget http://nginx.org/download/nginx-$(cat version.txt | grep nginx | awk '{print $3}' | tr '/' ' ' | awk '{print $2}').tar.gz && \
	tar zxvf nginx-$(cat version.txt | grep nginx | awk '{print $3}' | tr '/' ' ' | awk '{print $2}').tar.gz && \
	mv nginx-$(cat version.txt | grep nginx | awk '{print $3}' | tr '/' ' ' | awk '{print $2}') nginx_for_module && \
	cd nginx_for_module && \
	./configure --with-compat --add-dynamic-module=../ModSecurity-nginx && \
	make >/dev/null 2>&1 && \
	make install >/dev/null 2>&1 && \
	make modules >/dev/null 2>&1 && \
	cp /opt/nginx_for_module/objs/ngx_http_modsecurity_module.so /etc/nginx/modules

# Configure the modsecurity rulesets

RUN mkdir /opt/modsecurity.d && \ 
	cd /opt/modsecurity.d && \
	wget https://raw.githubusercontent.com/SpiderLabs/ModSecurity/v3/master/modsecurity.conf-recommended && \
	wget https://raw.githubusercontent.com/SpiderLabs/ModSecurity/v3/master/unicode.mapping && \
	cp modsecurity.conf-recommended modsecurity.conf && \
	sed -i 's/SecRuleEngine DetectionOnly/SecRuleEngine On/' modsecurity.conf && \
	echo include \"/etc/modsecurity.d/modsecurity.conf\" >> include.conf && \
	echo include \"/etc/modsecurity.d/owasp-modsecurity-crs/crs-setup.conf\" >> include.conf && \
	echo include \"/etc/modsecurity.d/owasp-modsecurity-crs/rules/*.conf\" >> include.conf && \
	git clone https://github.com/SpiderLabs/owasp-modsecurity-crs.git && \
	cd owasp-modsecurity-crs && \
	cp crs-setup.conf.example crs-setup.conf

FROM nginx:latest AS nginx-final

# Copy the artifacts from the previous stages

COPY --from=modsecurity-build /usr/local/modsecurity/ /usr/local/modsecurity/
COPY --from=nginx-build /etc/nginx/modules/ngx_http_modsecurity_module.so /etc/nginx/modules/
COPY --from=nginx-build /opt/modsecurity.d/ /etc/modsecurity.d/

# Required dependencies for ModSecurity

RUN apt-get update -qq && \
	apt-get install -y apt-utils \
	autoconf \
	automake \
	build-essential \
	git \
	libcurl4-openssl-dev \
	libgeoip-dev \
	liblmdb-dev \
	libpcre++-dev \
	libtool \
	libxml2-dev \
	libyajl-dev \
	pkgconf \
	wget \
	zlib1g-dev && \
	apt-get clean && rm -rf /var/lib/apt/lists/*

# Final Configuration

RUN ldconfig && \
	sed -i 's/user  nginx/load_module \/etc\/nginx\/modules\/ngx_http_modsecurity_module.so;\n\nuser  nginx/g' /etc/nginx/nginx.conf && \
	sed -i 's/http {/http {\n    modsecurity on;\n    modsecurity_rules_file \/etc\/modsecurity.d\/include.conf;    \n/g' /etc/nginx/nginx.conf && \
	mkdir -p /var/log/modsec && \
	touch /var/log/modsec/modsec_audit.log && \
	sed -i 's/SecAuditLog \/var\/log\/modsec_audit.log/SecAuditLog \/var\/log\/modsec\/modsec_audit.log/g' /etc/modsecurity.d/modsecurity.conf && \
	chown -R www-data:www-data /etc/nginx && \
	chown -R www-data:www-data /etc/modsecurity.d
