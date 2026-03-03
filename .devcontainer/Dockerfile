FROM mcr.microsoft.com/devcontainers/base:ubuntu

RUN apt-get update && \
    apt-get install -y \
        curl \
        clang \
        clangd \
        build-essential \
        libsecret-1-0 \
    && apt-get clean

# c2asm370
RUN curl -fL -o /tmp/c2asm370.tar.gz \
    https://github.com/mvslovers/c2asm370/releases/download/v1.2/c2asm370-linux-x86.tar.gz && \
    tar -xzf /tmp/c2asm370.tar.gz -C /tmp && \
    mv /tmp/c2asm370 /usr/local/bin/c2asm370 && \
    chmod +x /usr/local/bin/c2asm370 && \
    rm -rf /tmp/c2asm370*