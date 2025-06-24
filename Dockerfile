# Multi-stage Dockerfile using NixOS for Reencodarr Elixir/Phoenix app
FROM nixos/nix:latest AS builder

# Enable experimental features for flakes
RUN echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf

# Set working directory
WORKDIR /app

# Copy flake files first for better caching
COPY flake.nix flake.lock ./

# Copy the entire source
COPY . .

# Build the application using nix flake
RUN nix develop --command bash -c "\
    mix deps.get --only prod && \
    MIX_ENV=prod mix compile && \
    MIX_ENV=prod mix assets.deploy && \
    MIX_ENV=prod mix release \
    "

# Production stage - using a lighter base with nix
FROM nixos/nix:latest AS runtime

# Enable experimental features for flakes
RUN echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf

# Create app user
RUN addgroup -g 1001 -S app && \
    adduser -u 1001 -S app -G app

# Set working directory
WORKDIR /app

# Copy flake files for runtime dependencies
COPY flake.nix flake.lock ./

# Install runtime dependencies including ffmpeg and other tools
RUN nix develop --command bash -c "echo 'Runtime environment prepared'"

# Copy the release from builder stage
COPY --from=builder --chown=app:app /app/_build/prod/rel/reencodarr ./

# Switch to app user
USER app

# Expose port
EXPOSE 4000

# Environment variables
ENV MIX_ENV=prod
ENV PHX_SERVER=true
ENV PORT=4000

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD nix develop --command curl -f http://localhost:4000/ || exit 1

# Start the application
CMD ["./bin/reencodarr", "start"]
