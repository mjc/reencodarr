.PHONY: docker-build docker-run docker-compose-up docker-compose-down nix-docker-build

# Build Docker image using standard Dockerfile
docker-build:
	docker build -t reencodarr:latest .

# Run the Docker container
docker-run:
	docker run -p 4000:4000 --env-file .env reencodarr:latest

# Start with docker-compose
docker-compose-up:
	docker compose up -d

# Stop docker-compose services
docker-compose-down:
	docker compose down

# Build Docker image using Nix flake
nix-docker-build:
	nix build .#dockerImage
	docker load < result

# Build and run with docker-compose
dev-up: docker-compose-up
	@echo "Application available at http://localhost:4000"

# Clean up Docker resources
docker-clean:
	docker compose down -v
	docker system prune -f

# Development helpers
setup:
	mix deps.get
	mix ecto.setup
	mix assets.setup

release:
	MIX_ENV=prod mix deps.get --only prod
	MIX_ENV=prod mix compile
	MIX_ENV=prod mix assets.deploy
	MIX_ENV=prod mix release
