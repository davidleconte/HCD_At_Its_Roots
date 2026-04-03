#!/bin/bash
# Compatible with both Docker and Podman container runtimes
set -e

# Set defaults for required environment variables
: "${CASSANDRA_CLUSTER_NAME:=HCDCluster}"
: "${CASSANDRA_SEEDS:=172.28.0.2}"
: "${CASSANDRA_LISTEN_ADDRESS:=127.0.0.1}"
: "${CASSANDRA_BROADCAST_ADDRESS:=$CASSANDRA_LISTEN_ADDRESS}"
: "${CASSANDRA_RPC_ADDRESS:=0.0.0.0}"
: "${CASSANDRA_ENDPOINT_SNITCH:=SimpleSnitch}"
: "${CASSANDRA_DC:=dc1}"
: "${CASSANDRA_RACK:=rack1}"

export CASSANDRA_CLUSTER_NAME CASSANDRA_SEEDS CASSANDRA_LISTEN_ADDRESS CASSANDRA_BROADCAST_ADDRESS CASSANDRA_RPC_ADDRESS CASSANDRA_ENDPOINT_SNITCH CASSANDRA_DC CASSANDRA_RACK
export CASSANDRA_CONF=${CASSANDRA_CONF:-/opt/hcd/resources/cassandra/conf}
export HCD_CONF=${HCD_CONF:-/opt/hcd/resources/cassandra/conf}

# Validate critical configuration
if [ -z "${CASSANDRA_LISTEN_ADDRESS}" ] || [ "${CASSANDRA_LISTEN_ADDRESS}" = "127.0.0.1" ]; then
    if [ "${CASSANDRA_LISTEN_ADDRESS}" = "127.0.0.1" ] && [ "${CASSANDRA_SEEDS}" != "127.0.0.1" ]; then
        echo "WARNING: CASSANDRA_LISTEN_ADDRESS is 127.0.0.1 but seeds point elsewhere. Node will be unreachable by peers."
    fi
fi

# Generate cassandra.yaml from template
TEMPLATE="/opt/hcd/resources/cassandra/conf/cassandra.yaml.template"
CONF_OUTPUT="/opt/hcd/resources/cassandra/conf/cassandra.yaml"
if [ ! -f "$TEMPLATE" ]; then
    echo "ERROR: Template file not found: $TEMPLATE"
    exit 1
fi
envsubst < "$TEMPLATE" > "$CONF_OUTPUT"
if [ ! -s "$CONF_OUTPUT" ]; then
    echo "ERROR: Generated cassandra.yaml is empty. Check template variables."
    exit 1
fi

# Generate cassandra-rackdc.properties if GossipingPropertyFileSnitch is used
if [ "$CASSANDRA_ENDPOINT_SNITCH" = "GossipingPropertyFileSnitch" ]; then
    echo "dc=$CASSANDRA_DC" > /opt/hcd/resources/cassandra/conf/cassandra-rackdc.properties
    echo "rack=$CASSANDRA_RACK" >> /opt/hcd/resources/cassandra/conf/cassandra-rackdc.properties
    echo "prefer_local=true" >> /opt/hcd/resources/cassandra/conf/cassandra-rackdc.properties
fi

# Apply JVM heap settings if provided
JVM_OPTIONS="/opt/hcd/resources/cassandra/conf/jvm-server.options"
if [ -n "$MAX_HEAP_SIZE" ] && [ -f "$JVM_OPTIONS" ]; then
    sed -i "s/^-Xmx.*/-Xmx${MAX_HEAP_SIZE}/" "$JVM_OPTIONS"
    sed -i "s/^-Xms.*/-Xms${MAX_HEAP_SIZE}/" "$JVM_OPTIONS"
fi

# Extract first seed from comma-separated list, trimming whitespace
FIRST_SEED=$(echo "${CASSANDRA_SEEDS}" | cut -d',' -f1 | tr -d '[:space:]')

if [ -z "$FIRST_SEED" ]; then
    echo "ERROR: CASSANDRA_SEEDS is empty or malformed: '${CASSANDRA_SEEDS}'"
    exit 1
fi

# Do not wait if we are the seed node
if [ "$CASSANDRA_LISTEN_ADDRESS" = "$FIRST_SEED" ]; then
    echo "Starting as seed node..."
else
    echo "This node ($CASSANDRA_LISTEN_ADDRESS) is not the seed. Waiting for seed node at $FIRST_SEED..."
    
    # Phase 1: Wait for TCP port to be open (exponential backoff: 1s, 2s, 4s, ... capped at 10s)
    MAX_RETRIES=30
    COUNT=0
    DELAY=1
    while ! nc -z "$FIRST_SEED" 9042 2>/dev/null; do
        COUNT=$((COUNT + 1))
        if [ $COUNT -ge $MAX_RETRIES ]; then
            echo "ERROR: Seed node $FIRST_SEED port 9042 not reachable after $COUNT retries."
            exit 1
        fi
        echo "Waiting for seed node TCP port... ($COUNT/$MAX_RETRIES, next retry in ${DELAY}s)"
        sleep $DELAY
        DELAY=$((DELAY * 2))
        [ $DELAY -gt 10 ] && DELAY=10
    done
    echo "Seed node TCP port is open."

    # Phase 2: Wait for CQL to be ready (exponential backoff: 2s, 4s, 8s, ... capped at 15s)
    MAX_CQL_RETRIES=20
    CQL_COUNT=0
    CQL_DELAY=2
    while ! cqlsh "$FIRST_SEED" -e "SELECT release_version FROM system.local" >/dev/null 2>&1; do
        CQL_COUNT=$((CQL_COUNT + 1))
        if [ $CQL_COUNT -ge $MAX_CQL_RETRIES ]; then
            echo "ERROR: Seed node $FIRST_SEED CQL not ready after $CQL_COUNT retries."
            exit 1
        fi
        echo "Waiting for seed node CQL readiness... ($CQL_COUNT/$MAX_CQL_RETRIES, next retry in ${CQL_DELAY}s)"
        sleep $CQL_DELAY
        CQL_DELAY=$((CQL_DELAY * 2))
        [ $CQL_DELAY -gt 15 ] && CQL_DELAY=15
    done
    echo "Seed node CQL is ready."
    
    # Add jitter delay to prevent thundering herd when multiple nodes join simultaneously
    JITTER=$((RANDOM % 5 + 1))
    echo "Adding ${JITTER}s jitter delay before joining cluster..."
    sleep $JITTER
fi

# Apply JVM_EXTRA_OPTS (e.g., JMX Prometheus exporter) if the agent JAR exists
if [ -n "$JVM_EXTRA_OPTS" ] && [ -f /opt/hcd/jmx_prometheus_javaagent.jar ]; then
    export JVM_OPTS="${JVM_OPTS:-} ${JVM_EXTRA_OPTS}"
    echo "JMX exporter enabled on port 9404"
fi

echo "Starting HCD..."
# Start HCD in foreground
exec /opt/hcd/bin/hcd cassandra -f
