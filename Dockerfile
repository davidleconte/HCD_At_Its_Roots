FROM eclipse-temurin:11-jre

# Install dependencies:
# - gettext-base for envsubst
# - netcat-openbsd for seed checking
# - procps for cassandra startup scripts
# - curl/ca-certificates for uv installation
# Note: Netty native epoll warning (UnsatisfiedLinkError) on ARM64 is harmless; 
# the service automatically falls back to NIO.
RUN apt-get update && apt-get install -y --no-install-recommends \
    gettext-base \
    netcat-openbsd \
    procps \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install uv and setup Python environment
COPY --from=ghcr.io/astral-sh/uv:0.5 /uv /bin/uv
ENV UV_PYTHON_INSTALL_DIR=/opt/python
ENV VIRTUAL_ENV=/opt/venv
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

# Create virtual environment with a specific Python version
# UV_PYTHON_INSTALL_DIR ensures Python is installed in a shared location
# accessible to the non-root cassandra user at runtime
RUN uv venv $VIRTUAL_ENV --python 3.11 && \
    uv pip install cassandra-driver

# Create cassandra user and directories with fixed IDs for Podman/Rootless consistency
# Fixed UIDs ensure that file ownership remains consistent when mapping volumes in rootless mode
RUN groupadd -r cassandra --gid=999 && \
    useradd -r -g cassandra --uid=999 cassandra

# Install HCD from local tarball
# We use a specific directory to avoid clobbering /opt
COPY hcd-1.2.3-bin.tar.gz /tmp/hcd.tar.gz
RUN mkdir -p /opt/hcd && \
    tar -xzf /tmp/hcd.tar.gz -C /opt/hcd --strip-components=1 && \
    rm /tmp/hcd.tar.gz

# Create wrapper scripts that set HCD_CONF for docker exec compatibility
# Remove any symlinks the tarball may have installed first
RUN for cmd in nodetool cqlsh hcd sstableloader sstabledump sstablemetadata; do \
        rm -f /usr/local/bin/$cmd && \
        printf '#!/bin/bash\nexport HCD_CONF=/opt/hcd/resources/cassandra/conf\nexport CASSANDRA_CONF=/opt/hcd/resources/cassandra/conf\nexec /opt/hcd/bin/%s "$@"\n' "$cmd" > /usr/local/bin/$cmd && \
        chmod +x /usr/local/bin/$cmd; \
    done

# Download JMX Prometheus exporter (optional: for --profile monitoring)
ARG JMX_EXPORTER_VERSION=0.20.0
RUN curl -fsSL -o /opt/hcd/jmx_prometheus_javaagent.jar \
    "https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/${JMX_EXPORTER_VERSION}/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar" \
    2>/dev/null || echo "JMX exporter download skipped (no internet). Monitoring profile will be unavailable."
COPY config/jmx-exporter.yml /opt/hcd/jmx-exporter.yml

WORKDIR /opt/hcd

ENV CASSANDRA_CONF=/opt/hcd/resources/cassandra/conf
ENV HCD_CONF=/opt/hcd/resources/cassandra/conf

# Copy configuration template and entrypoint script
COPY config/cassandra.yaml.template /opt/hcd/resources/cassandra/conf/cassandra.yaml.template
COPY --chmod=755 scripts/docker-entrypoint.sh /docker-entrypoint.sh
COPY --chmod=755 scripts/generate-topology.py /usr/local/bin/generate-topology
COPY --chmod=755 scripts/demo-entropy.sh /usr/local/bin/demo-entropy
COPY --chmod=755 scripts/driver-demo.py /usr/local/bin/driver-demo

# Ensure permissions for cassandra user
RUN mkdir -p /var/lib/cassandra /var/log/cassandra && \
    chown -R cassandra:cassandra /var/lib/cassandra /var/log/cassandra /opt/hcd /opt/venv /opt/python

# Set default JVM Heap sizes (Lowered for demo/local laptop portability)
ENV MAX_HEAP_SIZE="512M"
ENV HEAP_NEWSIZE="100M"

USER cassandra

ENTRYPOINT ["/docker-entrypoint.sh"]
