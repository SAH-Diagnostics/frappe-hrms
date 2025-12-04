FROM frappe/bench:latest

USER root

# Install system dependencies and AWS CLI
RUN apt-get update && apt-get install -y \
    unzip \
    curl \
    git \
    && curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" \
    && unzip awscliv2.zip \
    && ./aws/install \
    && rm -rf aws awscliv2.zip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

USER frappe

