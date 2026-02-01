FROM openjdk:11-jre-slim

# Install dependencies:
# - gettext-base for envsubst
# - netcat-openbsd for seed checking
# - procps for cassandra startup scripts
RUN apt-get update && apt-get install -y --no-install-recommends \
    gettext-base \
    netcat-openbsd \
    procps \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# Create cassandra user and directories
RUN groupadd -r cassandra && useradd -r -g cassandra cassandra

# Assuming HCD is installed at /opt/hcd
# (In a real scenario, we would ADD/COPY the tarball here)
WORKDIR /opt/hcd

# Copy configuration template and entrypoint script
COPY config/cassandra.yaml.template /opt/hcd/conf/cassandra.yaml.template
COPY scripts/docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# Ensure permissions for cassandra user
RUN mkdir -p /var/lib/cassandra /var/log/cassandra && \
    chown -R cassandra:cassandra /var/lib/cassandra /var/log/cassandra /opt/hcd

USER cassandra

ENTRYPOINT ["/docker-entrypoint.sh"]
