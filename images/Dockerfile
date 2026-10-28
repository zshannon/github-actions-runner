# Source: https://github.com/dotnet/dotnet-docker
FROM mcr.microsoft.com/dotnet/runtime-deps:8.0-noble AS build

ARG BUILDX_VERSION=0.38.0
ARG DOCKER_VERSION=29.9.0
ARG RUNNER_CONTAINER_HOOKS_VERSION=0.7.0
ARG RUNNER_PACKAGE_SHA256_ARM64
ARG RUNNER_PACKAGE_SHA256_X64
ARG RUNNER_PACKAGE_SOURCE=release
ARG RUNNER_REPOSITORY=falcondev-oss/github-actions-runner
ARG RUNNER_VERSION
ARG TARGETARCH
ARG TARGETOS
ARG VERIFY_RUNNER_PACKAGE=false

RUN apt update -y && apt install curl unzip -y

WORKDIR /actions-runner
RUN --mount=type=bind,source=.,target=/build-context \
    export RUNNER_ARCH=${TARGETARCH} \
    && if [ "$RUNNER_ARCH" = "amd64" ]; then export RUNNER_ARCH=x64 ; fi \
    && case "$RUNNER_PACKAGE_SOURCE" in \
         local) cp "/build-context/runner-packages/actions-runner-${TARGETOS}-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz" runner.tar.gz ;; \
         release) curl -f -L -o runner.tar.gz "https://github.com/${RUNNER_REPOSITORY}/releases/download/v${RUNNER_VERSION}/actions-runner-${TARGETOS}-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz" ;; \
         *) echo "Unsupported runner package source: $RUNNER_PACKAGE_SOURCE" >&2; exit 1 ;; \
       esac \
    && if [ "$RUNNER_PACKAGE_SOURCE" = "local" ] || [ "$VERIFY_RUNNER_PACKAGE" = "true" ]; then \
         case "$RUNNER_ARCH" in \
           arm64) RUNNER_PACKAGE_SHA256="$RUNNER_PACKAGE_SHA256_ARM64" ;; \
           x64) RUNNER_PACKAGE_SHA256="$RUNNER_PACKAGE_SHA256_X64" ;; \
           *) echo "Unsupported runner architecture: $RUNNER_ARCH" >&2; exit 1 ;; \
         esac; \
         case "$RUNNER_PACKAGE_SHA256" in *[!0-9a-f]*|'') echo "Invalid runner package SHA256" >&2; exit 1 ;; esac; \
         [ "${#RUNNER_PACKAGE_SHA256}" -eq 64 ] || exit 1; \
         echo "$RUNNER_PACKAGE_SHA256  runner.tar.gz" | sha256sum -c -; \
       fi \
    && tar xzf ./runner.tar.gz \
    && rm runner.tar.gz

RUN curl -f -L -o runner-container-hooks.zip https://github.com/actions/runner-container-hooks/releases/download/v${RUNNER_CONTAINER_HOOKS_VERSION}/actions-runner-hooks-k8s-${RUNNER_CONTAINER_HOOKS_VERSION}.zip \
    && unzip ./runner-container-hooks.zip -d ./k8s \
    && rm runner-container-hooks.zip

RUN curl -f -L -o runner-container-hooks.zip https://github.com/actions/runner-container-hooks/releases/download/v0.8.1/actions-runner-hooks-k8s-0.8.1.zip \
    && unzip ./runner-container-hooks.zip -d ./k8s-novolume \
    && rm runner-container-hooks.zip

RUN export RUNNER_ARCH=${TARGETARCH} \
    && if [ "$RUNNER_ARCH" = "amd64" ]; then export DOCKER_ARCH=x86_64 ; fi \
    && if [ "$RUNNER_ARCH" = "arm64" ]; then export DOCKER_ARCH=aarch64 ; fi \
    && curl -fLo docker.tgz https://download.docker.com/${TARGETOS}/static/stable/${DOCKER_ARCH}/docker-${DOCKER_VERSION}.tgz \
    && tar zxvf docker.tgz \
    && rm -rf docker.tgz \
    && mkdir -p /usr/local/lib/docker/cli-plugins \
    && curl -fLo /usr/local/lib/docker/cli-plugins/docker-buildx \
    "https://github.com/docker/buildx/releases/download/v${BUILDX_VERSION}/buildx-v${BUILDX_VERSION}.linux-${TARGETARCH}" \
    && chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx

FROM mcr.microsoft.com/dotnet/runtime-deps:8.0-noble

ENV DEBIAN_FRONTEND=noninteractive
ENV RUNNER_MANUALLY_TRAP_SIG=1
ENV ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT=1
ENV ImageOS=ubuntu24

# 'gpg-agent' and 'software-properties-common' are needed for the 'add-apt-repository' command that follows
RUN apt update -y \
    && apt install -y --no-install-recommends ca-certificates sudo lsb-release gpg-agent software-properties-common curl jq unzip zstd \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && rm -rf /var/lib/apt/lists/*

# Configure git-core/ppa based on guidance here:  https://git-scm.com/download/linux
RUN add-apt-repository ppa:git-core/ppa \
    && apt update -y \
    && apt install -y --no-install-recommends gh git \
    && rm -rf /var/lib/apt/lists/*

RUN adduser --disabled-password --gecos "" --uid 1001 runner \
    && groupadd docker --gid 123 \
    && usermod -aG sudo runner \
    && usermod -aG docker runner \
    && echo "%sudo   ALL=(ALL:ALL) NOPASSWD:ALL" > /etc/sudoers \
    && echo "Defaults env_keep += \"DEBIAN_FRONTEND\"" >> /etc/sudoers \
    && chmod 777 /home/runner

WORKDIR /home/runner

COPY --chown=runner:docker --from=build /actions-runner .
COPY --from=build /usr/local/lib/docker/cli-plugins/docker-buildx /usr/local/lib/docker/cli-plugins/docker-buildx

RUN install -o root -g root -m 755 docker/* /usr/bin/ && rm -rf docker

USER runner
