FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG NODE_MAJOR=24

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      gnupg \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
      > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
      nodejs \
      openjdk-21-jdk \
      build-essential \
      clang \
      make \
      pkg-config \
      graphviz \
      libgraphviz-dev \
      libcap-dev \
      lsof \
      iproute2 \
      procps \
      util-linux \
      python3 \
      python3-venv \
      gdb \
      git \
      unzip \
      zip \
      rsync \
      file \
      bash \
      coreutils \
      findutils \
      grep \
      sed \
      gawk \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 \
    AFL_NO_UI=1 \
    AFL_SKIP_CPUFREQ=1 \
    AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 \
    AFL_NO_AFFINITY=1 \
    GRADLE_USER_HOME=/work/.gradle-container \
    NPM_CONFIG_CACHE=/work/.npm-cache-container

WORKDIR /work

CMD ["bash"]
