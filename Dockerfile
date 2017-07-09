FROM ubuntu:16.04 as base

ENV DEBIAN_FRONTEND=noninteractive TERM=xterm
RUN echo "export > /etc/envvars" >> /root/.bashrc && \
    echo "export PS1='\[\e[1;31m\]\u@\h:\w\\$\[\e[0m\] '" | tee -a /root/.bashrc /etc/skel/.bashrc && \
    echo "alias tcurrent='tail /var/log/*/current -f'" | tee -a /root/.bashrc /etc/skel/.bashrc

RUN apt-get update
RUN apt-get install -y locales && locale-gen en_US.UTF-8 && dpkg-reconfigure locales
ENV LANGUAGE=en_US.UTF-8 LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8

# Runit
RUN apt-get install -y --no-install-recommends runit
CMD export > /etc/envvars && /usr/sbin/runsvdir-start

# Utilities
RUN apt-get install -y --no-install-recommends vim less net-tools inetutils-ping wget curl git telnet nmap socat dnsutils netcat tree htop unzip sudo software-properties-common jq psmisc iproute python ssh rsync gettext-base

# Based on https://docs.gitlab.com/ce/install/installation.html

# 1. Packages / Dependencies

RUN apt-get install -y build-essential zlib1g-dev libyaml-dev libssl-dev libgdbm-dev libreadline-dev libncurses5-dev libffi-dev curl openssh-server checkinstall libxml2-dev libxslt-dev libcurl4-openssl-dev libicu-dev logrotate python-docutils pkg-config cmake

# 2. Ruby

RUN mkdir /tmp/ruby && cd /tmp/ruby && \
    curl --remote-name --progress https://cache.ruby-lang.org/pub/ruby/2.3/ruby-2.3.3.tar.gz && \
    echo '1014ee699071aa2ddd501907d18cbe15399c997d  ruby-2.3.3.tar.gz' | shasum -c - && tar xzf ruby-2.3.3.tar.gz && \
    cd ruby-2.3.3 && \
    ./configure --disable-install-rdoc && \
    make -j4 && \
    make install && \
    rm -rf /tmp/ruby
RUN gem install bundler --no-ri --no-rdoc

# 3. GO

RUN curl --remote-name --progress https://storage.googleapis.com/golang/go1.8.3.linux-amd64.tar.gz && \
    echo '1862f4c3d3907e59b04a757cfda0ea7aa9ef39274af99a784f5be843c80c6772  go1.8.3.linux-amd64.tar.gz' | shasum -a256 -c - && \
    tar -C /usr/local -xzf go1.8.3.linux-amd64.tar.gz && \
    ln -sf /usr/local/go/bin/go /usr/local/bin/ && \
    ln -sf /usr/local/go/bin/godoc /usr/local/bin/ && \
    ln -sf /usr/local/go/bin/gofmt /usr/local/bin/ && \
    rm go1.8.3.linux-amd64.tar.gz

# 4. Node
RUN curl --location https://deb.nodesource.com/setup_7.x | sudo bash - && \
    apt-get install -y nodejs
RUN curl --location https://yarnpkg.com/install.sh | bash -

# 5. System Users

RUN adduser --disabled-login --gecos 'GitLab' git

# 6. Database

RUN apt-get install -y postgresql postgresql-client libpq-dev postgresql-contrib

# 7. Redis

RUN apt-get install -y redis-server

# 8. GitLab

RUN cd /home/git && \
    sudo -u git -H git clone --depth 1 https://gitlab.com/gitlab-org/gitlab-ce.git -b 9-3-stable gitlab

WORKDIR /home/git/gitlab

RUN sudo -u git -H cp config/gitlab.yml.example config/gitlab.yml && \
    sudo -u git -H cp config/secrets.yml.example config/secrets.yml && \
    sudo -u git -H chmod 0600 config/secrets.yml && \
    sudo -u git -H mkdir public/uploads/ && \
    sudo -u git -H chmod 0700 public/uploads && \
    sudo -u git -H chmod -R u+rwX builds/ && \
    sudo -u git -H chmod -R u+rwX shared/artifacts/ && \
    sudo -u git -H chmod -R ug+rwX shared/pages/ && \
    sudo -u git -H cp config/unicorn.rb.example config/unicorn.rb && \
    sudo -u git -H cp config/initializers/rack_attack.rb.example config/initializers/rack_attack.rb && \
    sudo -u git -H git config --global core.autocrlf input && \
    sudo -u git -H git config --global gc.auto 0 && \
    sudo -u git -H git config --global repack.writeBitmaps true && \
    sudo -u git -H cp config/resque.yml.example config/resque.ymld && \
    sudo -u git -H cp config/database.yml.postgresql config/database.yml && \
    sudo -u git -H chmod o-rwx config/database.yml

RUN sudo -u git -H bundle install --deployment --without development test mysql aws kerberos -j$(nproc)

RUN sudo -u git -H bundle exec rake gitlab:shell:install REDIS_URL=unix:/var/run/redis/redis.sock RAILS_ENV=production SKIP_STORAGE_VALIDATION=true

COPY redis.conf /etc/redis/
RUN redis-server & \
    sudo -u git -H bundle exec rake "gitlab:workhorse:install[/home/git/gitlab-workhorse]" RAILS_ENV=production

# Postgres

COPY ddl /
ENV PGDATA /data
ENV PATH $PATH:/usr/lib/postgresql/9.5/bin
RUN mkdir -p /var/run/postgresql/9.5-main.pg_stat_tmp
RUN chown postgres.postgres /var/run/postgresql/9.5-main.pg_stat_tmp -R

# Gitaly
RUN redis-server & \
    sudo -u git -H bundle exec rake "gitlab:gitaly:install[/home/git/gitaly]" RAILS_ENV=production

# logrotate
RUN cp lib/support/logrotate/gitlab /etc/logrotate.d/gitlab

# Compile Assets
RUN npm install -g yarn
RUN sudo -u git -H yarn install --production --pure-lockfile
RUN redis-server & \
    sudo -u git -H bundle exec rake gitlab:assets:compile RAILS_ENV=production NODE_ENV=production

# Compile GetText PO files
RUN redis-server & \
    sudo -u git -H bundle exec rake gettext:compile RAILS_ENV=production

# Nginx
RUN apt-get install -y nginx
RUN cp lib/support/nginx/gitlab /etc/nginx/sites-available/gitlab && \
    ln -s /etc/nginx/sites-available/gitlab /etc/nginx/sites-enabled/gitlab && \
    rm -f /etc/nginx/sites-enabled/default

# Add runit services
COPY sv /etc/service 
ARG BUILD_INFO
LABEL BUILD_INFO=$BUILD_INFO

