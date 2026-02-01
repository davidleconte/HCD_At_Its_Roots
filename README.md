# HCD Docker Cluster

This project provides a Dockerized environment for running a multi-node IBM Hyperledger Cassandra (HCD) cluster. It is designed for development and testing purposes.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [Docker Compose](https://docs.docker.com/compose/install/)
- An IBM HCD tarball download URL.

## Quick Start

1.  **Clone the repository.**

2.  **Configure the environment.**
    Copy the example environment file and set your HCD tarball URL:
    ```bash
    cp .env.example .env
    # Export the HCD_TARBALL_URL for the build process
    export HCD_TARBALL_URL="<your-ibm-hcd-tarball-url>"
    ```

3.  **Build and start the cluster.**
    ```bash
    docker-compose up -d --build
    ```

4.  **Check cluster status.**
    Wait a minute for the nodes to initialize, then run:
    ```bash
    docker exec hcd-node1 nodetool status
    ```

## Connecting to the Cluster

You can connect to the first node using `cqlsh`:

```bash
docker exec -it hcd-node1 cqlsh
```

## Configuration

The cluster can be configured via environment variables in the `.env` file or `docker-compose.yml`:

| Variable | Description | Default |
|----------|-------------|---------|
| `CASSANDRA_CLUSTER_NAME` | The name of the Cassandra cluster. | `HCDCluster` |
| `CASSANDRA_SEEDS` | Comma-separated list of seed node IP addresses. | `172.28.0.2` |
| `HCD_TARBALL_URL` | (Build time) The URL to download the HCD distribution. | Required |

## Scaling and Production Notes

- **Resources**: Each node is configured with default JVM settings. In production, ensure you tune `Xmx` and `Xms` via the `jvm.options` file or environment variables if supported by your entrypoint.
- **Persistence**: Data is persisted in Docker volumes (`hcd-node1-data`, etc.). Ensure these are backed up.
- **Networking**: This setup uses static IPs within a dedicated Docker bridge network (`172.28.0.0/16`).
- **Snitch**: Currently uses `SimpleSnitch`. For multi-datacenter setups, switch to `GossipingPropertyFileSnitch`.

## Troubleshooting

- **Node fails to start**: Check the logs using `docker-compose logs -f`. Common issues include invalid `HCD_TARBALL_URL` or insufficient memory allocated to Docker.
- **Nodes not joining**: Ensure the seed node (`hcd-node1` at `172.28.0.2`) is healthy and that `CASSANDRA_SEEDS` is correctly configured for the other nodes.
- **Healthcheck fails**: The first startup can take a while. Increase `start_period` in `docker-compose.yml` if your hardware is slower.
