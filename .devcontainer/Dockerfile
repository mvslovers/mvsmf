FROM mcr.microsoft.com/devcontainers/base:ubuntu

RUN apt-get update && \
    apt-get install -y \
        clang \
        clangd \
        build-essential \
        npm \
        curl \
    && apt-get clean

# Zowe
RUN npm install -g @zowe/cli

# c2asm370 v1.2
RUN curl -L -o /tmp/c2asm370.tar.gz \
    https://github.com/mvslovers/c2asm370/releases/download/v1.2/c2asm370-v1.2-linux-x86_64.tar.gz && \
    tar -xzf /tmp/c2asm370.tar.gz -C /tmp && \
    mv /tmp/c2asm370 /usr/local/bin/c2asm370 && \
    chmod +x /usr/local/bin/c2asm370 && \
    rm -rf /tmp/c2asm370*