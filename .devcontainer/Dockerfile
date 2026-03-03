FROM mcr.microsoft.com/devcontainers/base:ubuntu

# ---- System Packages ----
RUN apt-get update && \
    apt-get install -y \
        curl \
        clang \
        clangd \
        build-essential \
        ca-certificates \
        gnupg \
    && apt-get clean

# ---- Node 20 LTS ----
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
      > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && \
    apt-get install -y nodejs && \
    node -v && npm -v

# ---- Zowe CLI ----
RUN npm install -g @zowe/cli

# ---- c2asm370 ----
RUN curl -fL -o /tmp/c2asm370.tar.gz \
    https://github.com/mvslovers/c2asm370/releases/download/v1.2/c2asm370-linux-x86.tar.gz && \
    tar -xzf /tmp/c2asm370.tar.gz -C /tmp && \
    mv /tmp/c2asm370 /usr/local/bin/c2asm370 && \
    chmod +x /usr/local/bin/c2asm370 && \
    rm -rf /tmp/c2asm370*