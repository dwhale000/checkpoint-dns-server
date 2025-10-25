# Use official Blocky image from GitHub Container Registry
FROM ghcr.io/0xerr0r/blocky:latest

# Copy our configuration file
COPY config.yml /app/config.yml

# Expose DNS ports
EXPOSE 53/udp
EXPOSE 53/tcp
EXPOSE 8080/tcp
EXPOSE 443/tcp

# Blocky will automatically use config.yml from /app/
CMD ["--config", "/app/config.yml"]
